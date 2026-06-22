# warp-tray

Cloudflare WARP (MASQUE/usque) with a **selective routing** system-tray indicator for Hyprland + Quickshell.

**Physical internet is the default.** Only specific apps and domains in your blacklist are routed through WARP.

What you get:

- `warp-on` / `warp-off` shell commands (sudo NOPASSWD, scoped)
- A clickable tray icon (PySide6, no theme dependency)
  - green "W" when connected, gray outline when disconnected
  - left click toggles, right click opens menu
  - state-change notifications via `notify-send`
- **Force WARP** submenu — pick which apps or interfaces go through WARP
- **Blacklist** submenu — domain list (e.g. GoodByDPI list), edit or reload live
- Hyprland autostart so the tray comes back after every reboot
- Dynamic gateway detection so it works on any network

Tested on **CachyOS / Arch + Hyprland (end-4 / illogical-impulse dots)**.

---

## One-liner install

```bash
curl -fsSL https://raw.githubusercontent.com/kaanalper/warp-tray-setup/main/install.sh | bash
```

You will be prompted once for `sudo` (the script re-launches itself as root)
and once for the `usque register` step (creates `~/config.json`, your WARP
device identity — **back this file up**).

---

## Manual install (cloned repo)

```bash
git clone https://github.com/kaanalper/warp-tray-setup.git
cd warp-tray-setup
./install.sh
```

---

## How selective routing works

```
physical default route  ─── Zen Browser, everything else
warp-only.slice cgroup  ─── Discord (app entry in warp-route.conf)
dnsmasq + nftables      ─── blacklist domains (nhentai, xvideos, etc.)
```

- **App routing**: apps listed under `app` in `~/.config/warp-route.conf` are automatically moved into the `warp-only.slice` systemd cgroup. Any PID in that cgroup gets `fwmark 0x43` via an nftables cgroup rule → routes to table 201 → tun0.
- **Domain routing**: a dnsmasq instance on `127.0.0.2:53` uses Yandex's port-1253 DNS to bypass Turkish ISP port-53 interception. For each blacklisted domain, DNS responses populate an nftables `warp_hosts` IP set. Traffic to those IPs gets the same fwmark.
- **Interface routing**: `iface` entries in `warp-route.conf` apply an nftables PREROUTING rule.
- **TCP MSS clamp**: tun0 MTU=1280 vs LAN MTU=1500. Without clamping, large TLS handshake packets get dropped silently. Fixed with `tcp option maxseg size set 1220` in POSTROUTING.
- **Connection persistence (conntrack mark)**: the fwmark is saved to the connection's conntrack entry and restored on every packet. So an established connection keeps routing through WARP even if the `warp_hosts` set entry expires (300s→1h TTL) mid-stream — no mid-connection drop or leak.
- **IPv6 fail-closed**: tun0 carries IPv4 only. To prevent leaks, IPv6 traffic that *would* go through WARP (blacklist domains via `warp_hosts6`, or cgroup apps) is `reject`ed with ICMPv6 admin-prohibited, forcing the app to fall back to IPv4 — which goes through WARP. A censorship-bypass tool must fail closed, not leak.
- **rp_filter**: loosened to `2` (needed for the asymmetric WARP/physical routing) and the original value is saved to `/run/warp` and restored by `warp-off`.

---

## What the installer does

1. Installs `python-pyside6`, `libnotify`, `dnsmasq`, `nftables`, plus `usque-bin` from AUR.
2. Writes these scripts to `/usr/local/bin/`:
   - `warp-on` — starts usque, sets up nftables/iproute2 policy routing, starts dnsmasq
   - `warp-off` — tears down everything
   - `warp-bypass-reload` — reloads iface rules from conf without restarting WARP
   - `warp-dnsmasq-gen` — generates `/etc/dnsmasq-warp.conf` from `~/.config/warp-blacklist.txt`
   - `warp-dns-reload` — reruns `warp-dnsmasq-gen` and restarts dnsmasq live
3. Drops `/etc/sudoers.d/warp` — NOPASSWD for only those five commands.
4. Installs `~/.local/bin/warp-tray` (PySide6 tray).
5. Installs `~/.local/bin/discord` — launcher wrapper that puts Discord in `warp-only.slice`.
6. Creates `~/.config/warp-route.conf` template (if missing).
7. Appends Hyprland autostart to `custom/execs.lua` or `hyprland.conf`.
8. Runs `usque register` if no `~/config.json` exists.

Re-running is safe; everything is overwrite-or-skip.

---

## Files

| Path | Owner | Purpose |
|------|-------|---------|
| `/usr/local/bin/warp-on` | root 0755 | Bring tunnel up + routes + nft + dnsmasq |
| `/usr/local/bin/warp-off` | root 0755 | Tear everything down |
| `/usr/local/bin/warp-bypass-reload` | root 0755 | Reload iface rules live |
| `/usr/local/bin/warp-dnsmasq-gen` | root 0755 | Generate dnsmasq config from blacklist |
| `/usr/local/bin/warp-dns-reload` | root 0755 | Hot-reload DNS blacklist |
| `/etc/sudoers.d/warp` | root 0440 | NOPASSWD for the above only |
| `~/.local/bin/warp-tray` | user 0755 | Tray icon (PySide6) |
| `~/.local/bin/discord` | user 0755 | Discord launcher (warp-only.slice) |
| `~/.config/warp-route.conf` | user | App/iface routing config (tray r/w) |
| `~/.config/warp-blacklist.txt` | user | Domain blacklist (one per line) |
| `~/config.json` | user | usque device key — **back this up** |
| `/etc/dnsmasq-warp.conf` | root | Generated dnsmasq config |
| `/var/log/usque.log` | root | Tunnel diagnostics |

---

## Daily use

| Action | How |
|--------|-----|
| Toggle WARP | Left-click tray icon |
| Force specific app through WARP | Right-click → Force WARP → Add running app |
| Force interface through WARP | Right-click → Force WARP → Add interface… |
| Add domain to blacklist | Right-click → Blacklist → Domain ekle… |
| Edit blacklist file | Right-click → Blacklist → Düzenle… |
| Reload DNS after editing blacklist | Right-click → Blacklist → DNS yenile |
| Connect HTTP/2 (default, DPI-stealthy) | Left-click or right-click → HTTP/2 |
| Connect HTTP/3 (faster on clean lines) | Right-click → HTTP/3 |
| Disconnect | Right-click → Disconnect or left-click |
| Terminal connect | `sudo -n warp-on` or `sudo -n warp-on http3` |
| Terminal disconnect | `sudo -n warp-off` |
| Tunnel diagnostics | `tail -f /var/log/usque.log` |

### HTTP/2 vs HTTP/3

| | HTTP/2 (TCP+TLS) | HTTP/3 (QUIC/UDP) |
|---|---|---|
| DPI resistance in TR | High — looks like normal HTTPS | Low — UDP 443 throttled |
| Latency | 2–3 RTT | 0–1 RTT |
| Discord stability | Better | Worse (UDP drops cascade) |

**Default is HTTP/2** — survives Turkish ISP shaping better.

---

## GoodByDPI blacklist integration

Copy any domain list (one domain per line, `*.example.com` wildcards stripped automatically) to `~/.config/warp-blacklist.txt`. The tray's **Blacklist → DNS yenile** applies it live.

```bash
# Example: import from GoodByDPI's blacklist.txt
cp /path/to/blacklist.txt ~/.config/warp-blacklist.txt
# Then: tray → Blacklist → DNS yenile
```

---

## Uninstall

```bash
sudo warp-off 2>/dev/null || true
sudo rm /usr/local/bin/warp-on /usr/local/bin/warp-off \
        /usr/local/bin/warp-bypass-reload /usr/local/bin/warp-dnsmasq-gen \
        /usr/local/bin/warp-dns-reload /etc/sudoers.d/warp /etc/dnsmasq-warp.conf
rm ~/.local/bin/warp-tray ~/.local/bin/discord
# Remove warp-tray line from ~/.config/hypr/custom/execs.lua manually.
```

`~/config.json` is left alone — delete only if you're sure you don't need that WARP identity.

---

## Why MASQUE instead of WireGuard WARP

Stock Cloudflare WARP (`warp-cli`) uses WireGuard. In Turkey (and other DPI-aggressive regions) WireGuard gets throttled, and the official client can be brittle on Linux.

`usque` uses Cloudflare's **MASQUE-over-HTTP/2 or HTTP/3** — traffic indistinguishable from normal HTTPS. Lighter DPI footprint, no `warp-svc` daemon, runs as your user.

---

## License

MIT — do whatever, no warranty.
