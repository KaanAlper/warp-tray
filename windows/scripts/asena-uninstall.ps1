#Requires -RunAsAdministrator
<#
.SYNOPSIS
    AsenaPlug'ı temiz kaldır: önce TÜM Asena durumunu geri al (NRPT, IPv6 firewall,
    route, DNS reset, usque/dnsproxy durdur), sonra görevleri/kısayolu/dosyaları sil.
    Kimliğin (config.json) korunur — silmek istersen elle.
#>
Set-StrictMode -Version 1.0
$ErrorActionPreference = "SilentlyContinue"

$ProgramFilesDir = Join-Path $env:ProgramFiles "usque"

# 1. Teardown (NRPT, firewall, route, DNS reset, usque/dnsproxy durdur)
$off = Join-Path $PSScriptRoot "asena-off.ps1"
if (Test-Path $off) { & $off }

# 2. Emniyet: asena-off açık değilken de kalmış olabilecekleri temizle
Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Where-Object { $_.NameServers -contains "127.0.0.2" } |
    ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue }
Remove-NetFirewallRule -Group "AsenaPlug-IPv6-FailClosed" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -Group "AsenaPlug-Full-IPv6Block" -ErrorAction SilentlyContinue
Stop-Process -Name "usque", "dnsproxy" -Force -ErrorAction SilentlyContinue

# 3. Scheduled task'lar
"AsenaPlug_Tray", "AsenaPlug_RouteSync", "AsenaPlug_Rescue" | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue
}

# 4. Masaüstü kısayolu
Remove-Item (Join-Path $env:USERPROFILE "Desktop\AsenaPlug.lnk") -Force -ErrorAction SilentlyContinue

# 5. Program dosyaları (Program Files\usque)
Remove-Item $ProgramFilesDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "AsenaPlug kaldırıldı." -ForegroundColor Green
Write-Host "Asena kimliğin (config.json) burada KORUNDU:" -ForegroundColor Yellow
Write-Host "  $env:ProgramData\usque\config\config.json"
Write-Host "Tamamen silmek istersen (kimlik dahil, yedekle!):"
Write-Host "  Remove-Item '$env:ProgramData\usque' -Recurse -Force"
