# warp-tray — Windows Portu

Windows 10/11 (x64). Cloudflare WARP (MASQUE/usque) için **seçilebilir routing** modlu sistem tepsisi göstergesi. Orijinal: [KaanAlper/warp-tray](https://github.com/KaanAlper/warp-tray) (Arch/Hyprland).

## İki eksenli mod

Tray menüsünden bağımsız iki seçim:

| Eksen | Seçenekler | Açıklama |
|---|---|---|
| **Routing** | **Sadece blacklist** *(default)* | Fiziksel internet default; yalnız `warp-blacklist.txt`'teki domainler WARP'tan geçer. |
| | **Her şey** | Tüm trafik WARP'tan geçer (split-default + endpoint pin). |
| **Transport** | **HTTP/2** *(default)* | TCP+TLS; DPI'ya dayanıklı (TR'de önerilir). |
| | **HTTP/3** | QUIC/UDP; daha düşük gecikme ama UDP 443 throttle yiyebilir. |

---

## Gereksinimler

| | |
|---|---|
| Windows 10/11 x64 | Kurulum admin (UAC) ister |
| Python 3.10+ **(yalnız kaynaktan çalıştırırken)** | PyInstaller exe için gerekmez |
| `PySide6`, `winotify` (pip) | exe içine paketlenir |

`usque.exe`, `wintun.dll`, `dnsproxy.exe` **repo'da gömülü gelir** (`windows/bundled/`) — runtime'da hiçbir şey indirilmez.

---

## Kurulum

> **`install.ps1` YOK.** Kurulum, exe/`.pyw` ilk çalıştırıldığında otomatik yapılır.

**Seçenek A — PyInstaller exe (kullanıcı için önerilen):**

```powershell
cd windows
.\build.ps1          # warp-tray.exe üretir (dist\warp-tray.exe)
.\dist\warp-tray.exe # ilk çalıştırma: UAC -> kurulum -> tray
```

**Seçenek B — kaynaktan (geliştirme):**

```powershell
cd windows
pip install PySide6 winotify
pythonw .\warp-tray.pyw
```

İlk çalıştırma (admin) şunları yapar:
1. `usque.exe` + `wintun.dll` + `dnsproxy.exe` → `C:\Program Files\usque\`
2. PowerShell scriptleri → `C:\Program Files\usque\scripts\`
3. `%ProgramData%\usque`'ye ACL (kullanıcı tray'i config yazabilsin, SYSTEM okuyabilsin)
4. Task Scheduler görevleri:
   - `WarpTray_Tray` — logon'da tray'i **yükseltilmiş (Highest)** başlatır (autostart + admin; kullanıcı yerel admin ise UAC promptu yok)
   - `WarpTray_RouteSync` — SYSTEM daemon (blacklist /32 + IPv6 fail-closed)
   - `WarpTray_Rescue` — boot+logon SYSTEM kurtarma (DNS/route artığı temizle)
5. `usque register` → `%ProgramData%\usque\config\config.json` (**YEDEKLE!**)

> **Privilege modeli:** Tray elevated çalışır ve `warp-*.ps1`'i doğrudan admin olarak
> koşar. Eski "standart kullanıcı SYSTEM task tetikler" sorunu (ve kırılgan SDDL/ACL
> ayarı) böylece tamamen elenir.

---

## Mimari (Linux ↔ Windows)

| Özellik | Linux | Windows (bu port) |
|---|---|---|
| Tünel | `usque` MASQUE | `usque.exe` (aynı) |
| TUN | wireguard/wintun | `wintun.dll` |
| Selective (domain) | `dnsmasq` + nftset | `dnsproxy` + `/32` route (route-sync) |
| Full tunnel | tablo + default | split-default `0.0.0.0/1`+`128.0.0.0/1` |
| Endpoint koruması | fwmark | endpoint `/32` fiziksel'de pin |
| IPv6 leak | nft reject | outbound firewall block (fail-closed) |
| **Per-app routing** | cgroup + fwmark | **YOK** (Windows'ta kernel driver/WFP gerekir) |
| Yönetici komut | sudoers NOPASSWD | Task Scheduler (SYSTEM) |
| Durum tespiti | `ip link` | ctypes `GetAdaptersAddresses` (powershell yok) |
| Bildirim | notify-send | winotify |
| Autostart | Hyprland exec-once | Startup klasörü (VBS) |

> **Not:** Linux'taki per-app (Discord-only) routing Windows'ta yoktur. Onun yerine "Her şey" (full tunnel) modu var.

---

## Dosyalar

| Yol | Açıklama |
|---|---|
| `C:\Program Files\usque\{usque,dnsproxy}.exe, wintun.dll` | Binary'ler |
| `C:\Program Files\usque\scripts\*.ps1` | warp-on/off/dns-reload/route-sync/rescue |
| `%ProgramData%\usque\config\config.json` | usque kimliği — **YEDEKLE** |
| `%ProgramData%\usque\config\warp-blacklist.txt` | Domain blacklist |
| `%ProgramData%\usque\run\state.json` | Gerçek durum (tray buradan okur) |
| `%ProgramData%\usque\run\desired.json` | Tray'in istediği mod |
| `%ProgramData%\usque\usque.log` | Loglar |

---

## Kaldırma

```powershell
"WarpTray_Tray","WarpTray_RouteSync","WarpTray_Rescue" |
    ForEach-Object { Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue }
Remove-Item "C:\Program Files\usque" -Recurse -Force
# %ProgramData%\usque\config\config.json kimliğin orada — silmeden önce yedekle.
Remove-Item "C:\ProgramData\usque" -Recurse -Force
```

---

## Lisans

MIT — orijinal proje ile aynı.
