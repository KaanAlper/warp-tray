"""İlk kurulum: binary kopyala, ACL ayarla, Task Scheduler görevlerini kur
(tray logon + route_sync + rescue), blacklist şablonu yaz, usque register.

Tüm binary'ler bundle'dan (PyInstaller _MEIPASS veya repo) kopyalanır —
RUNTIME İNDİRME YOK (eski koddaki dnsproxy indirme + sessiz hata kaldırıldı;
dnsproxy.exe artık bundled/ içinde gelir).
"""
import shutil
import subprocess
import sys
from pathlib import Path

from . import win
from .paths import (
    INSTALL_DIR, SCRIPTS_DIR, USQUE_EXE, WINTUN_DLL, DNSPROXY_EXE,
    DATA_DIR, CONFIG_DIR, RUN_DIR, CONFIG_JSON, BLACKLIST_PATH, SETUP_FLAG, LOG_FILE,
    TASKS,
)

CREATE_NO_WINDOW = 0x08000000

SCRIPT_NAMES = [
    "warp-on.ps1", "warp-off.ps1", "warp-dns-reload.ps1",
    "warp-route-sync.ps1", "warp-rescue.ps1",
]


def log(msg: str):
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        import time
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + "  [install] " + msg + "\n")
    except Exception:
        pass


def bundle_path(relative: str) -> Path:
    """PyInstaller _MEIPASS, yoksa repo'daki windows/ dizini."""
    base = getattr(sys, "_MEIPASS", str(Path(__file__).resolve().parent.parent))
    return Path(base) / relative


def needs_setup() -> bool:
    return not SETUP_FLAG.exists()


def run_setup():
    """Admin gerektirir. Tüm kurulum adımlarını sırayla yapar."""
    # 1. Dizinler
    for d in (INSTALL_DIR, SCRIPTS_DIR, DATA_DIR, CONFIG_DIR, RUN_DIR):
        d.mkdir(parents=True, exist_ok=True)

    # 2. Binary'ler (bundled'dan kopya — indirme yok)
    for fname, dst in (("usque.exe", USQUE_EXE),
                       ("wintun.dll", WINTUN_DLL),
                       ("dnsproxy.exe", DNSPROXY_EXE)):
        src = bundle_path(f"bundled/{fname}")
        if not (src.exists() and src.stat().st_size > 0):
            raise FileNotFoundError(
                f"{fname} bundle içinde yok!\nBeklenen: {src}\n"
                "windows/bundled/ içine koy ve tekrar build al."
            )
        shutil.copy2(src, dst)

    # 3. Scriptler
    for ps in SCRIPT_NAMES:
        src = bundle_path(f"scripts/{ps}")
        if src.exists():
            shutil.copy2(src, SCRIPTS_DIR / ps)

    # 4. Paylaşılan veri dizinine ACL: Authenticated Users (S-1-5-11) Modify.
    #    Böylece normal-kullanıcı tray desired.json/blacklist yazar, SYSTEM okur.
    _grant_users_modify(DATA_DIR)

    # 5. Task Scheduler görevleri (SYSTEM)
    _register_tasks()

    # 6. Blacklist şablonu
    if not BLACKLIST_PATH.exists():
        BLACKLIST_PATH.write_text(
            "# Domain blacklist — satır başına bir domain.\n"
            "# Sadece 'Sadece blacklist' (selective) modunda WARP'tan geçer.\n"
            "# Örnek:\n"
            "# nhentai.net\n"
            "# twitter.com\n",
            encoding="utf-8",
        )

    # 7. usque register (cihaz kimliği yoksa)
    if not CONFIG_JSON.exists():
        _run_usque_register()

    # 8. Tamamlandı (autostart = WarpTray_Tray logon görevi, adım 5'te kuruldu)
    SETUP_FLAG.touch()


def _grant_users_modify(path: Path):
    try:
        subprocess.run(
            ["icacls", str(path), "/grant", "*S-1-5-11:(OI)(CI)M", "/T", "/C"],
            check=False, capture_output=True, creationflags=CREATE_NO_WINDOW,
        )
    except Exception as e:
        log(f"icacls başarısız: {e}")


def _tray_launch():
    """(Execute, Argument) — frozen exe ise exe; değilse pythonw + .pyw."""
    if getattr(sys, "frozen", False):
        return sys.executable, ""
    pyw = Path(sys.executable).with_name("pythonw.exe")
    runner = str(pyw if pyw.exists() else sys.executable)
    return runner, f'\"{Path(sys.argv[0]).resolve()}\"'


def _register_tasks():
    # SYSTEM görevleri: route_sync (daemon, warp-on tetikler), rescue (boot+logon)
    sys_defs = [
        (TASKS["route_sync"], "warp-route-sync.ps1", "(New-TimeSpan -Days 3650)", None),
        (TASKS["rescue"],     "warp-rescue.ps1",     "(New-TimeSpan -Minutes 1)", "rescue"),
    ]
    blocks = []
    for name, script, limit, trig in sys_defs:
        trigger_line = ""
        register_trigger = ""
        if trig == "rescue":
            trigger_line = (
                "$t1 = New-ScheduledTaskTrigger -AtStartup\n"
                "$t2 = New-ScheduledTaskTrigger -AtLogOn\n"
            )
            register_trigger = "-Trigger @($t1,$t2) "
        target = SCRIPTS_DIR / script
        blocks.append(f"""
Unregister-ScheduledTask -TaskName '{name}' -Confirm:$false -ErrorAction SilentlyContinue
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File "{target}"'
{trigger_line}$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit {limit} -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName '{name}' -Action $a {register_trigger}-Settings $s -Principal $p | Out-Null
""")

    # Tray görevi: logon'da YÜKSELTİLMİŞ (Highest) tray, oturum açan kullanıcı olarak.
    # Kullanıcı yerel admin ise UAC promptu olmadan elevated başlar (autostart + privilege).
    exe, arg = _tray_launch()
    arg_part = f"-Argument '{arg}' " if arg else ""
    blocks.append(f"""
Unregister-ScheduledTask -TaskName '{TASKS["tray"]}' -Confirm:$false -ErrorAction SilentlyContinue
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$a = New-ScheduledTaskAction -Execute '{exe}' {arg_part}
$t = New-ScheduledTaskTrigger -AtLogOn -User $me
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Days 3650) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$p = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName '{TASKS["tray"]}' -Action $a -Trigger $t -Settings $s -Principal $p | Out-Null
""")

    ps_code = "\n".join(blocks)
    subprocess.run(
        ["powershell", "-ExecutionPolicy", "Bypass", "-NonInteractive", "-Command", ps_code],
        check=True, capture_output=True, creationflags=CREATE_NO_WINDOW,
    )


def _run_usque_register():
    try:
        # config.json'ı paylaşılan CONFIG_DIR'a yaz (SYSTEM task buradan okur)
        subprocess.run([str(USQUE_EXE), "register"], cwd=str(CONFIG_DIR), check=True)
    except Exception as e:
        log(f"usque register başarısız: {e} — elle: cd \"{CONFIG_DIR}\" && usque register")
