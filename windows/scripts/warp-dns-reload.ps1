#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Blacklist DNS/route'larını taze yenile: DNS cache flush, mevcut /32
    blacklist route'larını temizle, route-sync'i yeniden başlat (sıfırdan çözer).
#>
Set-StrictMode -Version 1.0
$ErrorActionPreference = "SilentlyContinue"

$DataDir      = Join-Path $env:ProgramData "usque"
$RunDir       = Join-Path $DataDir "run"
$LogFile      = Join-Path $DataDir "usque.log"
$ResolvedFile = Join-Path $RunDir "warp-resolved-ips.txt"
$TunName      = "usque"
$V6Rule       = "WarpTray-IPv6-FailClosed"

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "$ts  [dns-reload] $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

$tun = Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue
if (-not $tun) {
    Write-Log "WARP kapalı — atlandı."
    exit 0
}

Write-Log "DNS cache flush..."
Clear-DnsClientCache -ErrorAction SilentlyContinue

# route-sync'i durdur, /32 blacklist route'larını + v6 kuralını + defteri temizle
Stop-ScheduledTask -TaskName "WarpTray_RouteSync" -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

# Sadece /32 host route'larını kaldır (split-default /1'lere dokunma)
Get-NetRoute -InterfaceIndex $tun.InterfaceIndex -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -like "*/32" } |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

Remove-NetFirewallRule -Group $V6Rule -ErrorAction SilentlyContinue
Remove-Item $ResolvedFile -Force -ErrorAction SilentlyContinue

# Taze yeniden başlat
Start-ScheduledTask -TaskName "WarpTray_RouteSync" -ErrorAction SilentlyContinue
Write-Log "tamam — route-sync yeniden başlatıldı."
