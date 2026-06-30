#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Blacklist değişince taze yenile: NRPT kurallarını blacklist'e göre yeniden kur
    (sadece listedeki domainler dnsproxy/clean DNS'e gider; sistem DNS değişmez),
    dnsproxy'yi diri tut, /32 route'ları + DNS cache'i temizleyip route-sync'i
    sıfırdan başlat.
#>
Set-StrictMode -Version 1.0
$ErrorActionPreference = "SilentlyContinue"

$DataDir      = Join-Path $env:ProgramData "usque"
$ConfigDir    = Join-Path $DataDir "config"
$RunDir       = Join-Path $DataDir "run"
$LogFile      = Join-Path $DataDir "usque.log"
$BlacklistTxt = Join-Path $ConfigDir "warp-blacklist.txt"
$ResolvedFile = Join-Path $RunDir "warp-resolved-ips.txt"
$DnsproxyExe  = Join-Path (Join-Path $env:ProgramFiles "usque") "dnsproxy.exe"
$TunName      = "usque"
$V6Rule       = "WarpTray-IPv6-FailClosed"
$ListenDns    = "127.0.0.2"
$UpstreamDns1 = "77.88.8.8:1253"
$UpstreamDns2 = "77.88.8.1:1253"

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "$ts  [dns-reload] $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

$tun = Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue
if (-not $tun) {
    Write-Log "WARP kapalı — atlandı."
    exit 0
}

Clear-DnsClientCache -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName "WarpTray_RouteSync" -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

# Eski /32 host route'ları + v6 kuralı + defter + eski NRPT kurallarımızı temizle
Get-NetRoute -InterfaceIndex $tun.InterfaceIndex -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -like "*/32" } |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetFirewallRule -Group $V6Rule -ErrorAction SilentlyContinue
Remove-Item $ResolvedFile -Force -ErrorAction SilentlyContinue
Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Where-Object { $_.NameServers -contains $ListenDns } |
    ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue }

# Blacklist oku
$domains = @()
if (Test-Path $BlacklistTxt) {
    $domains = Get-Content $BlacklistTxt |
        ForEach-Object { ($_ -replace '#.*', '').Trim() } |
        Where-Object { $_ -ne '' } |
        ForEach-Object { ($_ -replace '^\*\.', '').TrimEnd('.').ToLower() } |
        Sort-Object -Unique
}

if ($domains.Count -eq 0) {
    Stop-Process -Name "dnsproxy" -Force -ErrorAction SilentlyContinue
    Write-Log "blacklist boş — NRPT/dnsproxy kaldırıldı, hiçbir şey unblock edilmiyor."
    exit 0
}

# dnsproxy diri mi? değilse başlat + dinlediğini doğrula
if (-not (Get-Process -Name "dnsproxy" -ErrorAction SilentlyContinue)) {
    if (Test-Path $DnsproxyExe) {
        Start-Process -FilePath $DnsproxyExe -ArgumentList @(
            "-l", $ListenDns, "-p", "53", "-u", $UpstreamDns1, "-u", $UpstreamDns2, "--cache"
        ) -NoNewWindow -ErrorAction SilentlyContinue
    }
}
$ok = $false; $tries = 0
while (-not $ok -and $tries -lt 10) {
    Start-Sleep -Milliseconds 300
    if ((Get-Process -Name "dnsproxy" -ErrorAction SilentlyContinue) -and
        (Get-NetUDPEndpoint -LocalAddress $ListenDns -LocalPort 53 -ErrorAction SilentlyContinue)) { $ok = $true }
    $tries++
}

if ($ok) {
    foreach ($d in $domains) {
        Add-DnsClientNrptRule -Namespace ("." + $d) -NameServers $ListenDns -ErrorAction SilentlyContinue
    }
    Start-ScheduledTask -TaskName "WarpTray_RouteSync" -ErrorAction SilentlyContinue
    Write-Log "tamam — $($domains.Count) domain NRPT'ye eklendi, route-sync başlatıldı."
} else {
    Write-Log "UYARI: dnsproxy dinlemedi — NRPT eklenmedi."
}
