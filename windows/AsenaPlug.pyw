#!/usr/bin/env python3
"""AsenaPlug — Windows giriş noktası (ince).

İlk çalıştırmada kurulum (admin gerekir), sonra tray olarak çalışır.
Tüm mantık `warp_tray/` paketinde. PyInstaller ile tek exe'ye paketlenir;
geliştirme için `pythonw AsenaPlug.pyw` ile de çalışır.
"""
import sys
from pathlib import Path

# Geliştirme modunda `warp_tray` paketini import edebilmek için
sys.path.insert(0, str(Path(__file__).resolve().parent))

from warp_tray import install, win  # noqa: E402
from warp_tray.tray import WarpTray  # noqa: E402


def _msgbox_error(text: str):
    from PySide6.QtWidgets import QApplication, QMessageBox
    QApplication.instance() or QApplication(sys.argv)
    QMessageBox.critical(None, "AsenaPlug Kurulum Hatası", text)


def main():
    # Tray her zaman YÖNETİCİ olmalı: warp-on/off admin ister, script/exe kopyalama
    # da öyle. Kurulu olsa bile (logon görevi dışı elle açılışta) yönetici değilsek
    # UAC ile yüksel — yoksa connect olmaz ve yeni scriptler kopyalanmaz.
    if not win.is_admin():
        win.relaunch_as_admin()  # UAC; yükseltilmiş kopya devam eder, bu süreç biter

    # Aynı anda tek tray (logon görevi + elle açış iki tray açmasın)
    if not win.acquire_single_instance():
        sys.exit(0)

    if install.needs_setup():
        try:
            install.run_setup()
        except Exception as e:
            _msgbox_error(str(e))
            sys.exit(1)
    else:
        # Kurulu: scriptleri kod ile senkronla + güncel exe'yi Program Files'a kopyala
        install.refresh_scripts()
        install.install_self()
    WarpTray().run()


if __name__ == "__main__":
    main()
