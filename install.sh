#!/usr/bin/env bash
# Cloudflare WARP via MASQUE (usque) with a Hyprland system tray indicator.
# Modes: HTTP/2 (TCP+TLS, default — DPI-stealthy in TR) and HTTP/3 (QUIC, faster).
# Self-contained installer — embeds all files, idempotent, safe to re-run.
#
# Tested on: CachyOS / Arch Linux + Hyprland (illogical-impulse dots).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh | bash
# or, after cloning:
#   ./install.sh
set -euo pipefail

#=== Identity ==================================================================
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[ -z "$TARGET_HOME" ] && { echo "ERROR: cannot resolve home for $TARGET_USER" >&2; exit 1; }

say() { printf "\033[1;36m::\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*" >&2; }
die() { printf "\033[1;31mXX\033[0m %s\n" "$*" >&2; exit 1; }

#=== Sanity ====================================================================
say "Target user: $TARGET_USER (home: $TARGET_HOME)"
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
    python-pyside6 libnotify sudo iproute2 systemd >/dev/null

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

#=== /usr/local/bin/warp-on (mode-aware) ======================================
say "Writing /usr/local/bin/warp-on (HTTP/2 default, HTTP/3 optional)…"
cat > /usr/local/bin/warp-on <<EOF
#!/usr/bin/env bash
# Usage: warp-on [http2|http3]   (default: http2)
# Runs as root via sudoers NOPASSWD.
set -e

MODE="\${1:-http2}"
case "\$MODE" in
    http2) PROTO_FLAGS="--http2" ;;
    http3) PROTO_FLAGS="" ;;
    *) echo "Usage: warp-on [http2|http3]" >&2; exit 2 ;;
esac

USQUE_DIR="$TARGET_HOME"
USQUE_CONFIG="\${USQUE_DIR}/config.json"
MASQUE_IP="162.159.198.2"

GW=\$(ip -4 route show default proto dhcp 2>/dev/null | awk '{print \$3; exit}')
DEV=\$(ip -4 route show default proto dhcp 2>/dev/null | awk '{print \$5; exit}')
if [ -z "\$GW" ]; then
    GW=\$(ip -4 route show default 2>/dev/null | awk '{print \$3; exit}')
    DEV=\$(ip -4 route show default 2>/dev/null | awk '{print \$5; exit}')
fi
[ -z "\$GW" ] || [ -z "\$DEV" ] && { echo "ERROR: no default gateway" >&2; exit 1; }

if ! pgrep -x usque >/dev/null; then
    cd "\$USQUE_DIR"
    nohup usque -c "\$USQUE_CONFIG" nativetun \\
        --always-reconnect \\
        --keepalive-period 15s \\
        \$PROTO_FLAGS \\
        >/var/log/usque.log 2>&1 &
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        ip link show tun0 >/dev/null 2>&1 && break
        sleep 0.5
    done
fi

ip route replace "\${MASQUE_IP}/32" via "\$GW" dev "\$DEV"
ip route replace default dev tun0 metric 50
resolvectl dns tun0 1.1.1.1 1.0.0.1
resolvectl domain tun0 "~."
resolvectl default-route tun0 true

echo "WARP on (\$MODE) gw=\$GW dev=\$DEV"
EOF
chmod 755 /usr/local/bin/warp-on

#=== /usr/local/bin/warp-off ==================================================
say "Writing /usr/local/bin/warp-off…"
cat > /usr/local/bin/warp-off <<'EOF'
#!/usr/bin/env bash
# Runs as root via sudoers NOPASSWD.
MASQUE_IP="162.159.198.2"
PHYS_DEV=$(ip -4 route show default proto dhcp 2>/dev/null | awk '{print $5; exit}')

ip route del default dev tun0 2>/dev/null || true
ip route del "${MASQUE_IP}/32" 2>/dev/null || true
[ -n "$PHYS_DEV" ] && resolvectl revert "$PHYS_DEV" 2>/dev/null || true

pkill -x usque 2>/dev/null || true
sleep 1
pkill -9 -x usque 2>/dev/null || true
ip link del tun0 2>/dev/null || true

echo "WARP off"
EOF
chmod 755 /usr/local/bin/warp-off

#=== sudoers ===================================================================
say "Configuring sudoers (NOPASSWD: warp-off, warp-on, warp-on http2|http3)…"
TMP_SUDO=$(mktemp)
trap 'rm -f "$TMP_SUDO"' EXIT
printf '%s ALL=(root) NOPASSWD: /usr/local/bin/warp-on, /usr/local/bin/warp-on http2, /usr/local/bin/warp-on http3, /usr/local/bin/warp-off\n' \
    "$TARGET_USER" > "$TMP_SUDO"
visudo -cf "$TMP_SUDO" >/dev/null || die "Generated sudoers fails visudo validation"
install -m 440 "$TMP_SUDO" /etc/sudoers.d/warp

#=== ~/.local/bin/warp-tray ===================================================
say "Installing tray app to $TARGET_HOME/.local/bin/warp-tray…"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.local/bin"
cat > "$TARGET_HOME/.local/bin/warp-tray" <<'PYEOF'
#!/usr/bin/env python3
"""
WARP system tray indicator (Hyprland + Quickshell-friendly).

- Left click: toggle. Off → connect via HTTP/2. On → disconnect.
- Right click menu: Disconnect / HTTP/2 (checkable) / HTTP/3 (checkable) / Quit.
  Switching mode while connected = warp-off → wait → warp-on <mode>.
- Mode detection: parses `pgrep -af usque` for the --http2 flag.
- Notifications via notify-send (does not touch the tray icon).
- Programmatic icon (no theme dependency).
"""
import subprocess
import sys
from PySide6.QtWidgets import QApplication, QSystemTrayIcon, QMenu
from PySide6.QtGui import QIcon, QAction, QPainter, QColor, QPen, QBrush, QPixmap, QFont
from PySide6.QtCore import QTimer, Qt, QRect

WARP_OFF = ["sudo", "-n", "/usr/local/bin/warp-off"]


def warp_on_cmd(mode: str) -> list[str]:
    return ["sudo", "-n", "/usr/local/bin/warp-on", mode]


ICON_SIZE = 64
COLOR_CONNECTED = QColor(76, 175, 80)
COLOR_DISCONNECTED = QColor(158, 158, 158)


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


class WarpTray:
    def __init__(self):
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
        quit_action = QAction("Quit")
        quit_action.triggered.connect(self.app.quit)

        self.menu.addAction(self.disconnect_action)
        self.menu.addSeparator()
        self.menu.addAction(self.http2_action)
        self.menu.addAction(self.http3_action)
        self.menu.addSeparator()
        self.menu.addAction(quit_action)
        self.tray.setContextMenu(self.menu)

        self._last_mode: str | None = None
        self.refresh()
        self.tray.setVisible(True)

        self.timer = QTimer()
        self.timer.timeout.connect(self.refresh)
        self.timer.start(3000)

    def _on_click(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            if current_mode() is None:
                self.set_mode("http2")
            else:
                self.disconnect()

    def disconnect(self):
        subprocess.Popen(WARP_OFF, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        QTimer.singleShot(1500, self.refresh)

    def set_mode(self, target: str):
        cur = current_mode()
        if cur == target:
            return
        if cur is not None:
            subprocess.run(WARP_OFF, capture_output=True)
            QTimer.singleShot(1500, lambda: self._launch(target))
        else:
            self._launch(target)

    def _launch(self, mode: str):
        subprocess.Popen(
            warp_on_cmd(mode),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        QTimer.singleShot(3500, self.refresh)

    def refresh(self):
        mode = current_mode()
        active = mode is not None

        if active:
            self.tray.setIcon(self.icon_on)
            self.tray.setToolTip(f"WARP: Connected ({mode.upper().replace('HTTP', 'HTTP/')})")
        else:
            self.tray.setIcon(self.icon_off)
            self.tray.setToolTip("WARP: Disconnected")

        self.disconnect_action.setEnabled(active)
        self.http2_action.setChecked(mode == "http2")
        self.http3_action.setChecked(mode == "http3")

        if self._last_mode is not None and mode != self._last_mode:
            if mode is None:
                body = "Disconnected"
                icon = "network-offline"
            else:
                body = f"Connected ({mode.upper().replace('HTTP', 'HTTP/')})"
                icon = "network-vpn"
            subprocess.Popen(
                [
                    "notify-send",
                    "-a", "WARP",
                    "-i", icon,
                    "-t", "2000",
                    "WARP",
                    body,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        self._last_mode = mode

    def run(self):
        sys.exit(self.app.exec())


if __name__ == "__main__":
    WarpTray().run()
PYEOF
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.local/bin/warp-tray"
chmod 755 "$TARGET_HOME/.local/bin/warp-tray"

#=== Hyprland autostart ========================================================
HYPR_LUA="$TARGET_HOME/.config/hypr/custom/execs.lua"
HYPR_CONF="$TARGET_HOME/.config/hypr/hyprland.conf"
AUTOSTART_LINE='hl.exec_cmd("sleep 4 && $HOME/.local/bin/warp-tray")'
CONF_LINE='exec-once = sleep 4 && $HOME/.local/bin/warp-tray'

if [ -f "$HYPR_LUA" ]; then
    say "Adding autostart to $HYPR_LUA…"
    if ! grep -q 'warp-tray' "$HYPR_LUA"; then
        if grep -q 'hl.on("hyprland.start"' "$HYPR_LUA"; then
            warn "Existing hl.on block — add manually inside it: $AUTOSTART_LINE"
        else
            cat >> "$HYPR_LUA" <<EOF

hl.on("hyprland.start", function ()
    -- WARP tray indicator (delay so Quickshell SNI host is up)
    $AUTOSTART_LINE
end)
EOF
        fi
    else
        say "warp-tray already in execs.lua, skipping."
    fi
    chown "$TARGET_USER:$TARGET_USER" "$HYPR_LUA"
elif [ -f "$HYPR_CONF" ]; then
    say "Adding autostart to $HYPR_CONF…"
    if ! grep -q 'warp-tray' "$HYPR_CONF"; then
        printf '\n# WARP tray indicator\n%s\n' "$CONF_LINE" >> "$HYPR_CONF"
        chown "$TARGET_USER:$TARGET_USER" "$HYPR_CONF"
    else
        say "warp-tray already in hyprland.conf, skipping."
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
cat <<EOF

────────────────────────────────────────────────────────────
  Installed!
────────────────────────────────────────────────────────────
  Scripts     : /usr/local/bin/warp-on [http2|http3] /usr/local/bin/warp-off
  Sudoers     : /etc/sudoers.d/warp  (NOPASSWD, scoped)
  Tray app    : $TARGET_HOME/.local/bin/warp-tray
  Usque config: $USQUE_CONFIG  (BACK THIS UP — your WARP identity!)

  Start now without rebooting:
    nohup ~/.local/bin/warp-tray >/dev/null 2>&1 & disown

  Daily use:
    Left click   = toggle (off → HTTP/2 connect; on → disconnect)
    Right click  = menu: Disconnect / HTTP/2 / HTTP/3 / Quit
    Mode switch  = pick HTTP/2 or HTTP/3 from menu while connected;
                   it disconnects, waits, reconnects in the new mode

  After a reboot, Hyprland starts the tray automatically.
────────────────────────────────────────────────────────────
EOF
