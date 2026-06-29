#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sürekli çalýþan arka plan DNS-Route eþleyici (Daemon Mode).
    WARP açýk olduðu sürece çalýþýr, blacklist'teki domainleri sürekli çözer
    ve anýnda TUN adaptörüne yönlendirir.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

$BLACKLIST_TXT = "$env:APPDATA\warp-tray\warp-blacklist.txt"
$RESOLVED_FILE = "$env:ProgramData\usque\run\warp-resolved-ips.txt"
$TUN_NAME      = "usque"

$knownIPs = @{}
if (Test-Path $RESOLVED_FILE) {
    Get-Content $RESOLVED_FILE | ForEach-Object {
        if ($_.Trim()) { $knownIPs[$_.Trim()] = $true }
    }
}

# Sonsuz döngü (WARP kapanana veya görev sonlandýrýlana kadar çalýþýr)
while ($true) {
    $tunAdapter = Get-NetAdapter -Name $TUN_NAME -ErrorAction SilentlyContinue
    if (-not $tunAdapter) {
        # WARP kapalýysa scripti sonlandýr
        exit 0
    }

    if (Test-Path $BLACKLIST_TXT) {
        $domains = Get-Content $BLACKLIST_TXT |
            Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' } |
            ForEach-Object { $_ -replace '^\*\.', '' } | Sort-Object -Unique

        $added = 0
        $currentNewIPs = [System.Collections.Generic.List[string]]::new()

        foreach ($domain in $domains) {
            try {
                $resolved = [System.Net.Dns]::GetHostAddresses($domain) |
                    Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                    ForEach-Object { $_.ToString() }

                foreach ($ip in $resolved) {
                    $currentNewIPs.Add($ip)
                    if (-not $knownIPs.ContainsKey($ip)) {
                        # Yeni IP tespit edildi, anýnda route ekle
                        $existing = Get-NetRoute -DestinationPrefix "$ip/32" -ErrorAction SilentlyContinue
                        if (-not $existing) {
                            New-NetRoute -DestinationPrefix "$ip/32" -InterfaceAlias $TUN_NAME -RouteMetric 1 | Out-Null
                            $added++
                        }
                        $knownIPs[$ip] = $true
                    }
                }
            } catch {}
        }

        if ($added -gt 0) {
            # Yeni IP'leri txt'ye kaydet
            $currentNewIPs | Sort-Object -Unique | Set-Content $RESOLVED_FILE
        }
    }
    
    # Ýþlemciyi yormamak için 10 saniye uyu (Bu süreyi ihtiyacýna göre kýsaltabilirsin)
    Start-Sleep -Seconds 10
}