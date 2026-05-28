# warp-tray

Cloudflare WARP (MASQUE/HTTP-3) via [usque](https://github.com/Diniboy1123/usque)
with a system-tray indicator for Hyprland + Quickshell.

What you get:

- `warp-on` / `warp-off` shell commands (sudo NOPASSWD, scoped)
- A clickable tray icon (PySide6, no theme dependency)
  - green "W" when connected, gray outline when disconnected
  - left click toggles, right click opens menu
  - state-change notifications via `notify-send`
- Hyprland autostart so the tray comes back after every reboot
- Dynamic gateway detection so it works on any Wi-Fi (home, school, hotspot)

Tested on **CachyOS / Arch + Hyprland (illogical-impulse dots)**. Vanilla
`hyprland.conf` is also handled.

---

## One-liner install

```bash
curl -fsSL https://raw.githubusercontent.com/KaanAlper/warp-tray/main/install.sh | bash
```


You will be prompted once for `sudo` (the script re-launches itself as root)
and once for the `usque register` step (creates `~/config.json`, your WARP
device identity — **back this file up**).

That's it. After the script finishes, left-click the new tray icon to
connect. After a reboot the tray auto-starts via Hyprland's exec hook.

---

## Manual install (cloned repo)

```bash
git clone https://github.com/KaanAlper/warp-tray.git
cd REPO
./install.sh
```

---

## What the installer does

1. Detects Arch + `yay`, installs `python-pyside6`, `libnotify`, plus
   `usque-bin` (or `usque`) from the AUR.
2. Writes `/usr/local/bin/warp-on` and `/usr/local/bin/warp-off`.
3. Drops a `visudo`-validated `/etc/sudoers.d/warp` granting NOPASSWD for
   **only those two commands** — minimal attack surface.
4. Installs `~/.local/bin/warp-tray` (PySide6, SNI tray icon).
5. Appends a Hyprland autostart hook to your `custom/execs.lua` (or your
   vanilla `hyprland.conf`). Idempotent — re-run safely.
6. Runs `usque register` if no `~/config.json` exists.

Re-running the installer is safe; everything is overwrite-or-skip.

---

## Files

| Path | Owner | Purpose |
|------|-------|---------|
| `/usr/local/bin/warp-on` | root:root 0755 | Bring tunnel up + routes + DNS |
| `/usr/local/bin/warp-off` | root:root 0755 | Tear down tunnel + restore |
| `/etc/sudoers.d/warp` | root:root 0440 | NOPASSWD for those two only |
| `~/.local/bin/warp-tray` | user 0755 | Tray icon (PySide6) |
| `~/.config/hypr/custom/execs.lua` | user | Hyprland autostart (line appended) |
| `~/config.json` | user 0644 | usque device key — **back this up** |
| `/var/log/usque.log` | root | Tunnel diagnostics |

---

## Why MASQUE instead of WireGuard WARP

Stock Cloudflare WARP (`warp-cli`) uses WireGuard. In Turkey (and other
DPI-aggressive regions) WireGuard sometimes survives, sometimes gets
throttled, and the official client can be brittle on Linux (no captive-portal
support, fights with NetworkManager).

`usque` uses Cloudflare's newer **MASQUE-over-HTTP/3** transport — same
network, modern protocol, traffic indistinguishable from any other HTTP/3
session. Lighter DPI footprint, no `warp-svc` daemon, runs as your user.

---

## Why a custom tray instead of just `warp-cli` GUI

- `warp-cli` has no first-party tray on Linux at all.
- We want **per-network toggling** (off for school captive portal, on for
  home Discord access) — a one-click affordance.
- Quickshell on Hyprland presents an SNI tray; PySide6's
  `QSystemTrayIcon` registers via the same protocol → native look.

---

## Daily use

| Action | How |
|--------|-----|
| Connect / disconnect | Left-click tray icon |
| Menu | Right-click tray icon |
| Connect from terminal | `sudo -n warp-on` |
| Disconnect from terminal | `sudo -n warp-off` |
| See tunnel diagnostics | `tail -f /var/log/usque.log` |
| Check current state | `ip link show tun0` (exists ⇒ on) |

The icon polls `tun0` every 3 s, so external changes (script call, reboot,
WARP dropping itself) are reflected within ~3 s.

---

## Caveats / known footguns

- **Full tunnel architecture**: all your traffic goes through Cloudflare
  while WARP is on. Anthropic / OpenAI / GitHub sometimes flag Cloudflare
  WARP exit IPs (rate-limit, captcha). If that bothers you, toggle off
  while using those services or migrate to a SOCKS5 setup (out of scope
  for this repo).
- **Discord persistence**: closing WARP kills the active TCP socket to
  `discord.com` because its source IP is tun0's — Discord has to
  reconnect, and the bare reconnect gets DPI-blocked. Keep WARP on while
  using Discord, or use a local DPI bypass (zapret, byedpi) instead.
- **`config.json` is your WARP identity**: lose it and the bandwidth/quota
  on that anonymous WARP+ device is gone. The installer leaves it in
  `~/config.json`; copy it to a USB or cloud once.
- **Tested only on Cachy/Arch + Hyprland**. Other distros / WMs will need
  the autostart step done by hand.

---

## Uninstall

```bash
sudo rm /usr/local/bin/warp-on /usr/local/bin/warp-off /etc/sudoers.d/warp
rm ~/.local/bin/warp-tray
# Remove the warp-tray line from ~/.config/hypr/custom/execs.lua manually.
sudo pkill -9 -x usque
sudo ip link del tun0 2>/dev/null
```

`~/config.json` left alone — delete only if you're sure you don't want
that WARP identity back.

---

## License

MIT — do whatever, no warranty.
