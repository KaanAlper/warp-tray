# AsenaPlug — Windows

**Selective DPI / DNS-censorship bypass over Cloudflare MASQUE (usque) — a Windows system-tray app with per-domain and full-tunnel modes.**

🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

Original Linux project: [KaanAlper/AsenaPlug](https://github.com/KaanAlper/AsenaPlug) (Arch/Hyprland).

---

## English

### Two independent axes
Pick both from the tray menu:

| Axis | Options | Meaning |
|---|---|---|
| **Routing** | **Blacklist only** *(default)* | Physical internet stays default; only domains in `asena-blacklist.txt` go through the tunnel. |
| | **Everything** | All traffic through the tunnel (split-default + endpoint pin). |
| **Transport** | **HTTP/2** *(default)* | TCP+TLS; DPI-resistant (recommended in TR). |
| | **HTTP/3** | QUIC/UDP; lower latency but UDP 443 may be throttled. |

### Requirements
- Windows 10/11 x64 (setup needs admin / UAC)
- Python 3.10+ **only when running from source** (not needed for the PyInstaller exe)
- `PySide6`, `winotify` (pip) — bundled into the exe

`usque.exe`, `wintun.dll`, `dnsproxy.exe` **ship inside the repo** (`windows/bundled/`) — nothing is downloaded at runtime.

### Install
> **No `install.ps1`.** Setup runs automatically the first time the exe/`.pyw` starts.

**Option A — PyInstaller exe (recommended):**
```powershell
cd windows
.\build.ps1            # builds dist\AsenaPlug.exe (with the wolf icon)
.\dist\AsenaPlug.exe   # first run: UAC -> setup -> tray
```
On first run the exe **copies itself to `C:\Program Files\usque\AsenaPlug.exe`**, makes a **desktop shortcut**, and auto-starts at logon from there — so you can delete `dist\`. Only one tray runs at a time.

> **Update:** quit the running tray (**Exit**), then run the new `dist\AsenaPlug.exe` (as admin) → it copies itself to Program Files. Your settings/blacklist/identity are **preserved** (setup runs once; only code is refreshed).

**Option B — from source (development):**
```powershell
cd windows
pip install PySide6 winotify
pythonw .\AsenaPlug.pyw
```

First run (admin) does:
1. `usque.exe` + `wintun.dll` + `dnsproxy.exe` → `C:\Program Files\usque\`
2. PowerShell scripts → `C:\Program Files\usque\scripts\`
3. ACL on `%ProgramData%\usque` (user tray writes config, SYSTEM reads)
4. Task Scheduler tasks: `AsenaPlug_Tray` (elevated tray at logon), `AsenaPlug_RouteSync` (SYSTEM daemon), `AsenaPlug_Rescue` (boot/logon cleanup)
5. `usque register` → `%ProgramData%\usque\config\config.json` (**back this up!**)

### How it works
- **Blacklist mode:** the system DNS is **not** touched. Only blacklisted domains are sent (via Windows **NRPT**) to a local `dnsproxy` whose upstream (`1.1.1.1`) is **routed through the tunnel** — so DNS answers can't be poisoned. Resolved IPs are routed through the tunnel (`route-sync`). Everything else uses your normal ISP DNS/route. IPv6 for blacklisted domains is **fail-closed** (firewall) so apps fall back to tunneled IPv4.
- **Everything mode:** split-default (`0.0.0.0/1`+`128.0.0.0/1`) through the tunnel, endpoint pinned on the physical link (no loop), global IPv6 blocked (no leak; usque is IPv4-only).
- **MTU/MSS** clamped (1260) so large packets fit the tunnel (otherwise pages load only partially).

### Architecture (Linux ↔ Windows)
| Feature | Linux | Windows (this port) |
|---|---|---|
| Tunnel | `usque` MASQUE | `usque.exe` (same) |
| Selective DNS | dnsmasq + nftset | NRPT → dnsproxy (DNS via tunnel) |
| Selective routing | fwmark + nftset | `/32` routes (route-sync) |
| Full tunnel | table + default | split-default `/1` routes |
| IPv6 leak | nft reject | firewall block (fail-closed) |
| **Per-app routing** | cgroup + fwmark | **N/A** (needs a kernel/WFP driver) |
| Admin commands | sudoers NOPASSWD | elevated tray (logon task, Highest) |
| State detection | `ip link` | ctypes `GetAdaptersAddresses` (no powershell) |

### Uninstall
**Admin PowerShell** (one command — first tears down cleanly: NRPT, IPv6 firewall, routes, DNS; then removes tasks/shortcut/files):
```powershell
& "C:\Program Files\usque\scripts\asena-uninstall.ps1"
```
> Deleting the folder while connected is **wrong**: NRPT rules linger and blacklisted domains point at a dead `127.0.0.2` (won't resolve). The script prevents this.

Your identity (`config.json`) is kept. To remove everything (back it up first!):
```powershell
Remove-Item "C:\ProgramData\usque" -Recurse -Force
```

### License
MIT — same as the original project.

---

## Türkçe

### İki bağımsız eksen
Tray menüsünden ikisini de seç:

| Eksen | Seçenekler | Anlamı |
|---|---|---|
| **Routing** | **Sadece blacklist** *(default)* | Fiziksel internet default; yalnız `asena-blacklist.txt`'teki domainler tünelden geçer. |
| | **Her şey** | Tüm trafik tünelden geçer (split-default + endpoint pin). |
| **Transport** | **HTTP/2** *(default)* | TCP+TLS; DPI'ya dayanıklı (TR'de önerilir). |
| | **HTTP/3** | QUIC/UDP; daha düşük gecikme ama UDP 443 throttle yiyebilir. |

### Gereksinimler
- Windows 10/11 x64 (kurulum admin / UAC ister)
- Python 3.10+ **yalnız kaynaktan çalıştırırken** (PyInstaller exe için gerekmez)
- `PySide6`, `winotify` (pip) — exe içine paketlenir

`usque.exe`, `wintun.dll`, `dnsproxy.exe` **repo'da gömülü gelir** (`windows/bundled/`) — runtime'da hiçbir şey indirilmez.

### Kurulum
> **`install.ps1` YOK.** Kurulum, exe/`.pyw` ilk çalıştığında otomatik yapılır.

**Seçenek A — PyInstaller exe (önerilen):**
```powershell
cd windows
.\build.ps1            # dist\AsenaPlug.exe üretir (kurt ikonlu)
.\dist\AsenaPlug.exe   # ilk çalıştırma: UAC -> kurulum -> tray
```
İlk çalıştırmada exe **kendini `C:\Program Files\usque\AsenaPlug.exe`'ye kopyalar**, **masaüstü kısayolu** yapar ve logon'da oradan otomatik başlar — `dist\`'i silebilirsin. Aynı anda tek tray çalışır.

> **Güncelleme:** çalışan tray'i **Çıkış**'tan kapat, sonra yeni `dist\AsenaPlug.exe`'yi (yönetici) çalıştır → kendini Program Files'a kopyalar. Ayarların/blacklist/kimliğin **korunur** (kurulum bir kez çalışır; sadece kod tazelenir).

**Seçenek B — kaynaktan (geliştirme):**
```powershell
cd windows
pip install PySide6 winotify
pythonw .\AsenaPlug.pyw
```

İlk çalıştırma (admin) şunları yapar:
1. `usque.exe` + `wintun.dll` + `dnsproxy.exe` → `C:\Program Files\usque\`
2. PowerShell scriptleri → `C:\Program Files\usque\scripts\`
3. `%ProgramData%\usque`'ye ACL (kullanıcı tray config yazar, SYSTEM okur)
4. Task Scheduler: `AsenaPlug_Tray` (logon'da elevated tray), `AsenaPlug_RouteSync` (SYSTEM daemon), `AsenaPlug_Rescue` (boot/logon temizlik)
5. `usque register` → `%ProgramData%\usque\config\config.json` (**YEDEKLE!**)

### Nasıl çalışır
- **Blacklist modu:** sistem DNS'ine **dokunulmaz**. Sadece blacklist domainleri Windows **NRPT** ile yerel `dnsproxy`'ye gider; onun upstream'i (`1.1.1.1`) **tünelden** sorulur → DNS zehirlenemez. Çözülen IP'ler tünele route edilir (`route-sync`). Gerisi normal ISP DNS/route kullanır. Blacklist domainlerinin IPv6'sı **fail-closed** (firewall) → uygulama tünelli IPv4'e düşer.
- **Her şey modu:** split-default (`0.0.0.0/1`+`128.0.0.0/1`) tünelden, endpoint fiziksel'de pinli (loop yok), global IPv6 bloklu (leak yok; usque IPv4-only).
- **MTU/MSS** clamp (1260) → büyük paketler tünele sığar (yoksa sayfalar yarım yüklenir).

### Mimari (Linux ↔ Windows)
| Özellik | Linux | Windows (bu port) |
|---|---|---|
| Tünel | `usque` MASQUE | `usque.exe` (aynı) |
| Selective DNS | dnsmasq + nftset | NRPT → dnsproxy (DNS tünelden) |
| Selective routing | fwmark + nftset | `/32` route (route-sync) |
| Full tunnel | tablo + default | split-default `/1` route |
| IPv6 leak | nft reject | firewall block (fail-closed) |
| **Per-app routing** | cgroup + fwmark | **YOK** (kernel/WFP sürücüsü gerekir) |
| Admin komut | sudoers NOPASSWD | elevated tray (logon görevi, Highest) |
| Durum tespiti | `ip link` | ctypes `GetAdaptersAddresses` (powershell yok) |

### Kaldırma
**Yönetici PowerShell** (tek komut — önce düzgün teardown: NRPT, IPv6 firewall, route, DNS; sonra görev/kısayol/dosya):
```powershell
& "C:\Program Files\usque\scripts\asena-uninstall.ps1"
```
> Bağlıyken klasörü silmek **yanlış**: NRPT kalır, blacklist domainleri ölü `127.0.0.2`'ye yönlenir (çözülmez). Script bunu önler.

Kimliğin (`config.json`) korunur. Tamamen silmek için (yedekle!):
```powershell
Remove-Item "C:\ProgramData\usque" -Recurse -Force
```

### Lisans
MIT — orijinal proje ile aynı.
