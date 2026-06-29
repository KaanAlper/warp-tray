#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Start usque MASQUE tunnel + selective routing
#>

param(
    [ValidateSet("http2","http3")]
    [string]$Mode = "http2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#--- Paths
$INSTALL_DIR   = "$env:ProgramFiles\usque"
$USQUE_EXE     = "$INSTALL_DIR\usque.exe"
$DNSPROXY_EXE  = "$INSTALL_DIR\dnsproxy.exe"
$CONFIG_JSON   = "$env:USERPROFILE\config.json"
$ROUTE_CONF    = "$env:APPDATA\warp-tray\warp-route.conf"
$BLACKLIST_TXT = "$env:APPDATA\warp-tray\warp-blacklist.txt"
$LOG_FILE      = "$env:ProgramData\usque\usque.log"
$TUNNEL_LOG    = "$env:ProgramData\usque\usque-tunnel.log" # YENI DOSYA EKLENDÝ
$RUN_DIR       = "$env:ProgramData\usque\run"
$PID_FILE      = "$RUN_DIR\usque.pid"
$DNS_PID_FILE  = "$RUN_DIR\dnsproxy.pid"
$TUN_NAME      = "usque"
$WARP_TABLE    = 201   
$MASQUE_IP     = "162.159.198.2"
$LISTEN_DNS    = "127.0.0.2"
$UPSTREAM_DNS  = "77.88.8.8:1253"
$UPSTREAM_DNS2 = "77.88.8.1:1253"

#--- Ensure dirs
foreach ($d in @($RUN_DIR, (Split-Path $LOG_FILE))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ENCODING VE KÝLÝT ÇÖZÜMÜ
function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LOG_FILE -Value "$ts  $msg" -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Get-DefaultGateway {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
             Sort-Object RouteMetric | Select-Object -First 1
    if (-not $route) { throw "No default gateway found" }
    return $route
}

function Get-TunInterface {
    return Get-NetAdapter | Where-Object { $_.Name -eq $TUN_NAME } | Select-Object -First 1
}

#=== 1. Start usque if not running ===========================================
Write-Log "warp-on: mode=$Mode"

$usqueRunning = Get-Process -Name "usque" -ErrorAction SilentlyContinue
if (-not $usqueRunning) {
    if (-not (Test-Path $USQUE_EXE)) {
        throw "usque.exe not found at $USQUE_EXE"
    }
    if (-not (Test-Path $CONFIG_JSON)) {
        throw "config.json not found at $CONFIG_JSON. Run: usque register"
    }

    $protoFlags = if ($Mode -eq "http2") { @("--http2") } else { @() }

    Write-Log "Starting usque nativetun ($Mode)..."
    
    # TÜNEL LOGLARI ÝÇÝN ÝKÝ AYRI DOSYA KULLANIYORUZ
    $STDOUT_LOG = "$env:ProgramData\usque\usque-stdout.log"
    $STDERR_LOG = "$env:ProgramData\usque\usque-stderr.log"

    Write-Log "Starting usque nativetun ($Mode)..."
    
    $proc = Start-Process -FilePath $USQUE_EXE `
        -ArgumentList (@("-c", $CONFIG_JSON, "nativetun", "--always-reconnect", "--keepalive-period", "15s") + $protoFlags) `
        -RedirectStandardOutput $STDOUT_LOG `
        -RedirectStandardError  $STDERR_LOG `
        -NoNewWindow -PassThru
    $proc.Id | Set-Content $PID_FILE

    $waited = 0
    while (-not (Get-TunInterface) -and $waited -lt 10) {
        Start-Sleep -Milliseconds 500
        $waited++
    }
    if (-not (Get-TunInterface)) {
        throw "TUN adapter '$TUN_NAME' did not appear after 5s."
    }
    Write-Log "TUN adapter '$TUN_NAME' is up."
} else {
    Write-Log "usque already running (PID $($usqueRunning.Id)), skipping start."
}

#=== 2. Routing setup ========================================================
$defaultRoute = Get-DefaultGateway
$gwIP         = $defaultRoute.NextHop
$physIface    = (Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex).Name
$tunIface     = (Get-TunInterface).Name

Write-Log "Gateway: $gwIP via $physIface | TUN: $tunIface"

$masqueExists = Get-NetRoute -DestinationPrefix "$MASQUE_IP/32" -ErrorAction SilentlyContinue
if ($masqueExists) { Remove-NetRoute -DestinationPrefix "$MASQUE_IP/32" -Confirm:$false -ErrorAction SilentlyContinue }
New-NetRoute -DestinationPrefix "$MASQUE_IP/32" -InterfaceAlias $physIface -NextHop $gwIP -RouteMetric 1 | Out-Null
Write-Log "Pinned MASQUE endpoint $MASQUE_IP -> $physIface"

Set-NetIPInterface -InterfaceAlias $tunIface -InterfaceMetric 5000 -ErrorAction SilentlyContinue

#=== 3. Interface routing ====================================================
$ifaceCount = 0
if (Test-Path $ROUTE_CONF) {
    $lines = Get-Content $ROUTE_CONF
    foreach ($rawLine in $lines) {
        $line = ($rawLine -replace '#.*', '').Trim()
        if ($line -match '^iface\s+(\S+)') {
            $iface = $Matches[1]
            $exists = Get-NetAdapter -Name $iface -ErrorAction SilentlyContinue
            if ($exists) {
                Get-NetRoute -InterfaceAlias $iface -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                New-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceAlias $tunIface -RouteMetric 10 | Out-Null
                Write-Log "Interface $iface -> routed via TUN"
                $ifaceCount++
            } else {
                Write-Log "WARNING: Interface '$iface' not found, skipping."
            }
        }
    }
}

#=== 4. Domain blacklist -> DNS -> route IPs through TUN =====================
$dnsRunning = Get-Process -Name "dnsproxy" -ErrorAction SilentlyContinue
if ($dnsRunning) {
    Stop-Process -Name "dnsproxy" -Force -ErrorAction SilentlyContinue
}

if (Test-Path $BLACKLIST_TXT) {
    if (-not (Test-Path $DNSPROXY_EXE)) {
        Write-Log "WARNING: dnsproxy.exe not found! Blacklist DNS intercept will be skipped."
    } else {
        Write-Log "Starting dnsproxy on $LISTEN_DNS..."
        $dnsArgs = @("-l", $LISTEN_DNS, "-p", "53", "-u", $UPSTREAM_DNS, "-u", $UPSTREAM_DNS2, "--cache")
        $dnsProc = Start-Process -FilePath $DNSPROXY_EXE -ArgumentList $dnsArgs -NoNewWindow -PassThru
        $dnsProc.Id | Set-Content $DNS_PID_FILE

        Set-DnsClientServerAddress -InterfaceAlias $physIface -ServerAddresses @($LISTEN_DNS, "1.1.1.1")
        Write-Log "DNS -> $LISTEN_DNS (dnsproxy, upstream: $UPSTREAM_DNS)"
    }
} else {
    Write-Log "No blacklist found at $BLACKLIST_TXT, skipping DNS setup."
}

#=== 5. Start RouteSync Watchdog =============================================
Write-Log "Starting RouteSync Watchdog task..."
Start-ScheduledTask -TaskName "WarpTray_RouteSync" -ErrorAction SilentlyContinue

Write-Log "warp-on OK | mode=$Mode | gw=$gwIP | phys=$physIface | tun=$tunIface | ifaces=$ifaceCount"