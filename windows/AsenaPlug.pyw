#!/usr/bin/env python3
"""AsenaPlug — Windows giriş noktası (ince).

İlk çalıştırmada kurulum (admin gerekir), sonra tray olarak çalışır.
Tüm mantık `asenaplug/` paketinde. PyInstaller ile tek exe'ye paketlenir;
geliştirme için `pythonw AsenaPlug.pyw` ile de çalışır.
"""
import sys
from pathlib import Path

# Geliştirme modunda `asenaplug` paketini import edebilmek için
sys.path.insert(0, str(Path(__file__).resolve().parent))

from asenaplug import install, win  # noqa: E402
from asenaplug.tray import AsenaTray  # noqa: E402


def _msgbox_error(text: str):
    from PySide6.QtWidgets import QApplication, QMessageBox
    QApplication.instance() or QApplication(sys.argv)
    QMessageBox.critical(None, "AsenaPlug Kurulum Hatası", text)


def main():
    # Tray her zaman YÖNETİCİ olmalı: asena-on/off admin ister, script/exe kopyalama
    # da öyle. Kurulu olsa bile (logon görevi dışı elle açılışta) yönetici değilsek
    # UAC ile yüksel — yoksa connect olmaz ve yeni scriptler kopyalanmaz.
    if not win.is_admin():
        win.relaunch_as_admin()  # UAC; yükseltilmiş kopya devam eder, bu süreç biter

    if install.needs_setup():
        try:
            install.run_setup()  # exe'yi Program Files'a kopyalar, görevler, vb.
        except Exception as e:
            _msgbox_error(str(e))
            sys.exit(1)
    else:
        # Kurulu: scriptleri kod ile senkronla + güncel exe'yi Program Files'a kopyala
        install.refresh_scripts()
        install.install_self()

    # dist'ten çalışıyorsak Program Files'taki kurulu kopyaya DEVRET (aktif o olsun);
    # mutex'i tutmadan devret ki yeni süreç alabilsin.
    if not install.running_from_install() and install.APP_EXE.exists():
        install.launch_installed()
        sys.exit(0)

    # Aynı anda tek tray (logon görevi + elle açış iki tray açmasın)
    if not win.acquire_single_instance():
        sys.exit(0)
    AsenaTray().run()


if __name__ == "__main__":
    main()
