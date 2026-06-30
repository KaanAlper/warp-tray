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


def _msgbox_question(text: str) -> bool:
    from PySide6.QtWidgets import QApplication, QMessageBox
    QApplication.instance() or QApplication(sys.argv)
    ret = QMessageBox.question(None, "AsenaPlug Kurulum", text)
    return ret == QMessageBox.StandardButton.Yes


def _msgbox_error(text: str):
    from PySide6.QtWidgets import QApplication, QMessageBox
    QApplication.instance() or QApplication(sys.argv)
    QMessageBox.critical(None, "AsenaPlug Kurulum Hatası", text)


def main():
    if install.needs_setup():
        if not win.is_admin():
            if not _msgbox_question(
                "AsenaPlug ilk kurulum için yönetici yetkisi gerektirir.\n"
                "Devam edilsin mi?"
            ):
                sys.exit(0)
            win.relaunch_as_admin()  # UAC ile yeniden başlar, bu süreç biter
        try:
            install.run_setup()
        except Exception as e:
            _msgbox_error(str(e))
            sys.exit(1)
    else:
        # Kurulu ama scriptler kod ile senkron olsun (kurulum bir kez çalışır)
        install.refresh_scripts()
    WarpTray().run()


if __name__ == "__main__":
    main()
