#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Reload interface routing from warp-route.conf without restarting WARP.
    Windows equivalent of warp-bypass-reload.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

$ROUTE_CONF = "$env:APPDATA\warp-tray\warp-route.conf"
$TUN_NAME   = "usque"
$LOG_FILE   = "$env:ProgramData\usque\usque.log"

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LOG_FILE -Value "$ts  $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

$tunAdapter = Get-NetAdapter -Name $TUN_NAME -ErrorAction SilentlyContinue
if (-not $tunAdapter) {
    Write-Log "warp-bypass-reload: WARP not active, skip."
    exit 0
}

$ifaceCount = 0
if (Test-Path $ROUTE_CONF) {
    Get-Content $ROUTE_CONF | ForEach-Object {
        $line = ($_ -replace '#.*', '').Trim()
        if ($line -match '^iface\s+(\S+)') {
            $iface = $Matches[1]
            $adapter = Get-NetAdapter -Name $iface -ErrorAction SilentlyContinue
            if ($adapter) {
                New-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceAlias $TUN_NAME -RouteMetric 10 `
                    -ErrorAction SilentlyContinue | Out-Null
                Write-Log "warp-bypass-reload: $iface -> TUN"
                $ifaceCount++
            }
        }
    }
}

Write-Log "warp-bypass-reload: iface_count=$ifaceCount"