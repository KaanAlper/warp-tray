#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Stop usque tunnel + teardown all WARP routing. Windows port of warp-off.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

$INSTALL_DIR   = "$env:ProgramFiles\usque"
$RUN_DIR       = "$env:ProgramData\usque\run"
$PID_FILE      = "$RUN_DIR\usque.pid"
$DNS_PID_FILE  = "$RUN_DIR\dnsproxy.pid"
$MASQUE_IP     = "162.159.198.2"
$TUN_NAME      = "usque"
$LOG_FILE      = "$env:ProgramData\usque\usque.log"

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LOG_FILE -Value "$ts  $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

Write-Log "warp-off: starting teardown..."

#--- Stop dnsproxy
if (Test-Path $DNS_PID_FILE) {
    $dpid = Get-Content $DNS_PID_FILE -ErrorAction SilentlyContinue
    if ($dpid) { Stop-Process -Id $dpid -Force -ErrorAction SilentlyContinue }
    Remove-Item $DNS_PID_FILE -Force -ErrorAction SilentlyContinue
}
Stop-Process -Name "dnsproxy" -Force -ErrorAction SilentlyContinue

#--- Restore DNS on all adapters to automatic
Get-NetAdapter | ForEach-Object {
    Set-DnsClientServerAddress -InterfaceAlias $_.Name -ResetServerAddresses -ErrorAction SilentlyContinue
}

#--- Remove MASQUE pinned route
Remove-NetRoute -DestinationPrefix "$MASQUE_IP/32" -Confirm:$false -ErrorAction SilentlyContinue

#--- Remove any routes via TUN
$tunAdapter = Get-NetAdapter -Name $TUN_NAME -ErrorAction SilentlyContinue
if ($tunAdapter) {
    Get-NetRoute -InterfaceIndex $tunAdapter.InterfaceIndex -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
}

#--- Stop usque
if (Test-Path $PID_FILE) {
    $upid = Get-Content $PID_FILE -ErrorAction SilentlyContinue
    if ($upid) { Stop-Process -Id $upid -Force -ErrorAction SilentlyContinue }
    Remove-Item $PID_FILE -Force -ErrorAction SilentlyContinue
}
Stop-Process -Name "usque" -Force -ErrorAction SilentlyContinue

Start-Sleep -Milliseconds 800

#--- TUN adapter should auto-remove when usque exits (wintun handles this)
#    If it's still there after 2s, log a warning.
Start-Sleep -Milliseconds 1200
if (Get-NetAdapter -Name $TUN_NAME -ErrorAction SilentlyContinue) {
    Write-Log "WARNING: TUN adapter '$TUN_NAME' still present. Reboot if issues persist."
}

#=== YENÝ: Watchdog'u durdur ===
Write-Log "Stopping RouteSync Watchdog task..."
Stop-ScheduledTask -TaskName "WarpTray_RouteSync" -ErrorAction SilentlyContinue

Write-Log "warp-off: done."
Write-Host "WARP off."
