#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Selective mod watchdog'u. WARP açık olduğu sürece blacklist domainlerini
    sürekli çözer:
      IPv4 -> /32 route TUN'a (yeni ekle, kalıcı kaybolanı prune et)
      IPv6 -> outbound firewall block (fail-closed: uygulama IPv4'e düşer -> WARP)

    Daemon: in-memory durum döngüler arası korunur (round-robin flap önleme).
#>
Set-StrictMode -Version 1.0
$ErrorActionPreference = "SilentlyContinue"

$DataDir       = Join-Path $env:ProgramData "usque"
$ConfigDir     = Join-Path $DataDir "config"
$RunDir        = Join-Path $DataDir "run"
$LogFile       = Join-Path $DataDir "usque.log"
$BlacklistTxt  = Join-Path $ConfigDir "warp-blacklist.txt"
$ResolvedFile  = Join-Path $RunDir "warp-resolved-ips.txt"
$TunName       = "usque"
$V6Rule        = "WarpTray-IPv6-FailClosed"
# CDN'ler (AWS/Cloudflare) her sorguda farklı IP döndürür. Agresif prune edersek
# tarayıcının kullandığı IP düşüp kaynak yarım gelir. Yüksek tut -> IP'ler oturum
# boyunca BİRİKİR, CDN havuzu zamanla tam kapsanır, set sabitlenir (churn durur).
# (dns-reload / reconnect zaten sıfırdan kurar.)
$PruneAfter    = 240    # ~1 saat (15sn x 240); pratikte oturum boyunca tutar
$SleepSeconds  = 15
# dnsproxy watchdog (selective modda sistem DNS 127.0.0.2'ye bağlı; dnsproxy
# ölürse internet gider — ölmüşse yeniden başlat)
$DnsproxyExe   = Join-Path (Join-Path $env:ProgramFiles "usque") "dnsproxy.exe"
$ListenDns     = "127.0.0.2"
$UpstreamDns1  = "1.1.1.1:53"
$UpstreamDns2  = "1.0.0.1:53"
$Resolvers     = @("1.1.1.1", "1.0.0.1")

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "$ts  [route-sync] $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

# Yeniden başlatmada mevcut route'larla senkron ol
$routed = @{}
if (Test-Path $ResolvedFile) {
    Get-Content $ResolvedFile | ForEach-Object {
        $ip = $_.Trim(); if ($ip) { $routed[$ip] = $true }
    }
}
$miss = @{}
$lastV6Key = ""

# .NET async DNS aslında thread havuzunda bloklayan iş; havuz yavaş büyür (~1/sn)
# -> 324 "async" sorgu sıraya girip ilk doldurma ~30sn sürüyordu. Havuzu baştan
# büyüt -> sorgular GERÇEKTEN eşzamanlı -> ilk doldurma birkaç saniye.
[System.Threading.ThreadPool]::SetMinThreads(256, 256) | Out-Null

Write-Log "başladı."

while ($true) {
    if (-not (Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue)) {
        Write-Log "TUN yok — çıkılıyor."
        break
    }

    # dnsproxy watchdog: düşmüşse yeniden başlat (DNS ölü kalıp internet gitmesin)
    if ((Test-Path $DnsproxyExe) -and -not (Get-Process -Name dnsproxy -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $DnsproxyExe -ArgumentList @(
            "-l", $ListenDns, "-p", "53", "-u", $UpstreamDns1, "-u", $UpstreamDns2, "--cache"
        ) -NoNewWindow -ErrorAction SilentlyContinue
        Write-Log "dnsproxy düşmüştü, yeniden başlatıldı (watchdog)"
    }

    # resolver IP'leri her zaman WARP tünelinden geçsin (zehirsiz DNS garantisi)
    foreach ($r in $Resolvers) {
        if (-not (Get-NetRoute -DestinationPrefix "$r/32" -InterfaceAlias $TunName -ErrorAction SilentlyContinue)) {
            New-NetRoute -DestinationPrefix "$r/32" -InterfaceAlias $TunName -RouteMetric 1 -ErrorAction SilentlyContinue | Out-Null
        }
    }

    $domains = @()
    if (Test-Path $BlacklistTxt) {
        $domains = Get-Content $BlacklistTxt |
            ForEach-Object { ($_ -replace '#.*', '').Trim() } |
            Where-Object { $_ -ne '' } |
            ForEach-Object { (($_ -replace '^\*\.', '') -replace ':\d+.*$', '').TrimEnd('.').ToLower() } |
            Where-Object { $_ -match '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' } |
            Sort-Object -Unique
    }

    $desiredV4 = @{}
    $v6set = New-Object System.Collections.Generic.HashSet[string]

    # PARALEL DNS çözümü: tüm domainleri async fırlat, topluca bekle (PS 5.1'de
    # ForEach -Parallel yok; .NET async Task kullanıyoruz). Sıralı ~30-60sn yerine
    # birkaç saniye. Tek tek GetHostAddresses çağrısı (her biri tünelden) yavaştı.
    $tasks = @{}
    foreach ($domain in $domains) {
        try { $tasks[$domain] = [System.Net.Dns]::GetHostAddressesAsync($domain) } catch {}
    }
    if ($tasks.Count -gt 0) {
        try {
            [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tasks.Values), 15000) | Out-Null
        } catch {}  # bazı task'lar timeout/hata -> bir sonraki tur yakalar
    }
    foreach ($domain in $tasks.Keys) {
        $t = $tasks[$domain]
        if ($t.Status -ne 'RanToCompletion' -or -not $t.Result) { continue }
        foreach ($a in $t.Result) {
            $ip = $a.ToString()
            if ($a.AddressFamily -eq 'InterNetwork') {
                $desiredV4[$ip] = $true
            } elseif ($a.AddressFamily -eq 'InterNetworkV6') {
                [void]$v6set.Add($ip)
            }
        }
    }

    # --- IPv4: ekle ---
    $added = 0
    foreach ($ip in $desiredV4.Keys) {
        $miss.Remove($ip) | Out-Null
        if (-not $routed.ContainsKey($ip)) {
            $exists = Get-NetRoute -DestinationPrefix "$ip/32" -InterfaceAlias $TunName -ErrorAction SilentlyContinue
            if (-not $exists) {
                New-NetRoute -DestinationPrefix "$ip/32" -InterfaceAlias $TunName -RouteMetric 1 -ErrorAction SilentlyContinue | Out-Null
            }
            $routed[$ip] = $true
            $added++
        }
    }

    # --- IPv4: kalıcı kaybolanı prune et ---
    $removed = 0
    foreach ($ip in @($routed.Keys)) {
        if (-not $desiredV4.ContainsKey($ip)) {
            $m = 0; if ($miss.ContainsKey($ip)) { $m = $miss[$ip] }
            $m++
            if ($m -ge $PruneAfter) {
                Get-NetRoute -DestinationPrefix "$ip/32" -InterfaceAlias $TunName -ErrorAction SilentlyContinue |
                    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                $routed.Remove($ip) | Out-Null
                $miss.Remove($ip) | Out-Null
                $removed++
            } else {
                $miss[$ip] = $m
            }
        }
    }

    if ($added -or $removed) {
        $routed.Keys | Sort-Object | Set-Content $ResolvedFile -Encoding UTF8
        Write-Log "v4: +$added -$removed (toplam $($routed.Count))"
    }

    # --- IPv6 fail-closed: değiştiyse block kuralını yeniden kur ---
    $v6sorted = @($v6set) | Sort-Object
    $v6key = ($v6sorted -join ",")
    if ($v6key -ne $lastV6Key) {
        Remove-NetFirewallRule -Group $V6Rule -ErrorAction SilentlyContinue
        if ($v6sorted.Count -gt 0) {
            New-NetFirewallRule -DisplayName $V6Rule -Group $V6Rule -Direction Outbound `
                -Action Block -RemoteAddress $v6sorted -Profile Any -ErrorAction SilentlyContinue | Out-Null
        }
        $lastV6Key = $v6key
        Write-Log "v6 block: $($v6sorted.Count) adres"
    }

    Start-Sleep -Seconds $SleepSeconds
}
