#Requires -RunAsAdministrator
<#
.SYNOPSIS
    usque tünelini durdur + tüm WARP routing'i geri al.
    Adımlar birbirinden bağımsız hata-toleranslı; DNS reset ASLA atlanmaz.
#>
Set-StrictMode -Version 1.0
$ErrorActionPreference = "SilentlyContinue"

$DataDir   = Join-Path $env:ProgramData "usque"
$RunDir    = Join-Path $DataDir "run"
$LogFile   = Join-Path $DataDir "usque.log"
$StateFile = Join-Path $RunDir "state.json"
$TunName   = "usque"
$V6Rule    = "WarpTray-IPv6-FailClosed"

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "$ts  $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

Write-Log "warp-off: teardown başlıyor..."

# state.json (pin/pid bilgisi)
$state = $null
if (Test-Path $StateFile) {
    try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json } catch {}
}

# 1. route-sync watchdog'u durdur
Stop-ScheduledTask -TaskName "WarpTray_RouteSync" -ErrorAction SilentlyContinue

# 2. dnsproxy durdur
Stop-Process -Name "dnsproxy" -Force -ErrorAction SilentlyContinue

# 3. DNS'i her adapterde otomatiğe al (HER ZAMAN — internet geri gelsin)
Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
    Set-DnsClientServerAddress -InterfaceAlias $_.Name -ResetServerAddresses -ErrorAction SilentlyContinue
}

# 4. IPv6 fail-closed firewall kuralını kaldır
Remove-NetFirewallRule -Group $V6Rule -ErrorAction SilentlyContinue

# 5. TUN üzerindeki tüm route'ları kaldır (split-default + blacklist /32)
$tun = Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue
if ($tun) {
    Get-NetRoute -InterfaceIndex $tun.InterfaceIndex -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
}

# 6. Endpoint pin route'larını kaldır
if ($state -and $state.pins) {
    foreach ($prefix in $state.pins) {
        Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# 7. usque'yu durdur (önce state'teki pid, sonra isimle)
if ($state -and $state.pid) {
    Stop-Process -Id $state.pid -Force -ErrorAction SilentlyContinue
}
Stop-Process -Name "usque" -Force -ErrorAction SilentlyContinue

# 8. state.json sil
Remove-Item $StateFile -Force -ErrorAction SilentlyContinue

# TUN kendiliğinden gitmeli (wintun); ~2sn sonra hâlâ varsa uyar
Start-Sleep -Milliseconds 1500
if (Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue) {
    Write-Log "UYARI: TUN '$TunName' hâlâ duruyor. Sorun sürerse yeniden başlat."
}

Write-Log "warp-off: tamam."
