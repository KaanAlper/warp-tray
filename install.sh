#!/usr/bin/env bash
# Cloudflare MASQUE (usque) — selective routing tray for Hyprland.
#
# Physical internet is the default. Only apps listed in asena-route.conf and
# domains in asena-blacklist.txt are routed through Asena.
#
# Tested on: CachyOS / Arch Linux + Hyprland (illogical-impulse / end-4 dots).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/KaanAlper/AsenaPlug/main/install.sh | bash
# or, after cloning:
#   ./install.sh
set -euo pipefail

#=== Identity ==================================================================
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
TARGET_UID=$(id -u "$TARGET_USER")
[ -z "$TARGET_HOME" ] && { echo "ERROR: cannot resolve home for $TARGET_USER" >&2; exit 1; }

say() { printf "\033[1;36m::\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*" >&2; }
die() { printf "\033[1;31mXX\033[0m %s\n" "$*" >&2; exit 1; }

#=== Sanity ====================================================================
say "Target user: $TARGET_USER (home: $TARGET_HOME, uid: $TARGET_UID)"
[ -f /etc/arch-release ] || warn "Not Arch — pacman/yay paths may fail."

if [ "$(id -u)" -ne 0 ]; then
    say "Re-launching under sudo for system installs…"
    exec sudo -E "$0" "$@"
fi

HAVE_YAY=0
if sudo -u "$TARGET_USER" command -v yay >/dev/null 2>&1; then
    HAVE_YAY=1
fi

#=== Dependencies ==============================================================
say "Installing system packages…"
pacman -S --needed --noconfirm \
    python-pyside6 libnotify sudo iproute2 systemd dnsmasq nftables >/dev/null

if ! command -v usque >/dev/null 2>&1; then
    if [ "$HAVE_YAY" -eq 1 ]; then
        say "Installing usque from AUR…"
        sudo -u "$TARGET_USER" yay -S --needed --noconfirm usque-bin || \
        sudo -u "$TARGET_USER" yay -S --needed --noconfirm usque || \
            die "Could not install usque. Install manually (https://github.com/Diniboy1123/usque)"
    else
        die "yay not found and usque missing. Install yay (or usque manually) then re-run."
    fi
fi

#=== /usr/local/bin/asena-on ===================================================
say "Writing /usr/local/bin/asena-on…"
cat > /usr/local/bin/asena-on << 'EOF'
#!/usr/bin/env bash
# Asena nativetun start — physical is default, only listed apps/ifaces/domains go through Asena.
# Usage: asena-on [http2|http3]   (default: http2)
# Runs as root via sudoers NOPASSWD.
set -e

MODE="${1:-http2}"
case "$MODE" in
    http2) PROTO_FLAGS="--http2" ;;
    http3) PROTO_FLAGS="" ;;
    *) echo "Usage: asena-on [http2|http3]" >&2; exit 2 ;;
esac

MASQUE_IP="162.159.198.2"
ASENA_TABLE=201
ASENA_MARK=0x43
SLICE_NAME="asena-only.slice"
RUN_DIR="/run/asena"

# Hedef kullaniciyi runtime'da belirle (hardcode yok):
#   sudo ile cagrildiysa SUDO_USER, degilse ilk normal kullanici (uid 1000).
USER_NAME="${SUDO_USER:-}"
{ [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ]; } && USER_NAME=$(id -nu 1000 2>/dev/null)
[ -z "$USER_NAME" ] && { echo "ERROR: hedef kullanici bulunamadi" >&2; exit 1; }
USER_UID=$(id -u "$USER_NAME")
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
[ -z "$USER_HOME" ] && { echo "ERROR: $USER_NAME icin home bulunamadi" >&2; exit 1; }

USQUE_DIR="$USER_HOME"
USQUE_CONFIG="${USQUE_DIR}/config.json"
ROUTE_CONF="$USER_HOME/.config/asena-route.conf"

GW=$(ip -4 route show default proto dhcp 2>/dev/null | awk '{print $3; exit}')
DEV=$(ip -4 route show default proto dhcp 2>/dev/null | awk '{print $5; exit}')
if [ -z "$GW" ]; then
    GW=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    DEV=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
fi
[ -z "$GW" ] || [ -z "$DEV" ] && { echo "ERROR: no default gateway" >&2; exit 1; }

if ! pgrep -x usque >/dev/null; then
    cd "$USQUE_DIR"
    nohup usque -c "$USQUE_CONFIG" nativetun \
        --always-reconnect \
        --keepalive-period 15s \
        $PROTO_FLAGS \
        >/var/log/usque.log 2>&1 &
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        ip link show tun0 >/dev/null 2>&1 && break
        sleep 0.5
    done
fi

# MASQUE endpoint dogrudan physical uzerinden cikmali.
ip route replace "${MASQUE_IP}/32" via "$GW" dev "$DEV"

# Physical default route korunuyor — tun0 default yapilmiyor.
ip route flush table "$ASENA_TABLE" 2>/dev/null || true
ip route add default dev tun0 table "$ASENA_TABLE"
ip rule del fwmark "$ASENA_MARK" 2>/dev/null || true
ip rule add fwmark "$ASENA_MARK" table "$ASENA_TABLE" priority 100

# rp_filter: asimetrik routing icin gevsetilir. Mevcut deger saklanir, asena-off geri yukler.
mkdir -p "$RUN_DIR" 2>/dev/null || true
sysctl -n net.ipv4.conf.all.rp_filter > "$RUN_DIR/rpfilter.all" 2>/dev/null || true
sysctl -n "net.ipv4.conf.${DEV}.rp_filter" > "$RUN_DIR/rpfilter.dev" 2>/dev/null || true
printf '%s\n' "$DEV" > "$RUN_DIR/rpfilter.devname" 2>/dev/null || true
sysctl -wq net.ipv4.conf.all.rp_filter=2
sysctl -wq "net.ipv4.conf.${DEV}.rp_filter=2" 2>/dev/null || true

# asena-only.slice icin cgroup path'i al.
runuser -u "$USER_NAME" -- env XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    systemctl --user start "$SLICE_NAME" 2>/dev/null || true
SLICE_PATH=$(runuser -u "$USER_NAME" -- env XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    systemctl --user show -p ControlGroup --value "$SLICE_NAME" 2>/dev/null)

if [ -n "$SLICE_PATH" ] && [ -d "/sys/fs/cgroup${SLICE_PATH}" ]; then
    SLICE_REL_PATH="${SLICE_PATH#/}"
    IFS=/ read -ra _parts <<< "$SLICE_REL_PATH"
    SLICE_LEVEL=${#_parts[@]}
else
    SLICE_REL_PATH=""
    SLICE_LEVEL=""
fi

# nft tablosu ve zincirler.
nft delete table inet asena_route 2>/dev/null || true
nft delete table ip asena_nat 2>/dev/null || true
nft add table inet asena_route
nft -- add chain inet asena_route prerouting  '{ type filter hook prerouting priority -150 ; }'
nft -- add chain inet asena_route postrouting '{ type filter hook postrouting priority -150 ; }'
# TCP MSS clamp: tun0 MTU=1280 vs LAN MTU=1500 uyusmazligini onler (TLS handshake drop).
nft add rule inet asena_route postrouting oifname tun0 tcp flags syn tcp option maxseg size set 1220
# IPv4 mark/route zinciri.
nft -- add chain inet asena_route output  '{ type route  hook output priority -150 ; }'
# IPv6 fail-closed zinciri (ayri filter chain, reject icin).
nft -- add chain inet asena_route output6 '{ type filter hook output priority -150 ; }'

# Domain tabanli IP set'leri — dnsmasq DNS sorgularinda doldurur. Timeout 1h.
nft add set inet asena_route asena_hosts \
    '{ type ipv4_addr ; flags interval,timeout ; timeout 3600s ; }'
nft add set inet asena_route asena_hosts6 \
    '{ type ipv6_addr ; flags interval,timeout ; timeout 3600s ; }'

# --- IPv4: conntrack mark save/restore + marking (output, type route) ---
# 1) Established baglanti: bizim connmark'imiz varsa packet mark'a geri yukle.
#    Boylece set TTL'i dolsa bile aktif baglanti Asena'ta kalir (kopmaz/leak olmaz).
nft add rule inet asena_route output ct mark "$ASENA_MARK" meta mark set "$ASENA_MARK"
# 2) Blacklist domainleri ve cgroup app'larini damgala.
nft add rule inet asena_route output ip daddr @asena_hosts counter meta mark set "$ASENA_MARK"
if [ -n "$SLICE_REL_PATH" ]; then
    nft "add rule inet asena_route output socket cgroupv2 level $SLICE_LEVEL \"$SLICE_REL_PATH\" counter meta mark set $ASENA_MARK"
fi
# 3) Bizim mark'imizi connmark'a kaydet (sonraki paketler restore edebilsin).
nft add rule inet asena_route output meta mark "$ASENA_MARK" ct mark set "$ASENA_MARK"

# --- IPv6 fail-closed: Asena'lik v6 trafigini reddet -> app v4'e duser -> Asena ---
# (tun0 v6 tasimadigi icin v6'yi tunele sokmak yerine kapatip v4'e zorluyoruz.)
nft add rule inet asena_route output6 meta nfproto ipv6 ip6 daddr @asena_hosts6 counter reject with icmpv6 type admin-prohibited
if [ -n "$SLICE_REL_PATH" ]; then
    nft "add rule inet asena_route output6 meta nfproto ipv6 socket cgroupv2 level $SLICE_LEVEL \"$SLICE_REL_PATH\" counter reject with icmpv6 type admin-prohibited"
fi

# PREROUTING: conf'taki iface'ler Asena'a gider.
IFACE_COUNT=0
if [ -f "$ROUTE_CONF" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        [ -z "${line// /}" ] && continue
        if [[ "$line" =~ ^[[:space:]]*iface[[:space:]]+([^[:space:]]+) ]]; then
            iface="${BASH_REMATCH[1]}"
            nft add rule inet asena_route prerouting iifname "$iface" counter meta mark set "$ASENA_MARK"
            IFACE_COUNT=$((IFACE_COUNT + 1))
        fi
    done < "$ROUTE_CONF"
fi

# dnsmasq: config uret ve baslat.
pkill -f "dnsmasq.*asena" 2>/dev/null || true
/usr/local/bin/asena-dnsmasq-gen
dnsmasq -C /etc/dnsmasq-asena.conf --pid-file=/run/dnsmasq-asena.pid

# Resolved'i dnsmasq'a yonlendir.
resolvectl dns "$DEV" 127.0.0.2
resolvectl domain "$DEV" "~."
resolvectl default-route "$DEV" true

echo "Asena on ($MODE) gw=$GW dev=$DEV user=$USER_NAME asena_iface=$IFACE_COUNT slice=${SLICE_REL_PATH:-?}"
EOF
chmod 755 /usr/local/bin/asena-on

#=== /usr/local/bin/asena-off ==================================================
say "Writing /usr/local/bin/asena-off…"
cat > /usr/local/bin/asena-off << 'EOF'
#!/usr/bin/env bash
# Asena nativetun stop + routing + dnsmasq teardown.
# Designed to run as root via sudoers NOPASSWD.

MASQUE_IP="162.159.198.2"
ASENA_TABLE=201
ASENA_MARK=0x43
RUN_DIR="/run/asena"

PHYS_DEV=$(ip -4 route show default proto dhcp 2>/dev/null | awk '{print $5; exit}')
[ -z "$PHYS_DEV" ] && PHYS_DEV=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')

# dnsmasq'i durdur.
PID_FILE="/run/dnsmasq-asena.pid"
if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
fi
pkill -f "dnsmasq.*dnsmasq-asena" 2>/dev/null || true

ip route del "${MASQUE_IP}/32" 2>/dev/null || true
ip rule del fwmark "$ASENA_MARK" 2>/dev/null || true
ip route flush table "$ASENA_TABLE" 2>/dev/null || true

nft delete table inet asena_route 2>/dev/null || true
nft delete table ip asena_nat 2>/dev/null || true

# rp_filter: asena-on'un sakladigi degerleri geri yukle.
if [ -f "$RUN_DIR/rpfilter.all" ]; then
    sysctl -wq "net.ipv4.conf.all.rp_filter=$(cat "$RUN_DIR/rpfilter.all")" 2>/dev/null || true
fi
SAVED_DEV=$(cat "$RUN_DIR/rpfilter.devname" 2>/dev/null)
if [ -n "$SAVED_DEV" ] && [ -f "$RUN_DIR/rpfilter.dev" ]; then
    sysctl -wq "net.ipv4.conf.${SAVED_DEV}.rp_filter=$(cat "$RUN_DIR/rpfilter.dev")" 2>/dev/null || true
fi
rm -f "$RUN_DIR"/rpfilter.* 2>/dev/null || true

[ -n "$PHYS_DEV" ] && resolvectl revert "$PHYS_DEV" 2>/dev/null || true

pkill -x usque 2>/dev/null || true
sleep 1
pkill -9 -x usque 2>/dev/null || true
ip link del tun0 2>/dev/null || true

echo "Asena off"
EOF
chmod 755 /usr/local/bin/asena-off

#=== /usr/local/bin/asena-bypass-reload ========================================
say "Writing /usr/local/bin/asena-bypass-reload…"
cat > /usr/local/bin/asena-bypass-reload << 'EOF'
#!/usr/bin/env bash
# Conf degisikligi sonrasi iface Asena kurallarini Asena'i kesmeden uygular.
# Designed to run as root via sudoers NOPASSWD.
set -e

ASENA_MARK=0x43

# Hedef kullaniciyi runtime'da belirle (hardcode yok).
USER_NAME="${SUDO_USER:-}"
{ [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ]; } && USER_NAME=$(id -nu 1000 2>/dev/null)
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
ROUTE_CONF="$USER_HOME/.config/asena-route.conf"

nft list table inet asena_route >/dev/null 2>&1 || { echo "asena-route-reload: Asena not active, skip"; exit 0; }

nft flush chain inet asena_route prerouting

IFACE_COUNT=0
if [ -f "$ROUTE_CONF" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        [ -z "${line// /}" ] && continue
        if [[ "$line" =~ ^[[:space:]]*iface[[:space:]]+([^[:space:]]+) ]]; then
            iface="${BASH_REMATCH[1]}"
            nft add rule inet asena_route prerouting iifname "$iface" counter meta mark set "$ASENA_MARK"
            IFACE_COUNT=$((IFACE_COUNT + 1))
        fi
    done < "$ROUTE_CONF"
fi

echo "asena-route reloaded: iface_count=$IFACE_COUNT"
EOF
chmod 755 /usr/local/bin/asena-bypass-reload

#=== /usr/local/bin/asena-dnsmasq-gen ==========================================
say "Writing /usr/local/bin/asena-dnsmasq-gen…"
cat > /usr/local/bin/asena-dnsmasq-gen << 'EOF'
#!/usr/bin/env bash
# asena-blacklist.txt'ten dnsmasq nftset config'i uret.
# Her domain icin DNS sorgusu aninda asena_hosts (v4) ve asena_hosts6 (v6)
# set'lerine IP eklenir. v6 set'i fail-closed reject icin kullanilir.
# Runs as root via sudoers NOPASSWD.

# Hedef kullaniciyi runtime'da belirle (hardcode yok).
USER_NAME="${SUDO_USER:-}"
{ [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ]; } && USER_NAME=$(id -nu 1000 2>/dev/null)
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)

BLACKLIST="$USER_HOME/.config/asena-blacklist.txt"
OUTPUT="/etc/dnsmasq-asena.conf"

cat > "$OUTPUT" << 'HEADER'
# dnsmasq-asena.conf — asena-on tarafindan olusturulur, elle duzenleme.
listen-address=127.0.0.2
bind-interfaces
port=53
no-resolv
# 77.88.8.8:1253 — Yandex'in ISP port-53 intercept'ini asmak icin acik alternatif DNS portu
server=77.88.8.8#1253
server=77.88.8.1#1253
server=2a02:6b8::feed:0ff#1253
cache-size=1000
log-queries=no
HEADER

if [ ! -f "$BLACKLIST" ]; then
    echo "asena-dnsmasq-gen: blacklist bulunamadi: $BLACKLIST, bos config yaziliyor" >&2
    exit 0
fi

# Wildcard'lari soy, deduplicate et, v4+v6 nftset satirlari olustur.
while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r' | sed 's/#.*//' | xargs)
    [ -z "$line" ] && continue
    domain="${line#\*.}"
    printf 'nftset=/%s/4#inet#asena_route#asena_hosts\n' "$domain"
    printf 'nftset=/%s/6#inet#asena_route#asena_hosts6\n' "$domain"
done < "$BLACKLIST" | sort -u >> "$OUTPUT"

echo "asena-dnsmasq-gen: $(grep -c '^nftset' "$OUTPUT") nftset satiri yazildi -> $OUTPUT"
EOF
chmod 755 /usr/local/bin/asena-dnsmasq-gen

#=== /usr/local/bin/asena-dns-reload ===========================================
say "Writing /usr/local/bin/asena-dns-reload…"
cat > /usr/local/bin/asena-dns-reload << 'EOF'
#!/usr/bin/env bash
# Blacklist'i yeniden uret ve dnsmasq'i yeniden baslat.
# Runs as root via sudoers NOPASSWD.
set -e

# Asena acik degilse nftset hedef tablosu (inet asena_route) yok — yenileme anlamsiz.
if ! nft list table inet asena_route >/dev/null 2>&1; then
    echo "asena-dns-reload: Asena kapali, atlandi" >&2
    exit 0
fi

pkill -f "dnsmasq.*asena" 2>/dev/null || true
sleep 0.3
/usr/local/bin/asena-dnsmasq-gen
dnsmasq -C /etc/dnsmasq-asena.conf --pid-file=/run/dnsmasq-asena.pid
# systemd-resolved cache'ini bosalt — yeni blacklist domainleri taze sorgulanip
# asena_hosts'a eklensin (yoksa cache'li eski IP fiziksel'den gider).
resolvectl flush-caches 2>/dev/null || true
echo "DNS reloaded"
EOF
chmod 755 /usr/local/bin/asena-dns-reload

#=== sudoers ===================================================================
say "Configuring sudoers (NOPASSWD: asena-on/off/bypass-reload/dnsmasq-gen/dns-reload)…"
TMP_SUDO=$(mktemp)
trap 'rm -f "$TMP_SUDO"' EXIT
printf '%s ALL=(root) NOPASSWD: /usr/local/bin/asena-on, /usr/local/bin/asena-on http2, /usr/local/bin/asena-on http3, /usr/local/bin/asena-off, /usr/local/bin/asena-bypass-reload, /usr/local/bin/asena-dnsmasq-gen, /usr/local/bin/asena-dns-reload\n' \
    "$TARGET_USER" > "$TMP_SUDO"
visudo -cf "$TMP_SUDO" >/dev/null || die "Generated sudoers fails visudo validation"
install -m 440 "$TMP_SUDO" /etc/sudoers.d/asena

#=== ~/.local/bin/asena-tray ===================================================
say "Installing tray app to $TARGET_HOME/.local/bin/asena-tray…"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.local/bin"
cat > "$TARGET_HOME/.local/bin/asena-tray" << 'PYEOF'
#!/usr/bin/env python3
"""
Asena system tray indicator (Hyprland + Quickshell-friendly).

- Left click: toggle. If off → connect via HTTP/2. If on → disconnect.
- Right click menu:
    Disconnect
    HTTP/2     (checked when active mode)
    HTTP/3     (checked when active mode)
    Force Asena ▸
        Through Asena:
            ✓ <entry>          [click to remove]
        Add interface…         [text input dialog]
        Add running app ▸      [Hyprland clients]
        Refresh
    Blacklist ▸
        N domain kayıtlı
        Düzenle…               [opens file in xdg-open]
        Domain ekle…           [text input dialog]
        DNS yenile             [runs asena-dns-reload]
    Quit

- Mode detection: parses `pgrep -af usque` for the --http2 flag.
- Route config: ~/.config/asena-route.conf  (lines: 'iface <name>', 'app <path>').
- Blacklist: ~/.config/asena-blacklist.txt  (one domain per line).
- Physical is default route; only listed apps/ifaces/domains go through Asena.
- App Asena: PID moved into asena-only.slice cgroup. Polling every 3s.
- Domain Asena: dnsmasq nftset populates asena_hosts on DNS queries.
"""
import fnmatch
import json
import os
import subprocess
import sys
from pathlib import Path
from PySide6.QtWidgets import (
    QApplication, QSystemTrayIcon, QMenu, QInputDialog,
)
from PySide6.QtGui import QIcon, QAction, QPainter, QColor, QPen, QBrush, QPixmap, QFont
from PySide6.QtCore import QTimer, Qt, QRect

ASENA_OFF = ["sudo", "-n", "/usr/local/bin/asena-off"]
BYPASS_RELOAD = ["sudo", "-n", "/usr/local/bin/asena-bypass-reload"]
DNS_RELOAD = ["sudo", "-n", "/usr/local/bin/asena-dns-reload"]
CONF_PATH = Path.home() / ".config" / "asena-route.conf"
BLACKLIST_PATH = Path.home() / ".config" / "asena-blacklist.txt"
SLICE_NAME = "asena-only.slice"
SLICE_PROCS = None  # resolved at startup


def asena_on_cmd(mode: str) -> list[str]:
    return ["sudo", "-n", "/usr/local/bin/asena-on", mode]


ICON_SIZE = 64
COLOR_CONNECTED = QColor(76, 175, 80)
COLOR_DISCONNECTED = QColor(158, 158, 158)


# ---------------------------------------------------------------- Asena state

def current_mode() -> str | None:
    """Returns 'http2', 'http3', or None (disconnected)."""
    if subprocess.run(
        ["ip", "link", "show", "tun0"],
        capture_output=True,
    ).returncode != 0:
        return None
    result = subprocess.run(
        ["pgrep", "-af", "^usque"],
        capture_output=True,
        text=True,
    )
    for line in result.stdout.splitlines():
        if "nativetun" in line:
            return "http2" if "--http2" in line else "http3"
    return None


# ---------------------------------------------------------------- Conf parser

def read_conf() -> dict[str, list[str]]:
    out: dict[str, list[str]] = {"iface": [], "app": []}
    if not CONF_PATH.exists():
        return out
    for raw in CONF_PATH.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        key, val = parts[0].lower(), parts[1].strip()
        if key in out:
            out[key].append(val)
    return out


def write_conf(data: dict[str, list[str]]) -> None:
    header = (
        "# Asena route list. Tray bu dosyayı okur ve yazar; elle de düzenleyebilirsin.\n"
        "# Physical default route; sadece buradakiler Asena'tan gecer.\n"
        "# Format:\n"
        "#   iface <name>            bu interface'ten gelen tüm trafik Asena'tan gecer\n"
        "#   app   <executable-path> bu exe ile calisan process'ler Asena'tan gecer\n"
        "# Yorum satırları # ile baslar, bos satırlar yok sayılır.\n"
        "\n"
    )
    body = []
    for k in ("iface", "app"):
        for v in data.get(k, []):
            body.append(f"{k} {v}")
    CONF_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONF_PATH.write_text(header + "\n".join(body) + ("\n" if body else ""))


# ---------------------------------------------------------------- Exe matching

def exe_matches(exe: str, pattern: str) -> bool:
    """Exact, glob, or versioned-subdir match (handles Discord app-X.Y.Z paths)."""
    if exe == pattern:
        return True
    if fnmatch.fnmatch(exe, pattern):
        return True
    p = Path(pattern)
    e = Path(exe)
    return e.name == p.name and e.parent.parent == p.parent


# ---------------------------------------------------------------- Cgroup

def resolve_slice_procs() -> Path | None:
    try:
        cp = subprocess.run(
            ["systemctl", "--user", "show", "-p", "ControlGroup", "--value", SLICE_NAME],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except Exception:
        return None
    if not cp:
        return None
    return Path("/sys/fs/cgroup") / cp.lstrip("/") / "cgroup.procs"


def slice_pids() -> set[int]:
    if SLICE_PROCS is None or not SLICE_PROCS.exists():
        return set()
    try:
        return {int(x) for x in SLICE_PROCS.read_text().split()}
    except Exception:
        return set()


def add_pid_to_slice(pid: int) -> bool:
    if SLICE_PROCS is None:
        return False
    try:
        SLICE_PROCS.write_text(f"{pid}\n")
        return True
    except Exception:
        return False


def remove_pid_from_slice(pid: int) -> bool:
    root_procs = Path("/sys/fs/cgroup/user.slice") / f"user-{os.getuid()}.slice" / "cgroup.procs"
    if not root_procs.exists():
        root_procs = Path("/sys/fs/cgroup/user.slice") / f"user-{os.getuid()}.slice" / f"user@{os.getuid()}.service" / "cgroup.procs"
    try:
        root_procs.write_text(f"{pid}\n")
        return True
    except Exception:
        return False


def pid_exe(pid: int) -> str | None:
    try:
        return os.readlink(f"/proc/{pid}/exe")
    except Exception:
        return None


# ---------------------------------------------------------------- Hyprland

def hyprland_clients() -> list[dict]:
    try:
        r = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, check=True)
        clients = json.loads(r.stdout)
    except Exception:
        return []
    seen = {}
    for c in clients:
        pid = c.get("pid")
        if not pid or pid <= 0:
            continue
        klass = c.get("class") or c.get("initialClass") or ""
        title = c.get("title") or ""
        if pid in seen:
            continue
        exe = pid_exe(pid)
        if not exe:
            continue
        seen[pid] = {"pid": pid, "klass": klass, "title": title, "exe": exe}
    return sorted(seen.values(), key=lambda x: x["klass"].lower())


# ---------------------------------------------------------------- Icon

def make_icon(connected: bool) -> QIcon:
    pixmap = QPixmap(ICON_SIZE, ICON_SIZE)
    pixmap.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    color = COLOR_CONNECTED if connected else COLOR_DISCONNECTED
    margin = 6
    rect = QRect(margin, margin, ICON_SIZE - 2 * margin, ICON_SIZE - 2 * margin)
    if connected:
        painter.setBrush(QBrush(color))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.drawEllipse(rect)
        painter.setPen(QPen(QColor(255, 255, 255)))
    else:
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.setPen(QPen(color, 4))
        painter.drawEllipse(rect)
        painter.setPen(QPen(color))
    font = QFont()
    font.setPointSize(28)
    font.setBold(True)
    painter.setFont(font)
    painter.drawText(QRect(0, 0, ICON_SIZE, ICON_SIZE), Qt.AlignmentFlag.AlignCenter, "W")
    painter.end()
    return QIcon(pixmap)


def notify(title: str, body: str, icon: str = "network-vpn") -> None:
    subprocess.Popen(
        ["notify-send", "-a", "Asena", "-i", icon, "-t", "2000", title, body],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


# ---------------------------------------------------------------- Tray

class AsenaTray:
    def __init__(self):
        global SLICE_PROCS
        SLICE_PROCS = resolve_slice_procs()

        self.app = QApplication(sys.argv)
        self.app.setQuitOnLastWindowClosed(False)

        self.icon_on = make_icon(True)
        self.icon_off = make_icon(False)

        self.tray = QSystemTrayIcon()
        self.tray.setIcon(self.icon_off)
        self.tray.activated.connect(self._on_click)

        self.menu = QMenu()
        self.disconnect_action = QAction("Disconnect")
        self.disconnect_action.triggered.connect(self.disconnect)

        self.http2_action = QAction("HTTP/2")
        self.http2_action.setCheckable(True)
        self.http2_action.triggered.connect(lambda: self.set_mode("http2"))

        self.http3_action = QAction("HTTP/3")
        self.http3_action.setCheckable(True)
        self.http3_action.triggered.connect(lambda: self.set_mode("http3"))

        self.bypass_menu = QMenu("Force Asena")
        self.blacklist_menu = QMenu("Blacklist")

        quit_action = QAction("Quit")
        quit_action.triggered.connect(self.app.quit)

        self.menu.addAction(self.disconnect_action)
        self.menu.addSeparator()
        self.menu.addAction(self.http2_action)
        self.menu.addAction(self.http3_action)
        self.menu.addSeparator()
        self.menu.addMenu(self.bypass_menu)
        self.menu.addMenu(self.blacklist_menu)
        self.menu.addSeparator()
        self.menu.addAction(quit_action)
        self.tray.setContextMenu(self.menu)
        self.menu.aboutToShow.connect(self._rebuild_menus)

        self._last_mode: str | None = None
        self._initialized = False
        self._rebuild_menus()
        self.refresh()
        self.tray.setVisible(True)

        self.timer = QTimer()
        self.timer.timeout.connect(self.refresh)
        self.timer.start(3000)

    # -------- Asena toggle

    def _on_click(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            if current_mode() is None:
                self.set_mode("http2")
            else:
                self.disconnect()

    def disconnect(self):
        subprocess.Popen(ASENA_OFF, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        QTimer.singleShot(1500, self.refresh)

    def set_mode(self, target: str):
        cur = current_mode()
        if cur == target:
            return
        if cur is not None:
            subprocess.run(ASENA_OFF, capture_output=True)
            QTimer.singleShot(1500, lambda: self._launch(target))
        else:
            self._launch(target)

    def _launch(self, mode: str):
        subprocess.Popen(
            asena_on_cmd(mode),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        QTimer.singleShot(3500, self.refresh)

    # -------- Bypass conf mutators

    def add_iface(self, name: str):
        name = name.strip()
        if not name:
            return
        conf = read_conf()
        if name in conf["iface"]:
            notify("Force Asena", f"{name} already in list")
            return
        conf["iface"].append(name)
        write_conf(conf)
        subprocess.Popen(BYPASS_RELOAD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        notify(f"Asena'a eklendi: {name}", "Interface trafiği artik Asena'tan geciyor.")
        QTimer.singleShot(500, self.rebuild_bypass_menu)

    def remove_iface(self, name: str):
        conf = read_conf()
        if name not in conf["iface"]:
            return
        conf["iface"].remove(name)
        write_conf(conf)
        subprocess.Popen(BYPASS_RELOAD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        notify(f"Asena'tan cikarildi: {name}", "Interface artik normal internete gidiyor.")
        QTimer.singleShot(500, self.rebuild_bypass_menu)

    def add_app(self, exe_path: str, pid: int | None = None):
        exe_path = exe_path.strip()
        if not exe_path:
            return
        conf = read_conf()
        if exe_path not in conf["app"]:
            conf["app"].append(exe_path)
            write_conf(conf)
        if pid is not None:
            add_pid_to_slice(pid)
            for p in self._pids_with_exe(exe_path):
                if p != pid:
                    add_pid_to_slice(p)
        name = Path(exe_path).name
        notify(
            f"Asena'a eklendi: {name}",
            "Tam etkili olması icin uygulamayı yeniden baslat.",
        )
        QTimer.singleShot(500, self.rebuild_bypass_menu)

    def remove_app(self, exe_path: str):
        conf = read_conf()
        if exe_path not in conf["app"]:
            return
        conf["app"].remove(exe_path)
        write_conf(conf)
        for pid in list(slice_pids()):
            if pid_exe(pid) == exe_path:
                remove_pid_from_slice(pid)
        name = Path(exe_path).name
        notify(
            f"Asena'tan cikarildi: {name}",
            "Tam etkili olması icin uygulamayı yeniden baslat.",
        )
        QTimer.singleShot(500, self.rebuild_bypass_menu)

    @staticmethod
    def _pids_with_exe(exe_path: str) -> list[int]:
        pids = []
        for p in Path("/proc").iterdir():
            if not p.name.isdigit():
                continue
            pid = int(p.name)
            if exe_matches(pid_exe(pid) or "", exe_path):
                pids.append(pid)
        return pids

    # -------- Force Asena menu

    def rebuild_bypass_menu(self):
        self.bypass_menu.clear()
        conf = read_conf()

        if conf["iface"] or conf["app"]:
            hdr = self.bypass_menu.addAction("Through Asena:")
            hdr.setEnabled(False)
            for name in conf["iface"]:
                a = self.bypass_menu.addAction(f"  ✓ {name}  (iface)")
                a.triggered.connect(lambda _=False, n=name: self.remove_iface(n))
            for exe in conf["app"]:
                short = Path(exe).name
                a = self.bypass_menu.addAction(f"  ✓ {short}  (app: {exe})")
                a.triggered.connect(lambda _=False, e=exe: self.remove_app(e))
            self.bypass_menu.addSeparator()

        add_if = self.bypass_menu.addAction("Add interface…")
        add_if.triggered.connect(self.prompt_add_iface)

        add_app_menu = self.bypass_menu.addMenu("Add running app")
        clients = hyprland_clients()
        bypassed_exes = set(conf["app"])
        any_added = False
        for c in clients:
            if c["exe"] in bypassed_exes:
                continue
            label = c["klass"] or Path(c["exe"]).name
            label = f"{label}  ({c['exe']})"
            a = add_app_menu.addAction(label)
            a.triggered.connect(lambda _=False, e=c["exe"], p=c["pid"]: self.add_app(e, p))
            any_added = True
        if not any_added:
            empty = add_app_menu.addAction("(no running graphical apps)")
            empty.setEnabled(False)

        refresh = self.bypass_menu.addAction("Refresh")
        refresh.triggered.connect(self.rebuild_bypass_menu)

    def prompt_add_iface(self):
        name, ok = QInputDialog.getText(None, "Add interface to Force Asena", "Interface name (e.g. waydroid0):")
        if ok and name.strip():
            self.add_iface(name.strip())

    # -------- Blacklist menu

    def _rebuild_menus(self):
        self.rebuild_bypass_menu()
        self.rebuild_blacklist_menu()

    def rebuild_blacklist_menu(self):
        self.blacklist_menu.clear()
        count = 0
        if BLACKLIST_PATH.exists():
            lines = [
                l.strip() for l in BLACKLIST_PATH.read_text().splitlines()
                if l.strip() and not l.strip().startswith("#")
            ]
            count = len(lines)
        info = self.blacklist_menu.addAction(f"{count} domain kayıtlı")
        info.setEnabled(False)
        self.blacklist_menu.addSeparator()

        edit_action = self.blacklist_menu.addAction("Düzenle…")
        edit_action.triggered.connect(self.open_blacklist_editor)

        add_action = self.blacklist_menu.addAction("Domain ekle…")
        add_action.triggered.connect(self.prompt_add_domain)

        reload_action = self.blacklist_menu.addAction("DNS yenile")
        reload_action.triggered.connect(self.reload_dns)

    def open_blacklist_editor(self):
        BLACKLIST_PATH.touch(exist_ok=True)
        subprocess.Popen(
            ["xdg-open", str(BLACKLIST_PATH)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    def prompt_add_domain(self):
        domain, ok = QInputDialog.getText(None, "Blacklist'e domain ekle", "Domain (örn: example.com):")
        if not ok or not domain.strip():
            return
        domain = domain.strip().lstrip("*").lstrip(".")
        if not domain:
            return
        BLACKLIST_PATH.touch(exist_ok=True)
        existing = BLACKLIST_PATH.read_text()
        if domain in existing.splitlines():
            notify("Blacklist", f"{domain} zaten mevcut.")
            return
        with BLACKLIST_PATH.open("a") as f:
            if existing and not existing.endswith("\n"):
                f.write("\n")
            f.write(domain + "\n")
        notify("Blacklist", f"{domain} eklendi. DNS yenile ile aktif et.")
        self.rebuild_blacklist_menu()

    def reload_dns(self):
        if current_mode() is None:
            notify("Asena Blacklist", "Önce Asena'ı aç — kapalıyken DNS yenilenmez.")
            return
        subprocess.Popen(DNS_RELOAD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        notify("Asena Blacklist", "DNS yenileniyor…")

    # -------- Polling

    def refresh(self):
        mode = current_mode()
        active = mode is not None

        if active:
            self.tray.setIcon(self.icon_on)
            self.tray.setToolTip(f"Asena: Connected ({mode.upper().replace('HTTP', 'HTTP/')})")
        else:
            self.tray.setIcon(self.icon_off)
            self.tray.setToolTip("Asena: Disconnected")

        self.disconnect_action.setEnabled(active)
        self.http2_action.setChecked(mode == "http2")
        self.http3_action.setChecked(mode == "http3")

        if SLICE_PROCS is not None and SLICE_PROCS.exists():
            conf = read_conf()
            in_slice = slice_pids()
            wanted_exes = set(conf["app"])
            if wanted_exes:
                for p in Path("/proc").iterdir():
                    if not p.name.isdigit():
                        continue
                    pid = int(p.name)
                    if pid in in_slice:
                        continue
                    exe = pid_exe(pid)
                    if exe and any(exe_matches(exe, pat) for pat in wanted_exes):
                        add_pid_to_slice(pid)

        if self._initialized and mode != self._last_mode:
            if mode is None:
                body = "Disconnected"
                icon = "network-offline"
            else:
                body = f"Connected ({mode.upper().replace('HTTP', 'HTTP/')})"
                icon = "network-vpn"
            notify("Asena", body, icon)
        self._last_mode = mode
        self._initialized = True

    def run(self):
        sys.exit(self.app.exec())


if __name__ == "__main__":
    AsenaTray().run()
PYEOF
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.local/bin/asena-tray"
chmod 755 "$TARGET_HOME/.local/bin/asena-tray"

#=== ~/.local/bin/discord wrapper =============================================
say "Installing Discord launcher wrapper to $TARGET_HOME/.local/bin/discord…"
cat > "$TARGET_HOME/.local/bin/discord" << 'EOF'
#!/usr/bin/env bash
# Discord'u asena-only.slice icinde baslatir — Asena'tan geciyor.
DISCORD_BIN=$(find "$HOME/.config/discord" -maxdepth 2 -name "Discord" -type f 2>/dev/null | sort -V | tail -1)
[ -z "$DISCORD_BIN" ] && { echo "Discord binary bulunamadi." >&2; exit 1; }
exec systemd-run --user --slice=asena-only.slice --scope \
    --setenv=DISCORD_SKIP_HOST_UPDATE=true "$DISCORD_BIN" "$@"
EOF
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.local/bin/discord"
chmod 755 "$TARGET_HOME/.local/bin/discord"

#=== ~/.config/asena-route.conf (template) =====================================
ROUTE_CONF="$TARGET_HOME/.config/asena-route.conf"
if [ ! -f "$ROUTE_CONF" ]; then
    say "Creating asena-route.conf template…"
    cat > "$ROUTE_CONF" << 'EOF'
# Asena route list. Tray bu dosyayı okur ve yazar; elle de düzenleyebilirsin.
# Physical default route; sadece buradakiler Asena'tan gecer.
# Format:
#   iface <name>            bu interface'ten gelen tüm trafik Asena'tan gecer
#   app   <executable-path> bu exe ile calisan process'ler Asena'tan gecer
# Yorum satırları # ile baslar, bos satırlar yok sayılır.

# Ornek: Discord'u Asena'tan gecirmek icin:
# app /home/USER/.config/discord/Discord
EOF
    chown "$TARGET_USER:$TARGET_USER" "$ROUTE_CONF"
fi

#=== Hyprland autostart ========================================================
HYPR_LUA="$TARGET_HOME/.config/hypr/custom/execs.lua"
HYPR_CONF="$TARGET_HOME/.config/hypr/hyprland.conf"
AUTOSTART_LINE='hl.exec_cmd("sleep 4 && $HOME/.local/bin/asena-tray")'
CONF_LINE='exec-once = sleep 4 && $HOME/.local/bin/asena-tray'

if [ -f "$HYPR_LUA" ]; then
    say "Adding autostart to $HYPR_LUA…"
    if ! grep -q 'asena-tray' "$HYPR_LUA"; then
        if grep -q 'hl.on("hyprland.start"' "$HYPR_LUA"; then
            warn "Existing hl.on block — add manually inside it: $AUTOSTART_LINE"
        else
            cat >> "$HYPR_LUA" << EOF

hl.on("hyprland.start", function ()
    -- Asena tray indicator (delay so Quickshell SNI host is up)
    $AUTOSTART_LINE
end)
EOF
        fi
    else
        say "asena-tray already in execs.lua, skipping."
    fi
    chown "$TARGET_USER:$TARGET_USER" "$HYPR_LUA"
elif [ -f "$HYPR_CONF" ]; then
    say "Adding autostart to $HYPR_CONF…"
    if ! grep -q 'asena-tray' "$HYPR_CONF"; then
        printf '\n# Asena tray indicator\n%s\n' "$CONF_LINE" >> "$HYPR_CONF"
        chown "$TARGET_USER:$TARGET_USER" "$HYPR_CONF"
    else
        say "asena-tray already in hyprland.conf, skipping."
    fi
else
    warn "No Hyprland config found — add manually: $CONF_LINE"
fi

#=== usque register ============================================================
USQUE_CONFIG="$TARGET_HOME/config.json"
if [ ! -f "$USQUE_CONFIG" ]; then
    say "Registering usque device (creates $USQUE_CONFIG)…"
    sudo -u "$TARGET_USER" bash -c "cd '$TARGET_HOME' && usque register" || \
        warn "usque register failed — run it manually from $TARGET_HOME"
fi

#=== Done ======================================================================
cat << EOF

────────────────────────────────────────────────────────────────────
  Installed! (selective routing — physical default, Asena on demand)
────────────────────────────────────────────────────────────────────
  Scripts   : asena-on [http2|http3]  asena-off  asena-bypass-reload
              asena-dnsmasq-gen  asena-dns-reload
  Sudoers   : /etc/sudoers.d/asena  (NOPASSWD, scoped)
  Tray app  : $TARGET_HOME/.local/bin/asena-tray
  Discord   : $TARGET_HOME/.local/bin/discord  (runs in asena-only.slice)
  Route conf: $TARGET_HOME/.config/asena-route.conf
  Blacklist : $TARGET_HOME/.config/asena-blacklist.txt  (domain per line)
  Usque cfg : $USQUE_CONFIG  (BACK THIS UP — your Asena identity!)

  Start now:
    nohup ~/.local/bin/asena-tray >/dev/null 2>&1 & disown

  Daily use:
    Left click   = toggle Asena
    Force Asena   = specific apps/interfaces through Asena
    Blacklist     = manage domain list + reload DNS

  After reboot, Hyprland starts the tray automatically.
────────────────────────────────────────────────────────────────────
EOF
