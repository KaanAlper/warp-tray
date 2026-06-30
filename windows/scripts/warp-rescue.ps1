#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Kurtarma görevi (boot + logon'da tetiklenir). Çökme / elektrik kesintisi
    sonrası WARP düzgün kapanamadıysa: DNS'i otomatiğe alır, IPv6 fail-closed
    kuralını ve TUN üzerindeki artık route'ları temizler ki sistem temiz açılsın.
#>
Set-StrictMode -Version 1.0
$ErrorActionPreference = "SilentlyContinue"

$DataDir = Join-Path $env:ProgramData "usque"
$LogFile = Join-Path $DataDir "usque.log"
$TunName = "usque"
$V6Rule  = "WarpTray-IPv6-FailClosed"

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "$ts  [rescue] $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

# usque ayakta değilken artık WARP yapılandırması varsa temizle
if (-not (Get-Process -Name "usque" -ErrorAction SilentlyContinue)) {
    Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
        Set-DnsClientServerAddress -InterfaceAlias $_.Name -ResetServerAddresses -ErrorAction SilentlyContinue
    }
    Remove-NetFirewallRule -Group $V6Rule -ErrorAction SilentlyContinue

    $tun = Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue
    if ($tun) {
        Get-NetRoute -InterfaceIndex $tun.InterfaceIndex -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Log "kurtarma: DNS/firewall/route artıkları temizlendi."
}
