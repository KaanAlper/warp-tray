#!/usr/bin/env bash
# warp-tray (eski) -> AsenaPlug (yeni) Linux migration. Normal kullanıcı olarak çalıştır:
#   bash migrate-asena.sh
# Idempotent: tekrar çalıştırmak güvenli.
set -u
cd "$(dirname "$(readlink -f "$0")")"

echo ":: 1/5  Eski warp durduruluyor…"
sudo /usr/local/bin/warp-off 2>/dev/null || true
pkill -f warp-tray 2>/dev/null || true

echo ":: 2/5  Ayar taşınıyor (blacklist + route; kimlik ~/config.json zaten ortak)…"
[ -f "$HOME/.config/warp-blacklist.txt" ] && cp -n "$HOME/.config/warp-blacklist.txt" "$HOME/.config/asena-blacklist.txt" && echo "   blacklist taşındı"
[ -f "$HOME/.config/warp-route.conf" ]    && cp -n "$HOME/.config/warp-route.conf"    "$HOME/.config/asena-route.conf"    && echo "   route.conf taşındı"

echo ":: 3/5  Yeni sürüm kuruluyor (install.sh; sudo parolası isteyebilir)…"
./install.sh

echo ":: 4/5  Eski warp artıkları temizleniyor…"
sudo rm -f /usr/local/bin/warp-on /usr/local/bin/warp-off /usr/local/bin/warp-bypass-reload \
           /usr/local/bin/warp-dnsmasq-gen /usr/local/bin/warp-dns-reload \
           /etc/sudoers.d/warp /etc/dnsmasq-warp.conf /run/dnsmasq-warp.pid 2>/dev/null || true
sudo rm -rf /run/warp 2>/dev/null || true
rm -f "$HOME/.local/bin/warp-tray"

echo ":: 5/5  Bitti."
echo
echo "   - Hyprland autostart'taki eski 'warp-tray' satırını elle sil:"
echo "       ~/.config/hypr/custom/execs.lua  (veya hyprland.conf)"
echo "   - Trayi başlat:  ~/.local/bin/asena-tray &   (ya da reboot)"
echo "   - Komutlar artık: asena-on / asena-off / asena-dns-reload …"
