#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Reload blacklist DNS routing. Windows equivalent of warp-dns-reload.
    Flushes DNS cache, re-resolves all blacklisted domains, updates routes.
#>

$TUN_NAME = "usque"
$LOG_FILE = "$env:ProgramData\usque\usque.log"

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LOG_FILE -Value "$ts  $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

$tunAdapter = Get-NetAdapter -Name $TUN_NAME -ErrorAction SilentlyContinue
if (-not $tunAdapter) {
    Write-Warning "WARP kapali, DNS yenileme atlandi."
    exit 0
}

Write-Log "warp-dns-reload: flushing DNS cache..."
Clear-DnsClientCache

# Remove all existing blacklist-derived routes via TUN
$RESOLVED_FILE = "$env:ProgramData\usque\run\warp-resolved-ips.txt"
if (Test-Path $RESOLVED_FILE) {
    Get-Content $RESOLVED_FILE | ForEach-Object {
        $ip = $_.Trim()
        if ($ip) {
            Remove-NetRoute -DestinationPrefix "$ip/32" -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    Remove-Item $RESOLVED_FILE -Force -ErrorAction SilentlyContinue
}

Write-Log "warp-dns-reload: re-resolving domains..."
& "$PSScriptRoot\warp-route-sync.ps1"
Write-Log "warp-dns-reload: done."
Write-Host "DNS reloaded."
