#Requires -RunAsAdministrator
<#
.SYNOPSIS
    usque MASQUE tünelini başlat + routing kur.
    Mod (transport + scope) desired.json'dan okunur.

    transport: http2 | http3
    scope:     selective (fiziksel default, sadece blacklist /32 -> TUN)
               full      (split-default -> TUN, endpoint fiziksel'de pinli)

    -Transport / -Scope CLI argümanı verilirse desired.json'ı GEÇERSİZ KILAR
    (tray bunları doğrudan geçer — dosya round-trip'ine güvenmeyen güvenilir yol).
#>
param(
    [ValidateSet("", "http2", "http3")][string]$Transport = "",
    [ValidateSet("", "selective", "full")][string]$Scope = ""
)
Set-StrictMode -Version 1.0
$ErrorActionPreference = "Stop"

# --- Yollar (hepsi paylaşılan ProgramData; SYSTEM + kullanıcı ortak) ---
$InstallDir   = Join-Path $env:ProgramFiles "usque"
$UsqueExe     = Join-Path $InstallDir "usque.exe"
$DnsproxyExe  = Join-Path $InstallDir "dnsproxy.exe"
$DataDir      = Join-Path $env:ProgramData "usque"
$ConfigDir    = Join-Path $DataDir "config"
$RunDir       = Join-Path $DataDir "run"
$LogFile      = Join-Path $DataDir "usque.log"
$ConfigJson   = Join-Path $ConfigDir "config.json"
$BlacklistTxt = Join-Path $ConfigDir "warp-blacklist.txt"
$StateFile    = Join-Path $RunDir "state.json"
$DesiredFile  = Join-Path $RunDir "desired.json"
$StdoutLog    = Join-Path $DataDir "usque-stdout.log"
$StderrLog    = Join-Path $DataDir "usque-stderr.log"

$TunName      = "usque"
$ListenDns    = "127.0.0.2"
# dnsproxy upstream: sorgular WARP TÜNELİNDEN geçer (resolver IP'leri TUN'a
# route'lanır) -> ISP zehirleyemez. Yandex:1253 düz-DNS artık TR'de zehirleniyordu.
$UpstreamDns1 = "1.1.1.1:53"
$UpstreamDns2 = "1.0.0.1:53"
$Resolvers    = @("1.1.1.1", "1.0.0.1")   # /32 -> TUN
$FullDns      = "1.1.1.1"          # full modda DNS tünelden geçer
# Cloudflare WARP endpoint altyapısı (içerik DEĞİL — bunları fiziksel'de pinlemek
# güvenli; usque'nin kendi bağlantısı tünele girip loop yapmasın). 162.159.192.0/19
# tüm WARP endpoint /24'lerini kapsar (.192/.193/.195/.198/.204).
$CfRanges     = @("162.159.192.0/19")

foreach ($d in @($RunDir, $ConfigDir, $DataDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "$ts  $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

# --- desired oku ---
$transport = "http2"; $scope = "selective"
if (Test-Path $DesiredFile) {
    try {
        $d = Get-Content $DesiredFile -Raw | ConvertFrom-Json
        if ($d.transport) { $transport = "$($d.transport)" }
        if ($d.scope)     { $scope     = "$($d.scope)" }
    } catch { Write-Log "desired.json okunamadı, varsayılan kullanılıyor: $_" }
}
# CLI argümanları (tray'den) desired.json'ı geçersiz kılar — öncelikli
if ($Transport) { $transport = $Transport }
if ($Scope)     { $scope     = $Scope }
if ($transport -notin @("http2","http3")) { $transport = "http2" }
if ($scope     -notin @("selective","full")) { $scope = "selective" }
Write-Log "warp-on: transport=$transport scope=$scope (arg: '$Transport'/'$Scope')"

# --- 1. usque başlat ---
$usque = Get-Process -Name "usque" -ErrorAction SilentlyContinue
if (-not $usque) {
    if (-not (Test-Path $UsqueExe))   { throw "usque.exe yok: $UsqueExe" }
    if (-not (Test-Path $ConfigJson)) { throw "config.json yok: $ConfigJson — 'usque register' çalıştır" }

    $protoFlags = @()
    if ($transport -eq "http2") { $protoFlags = @("--http2") }

    $argList = @("-c", $ConfigJson, "nativetun", "--always-reconnect",
                 "--keepalive-period", "15s") + $protoFlags
    Write-Log "usque başlatılıyor: $($argList -join ' ')"
    $proc = Start-Process -FilePath $UsqueExe -ArgumentList $argList `
        -RedirectStandardOutput $StdoutLog -RedirectStandardError $StderrLog `
        -NoNewWindow -PassThru
    $usquePid = $proc.Id
} else {
    $usquePid = $usque.Id
    Write-Log "usque zaten çalışıyor (PID $usquePid)."
}

# TUN adapteri görünene dek bekle (koşul-bazlı)
$waited = 0
while (-not (Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue) -and $waited -lt 24) {
    Start-Sleep -Milliseconds 500
    $waited++
}
if (-not (Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue)) {
    throw "TUN adapteri '$TunName' 12sn içinde gelmedi. usque-stderr.log'a bak."
}
Write-Log "TUN '$TunName' ayakta."

# MTU/MSS clamp (Linux'taki 'tcp option maxseg size set 1220' eşdeğeri):
# tünel MTU'su fiziksel'den (1500) küçük. Set etmezsek Windows büyük paket
# gönderir, tünele sığmaz, sessizce düşer -> siteler yarım açılır (HTML gelir,
# resim/CSS/JS gelmez). MTU 1260 -> ilan edilen MSS ~1220 (Linux'un kanıtlı değeri).
Set-NetIPInterface -InterfaceAlias $TunName -NlMtuBytes 1260 -ErrorAction SilentlyContinue
Write-Log "TUN MTU -> 1260 (MSS ~1220; yarım yüklenmeyi önler)."

# --- 2. Default gateway / fiziksel arayüz ---
$defRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -ne "0.0.0.0" } |
            Sort-Object RouteMetric | Select-Object -First 1
if (-not $defRoute) { throw "Default gateway bulunamadı." }
$gwIP      = $defRoute.NextHop
$physIface = (Get-NetAdapter -InterfaceIndex $defRoute.InterfaceIndex).Name
Write-Log "Gateway: $gwIP via $physIface"

# --- 3. Endpoint pin (loop önler) ---
$pins = New-Object System.Collections.Generic.List[string]
function Add-Pin([string]$prefix) {
    if ([string]::IsNullOrWhiteSpace($prefix)) { return }
    Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    New-NetRoute -DestinationPrefix $prefix -InterfaceAlias $physIface -NextHop $gwIP `
        -RouteMetric 1 -ErrorAction SilentlyContinue | Out-Null
    $pins.Add($prefix)
    Write-Log "Endpoint pin: $prefix -> $physIface"
}

# http2 (TCP) ise gerçek endpoint'i bul; bulunamazsa (http3/UDP) WARP aralıklarını pinle
$endpoint = $null
try {
    $endpoint = (Get-NetTCPConnection -OwningProcess $usquePid -RemotePort 443 `
                 -State Established -ErrorAction SilentlyContinue |
                 Select-Object -First 1).RemoteAddress
} catch {}
if ($endpoint) { Add-Pin "$endpoint/32" }
# full modda VEYA endpoint dinamik bulunamadıysa: tüm Cloudflare WARP endpoint
# aralıklarını fiziksel'de pinle ki usque'nin kendi bağlantısı tünele girip loop yapmasın.
if ($scope -eq "full" -or -not $endpoint) {
    foreach ($r in $CfRanges) { Add-Pin $r }
}

# --- 4. Scope'a göre routing ---
if ($scope -eq "full") {
    # split-default: fiziksel default'u SİLMEDEN geçersiz kıl (teardown temiz)
    foreach ($half in @("0.0.0.0/1","128.0.0.0/1")) {
        Get-NetRoute -DestinationPrefix $half -InterfaceAlias $TunName -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        New-NetRoute -DestinationPrefix $half -InterfaceAlias $TunName -RouteMetric 1 `
            -ErrorAction SilentlyContinue | Out-Null
    }
    Set-DnsClientServerAddress -InterfaceAlias $physIface -ServerAddresses @($FullDns) -ErrorAction SilentlyContinue
    Write-Log "FULL: split-default -> $TunName, DNS=$FullDns"
}
else {
    # selective: fiziksel default kalır; TUN yüksek metric. SİSTEM DNS'İNE DOKUNMAYIZ.
    # Sadece blacklist domainleri NRPT ile dnsproxy'ye (clean DNS) yönlendirilir;
    # gerisi normal ISP DNS kullanır (zehirli/normal kalır). dnsproxy ölse bile
    # sadece blacklist çözümü etkilenir, internet ayakta kalır.
    Set-NetIPInterface -InterfaceAlias $TunName -InterfaceMetric 5000 -ErrorAction SilentlyContinue

    # blacklist oku
    $domains = @()
    if (Test-Path $BlacklistTxt) {
        $domains = Get-Content $BlacklistTxt |
            ForEach-Object { ($_ -replace '#.*', '').Trim() } |
            Where-Object { $_ -ne '' } |
            ForEach-Object { (($_ -replace '^\*\.', '') -replace ':\d+.*$', '').TrimEnd('.').ToLower() } |
            Where-Object { $_ -match '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' } |
            Sort-Object -Unique
    }

    # eski NRPT kurallarımızı temizle (NameServers 127.0.0.2 = bizimkiler)
    Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
        Where-Object { $_.NameServers -contains $ListenDns } |
        ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue }

    if ($domains.Count -eq 0) {
        Write-Log "SELECTIVE: blacklist boş — DNS'e dokunulmadı, hiçbir şey unblock edilmedi."
    } else {
        Stop-Process -Name "dnsproxy" -Force -ErrorAction SilentlyContinue
        if (Test-Path $DnsproxyExe) {
            $dnsArgs = @("-l", $ListenDns, "-p", "53", "-u", $UpstreamDns1, "-u", $UpstreamDns2, "--cache")
            $dnsProc = Start-Process -FilePath $DnsproxyExe -ArgumentList $dnsArgs -NoNewWindow -PassThru
            $ok = $false; $tries = 0
            while (-not $ok -and $tries -lt 10) {
                Start-Sleep -Milliseconds 300
                $alive = Get-Process -Id $dnsProc.Id -ErrorAction SilentlyContinue
                $listen = Get-NetUDPEndpoint -LocalAddress $ListenDns -LocalPort 53 -ErrorAction SilentlyContinue
                if ($alive -and $listen) { $ok = $true }
                $tries++
            }
            if ($ok) {
                # dnsproxy upstream sorgularını (1.1.1.1/1.0.0.1) WARP tüneline sok
                # -> DNS cevabı ISP tarafından zehirlenemez, gerçek IP gelir.
                foreach ($r in $Resolvers) {
                    Get-NetRoute -DestinationPrefix "$r/32" -ErrorAction SilentlyContinue |
                        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                    New-NetRoute -DestinationPrefix "$r/32" -InterfaceAlias $TunName -RouteMetric 1 -ErrorAction SilentlyContinue | Out-Null
                }
                # SADECE blacklist domainleri -> dnsproxy (NRPT). Sistem DNS değişmez.
                # Tek çağrıda tüm namespace'ler (324 ayrı cmdlet yerine) -> hızlı.
                $ns = @($domains | ForEach-Object { "." + $_ })
                Add-DnsClientNrptRule -Namespace $ns -NameServers $ListenDns -ErrorAction SilentlyContinue
                Clear-DnsClientCache -ErrorAction SilentlyContinue  # eski zehirli kayıtları at
                Write-Log "SELECTIVE: $($domains.Count) domain NRPT, resolver'lar tünelden (sistem DNS değişmedi)."
            } else {
                Write-Log "UYARI: dnsproxy dinlemedi — NRPT eklenmedi, blacklist devre dışı."
            }
        } else {
            Write-Log "UYARI: dnsproxy.exe yok — blacklist DNS atlandı."
        }
        # route-sync: blacklist IP'lerini WARP'a route et (+IPv6 fail-closed).
        # Bloklamadan başlat -> connect hızlı kalsın (route'lar birkaç sn içinde dolar).
        Start-ScheduledTask -TaskName "WarpTray_RouteSync" -ErrorAction SilentlyContinue
    }
}

# --- 5. state.json yaz (tek doğru kaynak) ---
$state = [ordered]@{
    transport = $transport
    scope     = $scope
    pid       = $usquePid
    endpoint  = $endpoint
    pins      = @($pins)
    started   = (Get-Date).ToString("o")
}
$state | ConvertTo-Json -Compress | Set-Content -Path $StateFile -Encoding UTF8
Write-Log "warp-on OK | $transport/$scope | pid=$usquePid | pins=$($pins -join ',')"
