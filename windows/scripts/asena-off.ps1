#Requires -RunAsAdministrator
<#
.SYNOPSIS
    usque tünelini durdur + tüm Asena routing'i geri al.
    Adımlar birbirinden bağımsız hata-toleranslı; DNS reset ASLA atlanmaz.
#>
Set-StrictMode -Version 1.0
$ErrorActionPreference = "SilentlyContinue"

$DataDir   = Join-Path $env:ProgramData "usque"
$RunDir    = Join-Path $DataDir "run"
$LogFile   = Join-Path $DataDir "usque.log"
$StateFile = Join-Path $RunDir "state.json"
$TunName   = "usque"
$V6Rule    = "AsenaPlug-IPv6-FailClosed"
$ListenDns = "127.0.0.2"

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "$ts  $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

Write-Log "asena-off: teardown başlıyor..."

# state.json (pin/pid bilgisi)
$state = $null
if (Test-Path $StateFile) {
    try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json } catch {}
}

# 1. route-sync watchdog'u durdur
Stop-ScheduledTask -TaskName "AsenaPlug_RouteSync" -ErrorAction SilentlyContinue

# 2. dnsproxy durdur
Stop-Process -Name "dnsproxy" -Force -ErrorAction SilentlyContinue

# 3. usque'yu HEMEN durdur -> TUN adapteri ve üzerindeki TÜM route'lar (split-default
#    + yüzlerce blacklist /32) KENDİLİĞİNDEN uçar. Tek tek silmekten çok daha hızlı.
if ($state -and $state.pid) {
    Stop-Process -Id $state.pid -Force -ErrorAction SilentlyContinue
}
Stop-Process -Name "usque" -Force -ErrorAction SilentlyContinue

# 4. NRPT kurallarımızı kaldır (selective: sistem DNS'ine dokunmadık, sadece
#    blacklist domainlerini dnsproxy'ye yönlendirmiştik)
Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Where-Object { $_.NameServers -contains $ListenDns } |
    ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue }

# 5. Sistem DNS'ini sadece GEREKİYORSA otomatiğe al: full moddaysak (DNS=1.1.1.1
#    yapmıştık), durum bilinmiyorsa, ya da bir adapter hâlâ 127.0.0.2'ye ayarlıysa
#    (eski selective hijack kalıntısı). Temiz selective'de DNS'e dokunmayız.
$resetAll = (-not $state) -or ($state.scope -eq "full")
Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
    $cur = (Get-DnsClientServerAddress -InterfaceAlias $_.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    if ($resetAll -or ($cur -contains $ListenDns)) {
        Set-DnsClientServerAddress -InterfaceAlias $_.Name -ResetServerAddresses -ErrorAction SilentlyContinue
    }
}

# 6. IPv6 firewall kurallarını kaldır (selective fail-closed + full leak-block)
Remove-NetFirewallRule -Group $V6Rule -ErrorAction SilentlyContinue
Remove-NetFirewallRule -Group "AsenaPlug-Full-IPv6Block" -ErrorAction SilentlyContinue

# 7. Endpoint pin route'ları FİZİKSEL arayüzde -> usque ölünce uçmaz, explicit sil
if ($state -and $state.pins) {
    foreach ($prefix in $state.pins) {
        Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# 8. Kalan TUN route'ları (adapter çoğunlukla gitti -> hızlı no-op; güvenlik için)
$tun = Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue
if ($tun) {
    Get-NetRoute -InterfaceIndex $tun.InterfaceIndex -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
}

# 9. state.json sil
Remove-Item $StateFile -Force -ErrorAction SilentlyContinue

# TUN kendiliğinden gitmeli (wintun); ~2sn sonra hâlâ varsa uyar
Start-Sleep -Milliseconds 1500
if (Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue) {
    Write-Log "UYARI: TUN '$TunName' hâlâ duruyor. Sorun sürerse yeniden başlat."
}

Write-Log "asena-off: tamam."
