"""Tüm yol sabitleri ve Task Scheduler görev adları — tek kaynak.

ÖNEMLİ: Scriptler Task Scheduler ile SYSTEM olarak çalışır. SYSTEM'in
%APPDATA% / %USERPROFILE%'ı kullanıcınınkinden farklıdır. Bu yüzden hem
kullanıcı (tray) hem SYSTEM (scriptler) tarafından okunan/yazılan TÜM
config %ProgramData%\\usque altında tutulur (setup ACL ile yazılabilir yapar).
"""
import os
from pathlib import Path

# --- Program dosyaları (binary + script) ---
INSTALL_DIR  = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "usque"
SCRIPTS_DIR  = INSTALL_DIR / "scripts"
USQUE_EXE    = INSTALL_DIR / "usque.exe"
WINTUN_DLL   = INSTALL_DIR / "wintun.dll"
DNSPROXY_EXE = INSTALL_DIR / "dnsproxy.exe"

# --- Paylaşılan veri (%ProgramData%\usque) — kullanıcı + SYSTEM ortak ---
DATA_DIR      = Path(os.environ.get("ProgramData", r"C:\ProgramData")) / "usque"
CONFIG_DIR    = DATA_DIR / "config"
RUN_DIR       = DATA_DIR / "run"
LOG_FILE      = DATA_DIR / "usque.log"
SETUP_FLAG    = DATA_DIR / "installed.flag"

BLACKLIST_PATH = CONFIG_DIR / "asena-blacklist.txt"
CONFIG_JSON    = CONFIG_DIR / "config.json"          # usque cihaz kimliği
STATE_FILE     = RUN_DIR / "state.json"              # gerçek çalışan durum
DESIRED_FILE   = RUN_DIR / "desired.json"            # tray'in istediği
RESOLVED_FILE  = RUN_DIR / "asena-resolved-ips.txt"   # route-sync IP defteri

TUN_NAME = "usque"

# Kullanıcıya görünen uygulama adı (tray, bildirimler, exe). İç tanımlayıcılar
# (usque yolları, AsenaPlug_* görevleri, asenaplug paketi) aynı kalır.
APP_NAME = "AsenaPlug"

# --- Varsayılan mod ---
DEFAULT_TRANSPORT = "http2"      # DPI-stealth; TR'de dayanıklı
DEFAULT_SCOPE     = "selective"  # fiziksel default, sadece blacklist Asena'tan

TRANSPORTS = ("http2", "http3")
SCOPES     = ("selective", "full")

# --- Task Scheduler görev adları ---
# Privilege modeli: tray, logon'da YÜKSELTİLMİŞ (Highest) bir görevle başlar
# (UAC promptu yok). Elevated tray, asena-*.ps1'i DOĞRUDAN admin olarak çalıştırır
# (win.run_script). Bu yüzden ayrı on/off/dns SYSTEM görevine gerek yok; standart
# kullanıcının SYSTEM görevini tetikleme izni sorunu (SDDL/ACL cerrahisi) da kalkar.
#   tray       — logon'da elevated tray (kullanıcı principal, Highest)
#   route_sync — SYSTEM daemon; asena-on Start-ScheduledTask ile tetikler
#   rescue     — boot+logon SYSTEM kurtarma (DNS/route artığı temizle)
TASKS = {
    "tray":       "AsenaPlug_Tray",
    "route_sync": "AsenaPlug_RouteSync",
    "rescue":     "AsenaPlug_Rescue",
}
