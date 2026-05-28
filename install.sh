#!/usr/bin/env bash
# Cloudflare WARP via MASQUE (usque) with a Hyprland system tray indicator.
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
if [ -z "$TARGET_HOME" ]; then
    echo "ERROR: cannot resolve home for $TARGET_USER" >&2
    exit 1
fi

say() { printf "\033[1;36m::\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*" >&2; }
die() { printf "\033[1;31mXX\033[0m %s\n" "$*" >&2; exit 1; }

#=== Sanity ====================================================================
say "Target user: $TARGET_USER (home: $TARGET_HOME)"

[ -f /etc/arch-release ] || warn "Not Arch — pacman/yay paths may fail."

# Re-run with sudo if not root (system paths need it)
if [ "$(id -u)" -ne 0 ]; then
    say "Re-launching under sudo for system installs…"
    exec sudo -E "$0" "$@"
fi

# yay is preferred for AUR (usque-bin). Fall back to skipping AUR install.
HAVE_YAY=0
if sudo -u "$TARGET_USER" command -v yay >/dev/null 2>&1; then
    HAVE_YAY=1
fi

#=== Dependencies ==============================================================
say "Installing system packages (pyside6, libnotify, sudo, iproute2, systemd)…"
pacman -S --needed --noconfirm \
    python-pyside6 libnotify sudo iproute2 systemd >/dev/null

if ! command -v usque >/dev/null 2>&1; then
    if [ "$HAVE_YAY" -eq 1 ]; then
        say "Installing usque from AUR via yay…"
        sudo -u "$TARGET_USER" yay -S --needed --noconfirm usque-bin || \
        sudo -u "$TARGET_USER" yay -S --needed --noconfirm usque || \
            die "Could not install usque. Install it manually (https://github.com/Diniboy1123/usque)"
    else
        die "yay not found and usque missing. Install yay (or usque manually) then re-run."
    fi
fi

#=== /usr/local/bin/warp-on ===================================================
say "Writing /usr/local/bin/warp-on…"
cat > /usr/local/bin/warp-on <<EOF
#!/usr/bin/env bash
# WARP nativetun start + routing setup.
# Runs as root via sudoers NOPASSWD.
set -e

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

echo "WARP on (gw=\$GW dev=\$DEV)"
EOF
chmod 755 /usr/local/bin/warp-on

#=== /usr/local/bin/warp-off ==================================================
say "Writing /usr/local/bin/warp-off…"
cat > /usr/local/bin/warp-off <<'EOF'
#!/usr/bin/env bash
# WARP nativetun stop + routing teardown. Runs as root via sudoers NOPASSWD.

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
say "Configuring sudoers (NOPASSWD for warp-on/warp-off only)…"
TMP_SUDO=$(mktemp)
trap 'rm -f "$TMP_SUDO"' EXIT
printf '%s ALL=(root) NOPASSWD: /usr/local/bin/warp-on, /usr/local/bin/warp-off\n' \
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

- Left click: toggle connect/disconnect.
- Right click: menu.
- Auto-refreshes every 3s by checking tun0 interface existence.
- State-change notifications via notify-send (does not touch the tray icon).
- Icon is rendered programmatically (no theme dependency).
"""
import subprocess
import sys
from PySide6.QtWidgets import QApplication, QSystemTrayIcon, QMenu
from PySide6.QtGui import QIcon, QAction, QPainter, QColor, QPen, QBrush, QPixmap, QFont
from PySide6.QtCore import QTimer, Qt, QRect

WARP_ON = ["sudo", "-n", "/usr/local/bin/warp-on"]
WARP_OFF = ["sudo", "-n", "/usr/local/bin/warp-off"]

ICON_SIZE = 64
COLOR_CONNECTED = QColor(76, 175, 80)
COLOR_DISCONNECTED = QColor(158, 158, 158)


def is_active() -> bool:
    return subprocess.run(
        ["ip", "link", "show", "tun0"],
        capture_output=True,
    ).returncode == 0


def make_icon(connected: bool) -> QIcon:
    pixmap = QPixmap(ICON_SIZE, ICON_SIZE)
    pixmap.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    color = COLOR_CONNECTED if connected else COLOR_DISCONNECTED
    margin = 6
    circle_rect = QRect(margin, margin, ICON_SIZE - 2 * margin, ICON_SIZE - 2 * margin)
    if connected:
        painter.setBrush(QBrush(color))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.drawEllipse(circle_rect)
        painter.setPen(QPen(QColor(255, 255, 255)))
    else:
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.setPen(QPen(color, 4))
        painter.drawEllipse(circle_rect)
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
        self.connect_action = QAction("Connect")
        self.connect_action.triggered.connect(self.connect)
        self.disconnect_action = QAction("Disconnect")
        self.disconnect_action.triggered.connect(self.disconnect)
        quit_action = QAction("Quit")
        quit_action.triggered.connect(self.app.quit)
        self.menu.addAction(self.connect_action)
        self.menu.addAction(self.disconnect_action)
        self.menu.addSeparator()
        self.menu.addAction(quit_action)
        self.tray.setContextMenu(self.menu)

        self._last_state = None
        self.refresh()
        self.tray.setVisible(True)

        self.timer = QTimer()
        self.timer.timeout.connect(self.refresh)
        self.timer.start(3000)

    def _on_click(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.disconnect() if is_active() else self.connect()

    def connect(self):
        subprocess.Popen(WARP_ON, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        QTimer.singleShot(3000, self.refresh)

    def disconnect(self):
        subprocess.Popen(WARP_OFF, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        QTimer.singleShot(1500, self.refresh)

    def refresh(self):
        active = is_active()
        if active:
            self.tray.setIcon(self.icon_on)
            self.tray.setToolTip("WARP: Connected")
            self.connect_action.setEnabled(False)
            self.disconnect_action.setEnabled(True)
        else:
            self.tray.setIcon(self.icon_off)
            self.tray.setToolTip("WARP: Disconnected")
            self.connect_action.setEnabled(True)
            self.disconnect_action.setEnabled(False)

        if self._last_state is not None and active != self._last_state:
            subprocess.Popen(
                [
                    "notify-send",
                    "-a", "WARP",
                    "-i", "network-vpn" if active else "network-offline",
                    "-t", "2000",
                    "WARP",
                    "Connected" if active else "Disconnected",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        self._last_state = active

    def run(self):
        sys.exit(self.app.exec())


if __name__ == "__main__":
    WarpTray().run()
PYEOF
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.local/bin/warp-tray"
chmod 755 "$TARGET_HOME/.local/bin/warp-tray"

#=== Hyprland autostart (illogical-impulse Lua-based or vanilla .conf) =========
HYPR_LUA="$TARGET_HOME/.config/hypr/custom/execs.lua"
HYPR_CONF="$TARGET_HOME/.config/hypr/hyprland.conf"
AUTOSTART_LINE='hl.exec_cmd("sleep 4 && $HOME/.local/bin/warp-tray")'
CONF_LINE='exec-once = sleep 4 && $HOME/.local/bin/warp-tray'

if [ -f "$HYPR_LUA" ]; then
    say "Found illogical-impulse Lua config — adding to execs.lua…"
    if ! grep -q 'warp-tray' "$HYPR_LUA"; then
        # Append a hl.on block (or extend existing one)
        if grep -q 'hl.on("hyprland.start"' "$HYPR_LUA"; then
            warn "execs.lua already has hl.on block — adding warp-tray exec_cmd inside is non-trivial. Edit manually:"
            warn "  $AUTOSTART_LINE"
        else
            cat >> "$HYPR_LUA" <<EOF

hl.on("hyprland.start", function ()
    -- WARP tray indicator (delay so Quickshell SNI host is up)
    $AUTOSTART_LINE
end)
EOF
        fi
    else
        say "warp-tray already present in execs.lua, skipping."
    fi
    chown "$TARGET_USER:$TARGET_USER" "$HYPR_LUA"
elif [ -f "$HYPR_CONF" ]; then
    say "Found vanilla hyprland.conf — adding exec-once line…"
    if ! grep -q 'warp-tray' "$HYPR_CONF"; then
        printf '\n# WARP tray indicator\n%s\n' "$CONF_LINE" >> "$HYPR_CONF"
        chown "$TARGET_USER:$TARGET_USER" "$HYPR_CONF"
    else
        say "warp-tray already present in hyprland.conf, skipping."
    fi
else
    warn "No Hyprland config found — add this to your autostart manually:"
    warn "  $CONF_LINE"
fi

#=== usque register (interactive, only if config.json missing) ================
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
  Scripts     : /usr/local/bin/warp-on /usr/local/bin/warp-off
  Sudoers     : /etc/sudoers.d/warp  (NOPASSWD, scoped)
  Tray app    : $TARGET_HOME/.local/bin/warp-tray
  Usque config: $USQUE_CONFIG  (BACK THIS UP — your WARP identity!)

  Start now without rebooting:
    nohup ~/.local/bin/warp-tray >/dev/null 2>&1 & disown

  Then left-click the tray icon to toggle WARP.
  After a reboot, Hyprland starts the tray automatically.

  Cheatsheet:
    sudo -n warp-on    # connect from terminal
    sudo -n warp-off   # disconnect from terminal
    tail -f /var/log/usque.log   # debug tunnel
────────────────────────────────────────────────────────────
EOF
