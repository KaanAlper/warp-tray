#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Kurtarma görevi (boot + logon'da tetiklenir). Çökme / elektrik kesintisi
    sonrası Asena düzgün kapanamadıysa: DNS'i otomatiğe alır, IPv6 fail-closed
    kuralını ve TUN üzerindeki artık route'ları temizler ki sistem temiz açılsın.
#>
Set-StrictMode -Version 1.0
$ErrorActionPreference = "SilentlyContinue"

$DataDir   = Join-Path $env:ProgramData "usque"
$LogFile   = Join-Path $DataDir "usque.log"
$TunName   = "usque"
$V6Rule    = "AsenaPlug-IPv6-FailClosed"
$ListenDns = "127.0.0.2"

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "$ts  [rescue] $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

# usque ayakta değilken (boot/logon ya da çökme sonrası) artık Asena yapılandırması
# varsa temizle ki internet kesin gelsin (kullanıcının korkusu: elektrik gidince
# DNS 127.0.0.2'de takılı kalması).
if (-not (Get-Process -Name "usque" -ErrorAction SilentlyContinue)) {
    # NRPT kurallarımızı kaldır
    Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
        Where-Object { $_.NameServers -contains $ListenDns } |
        ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue }

    # Sistem DNS'i 127.0.0.2'de KALMIŞ adapterleri otomatiğe al (tehlikeli kalıntı;
    # bunu yapmazsak internet gelmez). Kullanıcının kendi DNS'ine dokunmamak için
    # SADECE 127.0.0.2 olanları sıfırlarız.
    Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
        $cur = (Get-DnsClientServerAddress -InterfaceAlias $_.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        if ($cur -contains $ListenDns) {
            Set-DnsClientServerAddress -InterfaceAlias $_.Name -ResetServerAddresses -ErrorAction SilentlyContinue
        }
    }

    Remove-NetFirewallRule -Group $V6Rule -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -Group "AsenaPlug-Full-IPv6Block" -ErrorAction SilentlyContinue

    $tun = Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue
    if ($tun) {
        Get-NetRoute -InterfaceIndex $tun.InterfaceIndex -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Log "kurtarma: NRPT/DNS(127.0.0.2)/firewall/route artıkları temizlendi."
}
