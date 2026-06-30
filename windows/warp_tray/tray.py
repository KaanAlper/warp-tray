"""Sistem tepsisi arayüzü.

İki bağımsız seçici:
  Transport: HTTP/2 · HTTP/3   (exclusive)
  Routing:   Sadece blacklist · Her şey  (exclusive)

Durum tespiti ctypes ile (powershell yok) → 3sn poll bedava, menü anında açılır.
Mod geçişleri sihirli singleShot gecikmeleri yerine KOŞUL-BAZLI poll ile yapılır.
"""
import os

from PySide6.QtCore import QRect, Qt, QTimer
from PySide6.QtGui import QAction, QActionGroup, QBrush, QColor, QFont, QIcon, QPainter, QPen, QPixmap
from PySide6.QtWidgets import QApplication, QInputDialog, QMenu, QSystemTrayIcon

from . import state, win
from .paths import BLACKLIST_PATH

TRAY_REF = None  # win.notify fallback'ı için

_T_LABEL = {"http2": "HTTP/2", "http3": "HTTP/3"}
_S_LABEL = {"selective": "Sadece blacklist", "full": "Her şey"}

ICON_SIZE = 64


def make_icon(connected: bool) -> QIcon:
    pixmap = QPixmap(ICON_SIZE, ICON_SIZE)
    pixmap.fill(Qt.GlobalColor.transparent)
    p = QPainter(pixmap)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    color = QColor(76, 175, 80) if connected else QColor(158, 158, 158)
    margin = 6
    rect = QRect(margin, margin, ICON_SIZE - 2 * margin, ICON_SIZE - 2 * margin)
    if connected:
        p.setBrush(QBrush(color))
        p.setPen(Qt.PenStyle.NoPen)
        p.drawEllipse(rect)
        p.setPen(QPen(QColor(255, 255, 255)))
    else:
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.setPen(QPen(color, 4))
        p.drawEllipse(rect)
        p.setPen(QPen(color))
    font = QFont()
    font.setPointSize(28)
    font.setBold(True)
    p.setFont(font)
    p.drawText(QRect(0, 0, ICON_SIZE, ICON_SIZE), Qt.AlignmentFlag.AlignCenter, "W")
    p.end()
    return QIcon(pixmap)


class WarpTray:
    def __init__(self):
        global TRAY_REF
        self.app = QApplication.instance() or QApplication([])
        self.app.setQuitOnLastWindowClosed(False)

        self.icon_on = make_icon(True)
        self.icon_off = make_icon(False)

        # Tray'in seçili istediği (kullanıcı seçimi)
        d = state.read_desired()
        self._sel_transport = d["transport"]
        self._sel_scope = d["scope"]
        self._last_state: dict | None = None
        self._initialized = False

        self.tray = QSystemTrayIcon()
        TRAY_REF = self.tray
        self.tray.setIcon(self.icon_off)
        self.tray.activated.connect(self._on_click)

        self._build_menu()

        self.refresh()
        self.tray.setVisible(True)

        self.timer = QTimer()
        self.timer.timeout.connect(self.refresh)
        self.timer.start(3000)
        self.app.aboutToQuit.connect(self.emergency_cleanup)

    # ------------------------------------------------------------------ menu
    def _build_menu(self):
        self.menu = QMenu()

        self.disconnect_action = QAction("Disconnect")
        self.disconnect_action.triggered.connect(self.disconnect)
        self.menu.addAction(self.disconnect_action)
        self.menu.addSeparator()

        # Transport grubu
        hdr_t = self.menu.addAction("Transport")
        hdr_t.setEnabled(False)
        self.transport_group = QActionGroup(self.menu)
        self.transport_group.setExclusive(True)
        self.transport_actions = {}
        for t in ("http2", "http3"):
            a = QAction(_T_LABEL[t], self.menu)
            a.setCheckable(True)
            a.triggered.connect(lambda _=False, x=t: self.choose_transport(x))
            self.transport_group.addAction(a)
            self.menu.addAction(a)
            self.transport_actions[t] = a
        self.menu.addSeparator()

        # Routing scope grubu
        hdr_s = self.menu.addAction("Routing")
        hdr_s.setEnabled(False)
        self.scope_group = QActionGroup(self.menu)
        self.scope_group.setExclusive(True)
        self.scope_actions = {}
        for s in ("selective", "full"):
            a = QAction(_S_LABEL[s], self.menu)
            a.setCheckable(True)
            a.triggered.connect(lambda _=False, x=s: self.choose_scope(x))
            self.scope_group.addAction(a)
            self.menu.addAction(a)
            self.scope_actions[s] = a
        self.menu.addSeparator()

        self.blacklist_menu = QMenu("Blacklist")
        self.menu.addMenu(self.blacklist_menu)
        self.menu.addSeparator()

        quit_action = QAction("Çıkış")
        quit_action.triggered.connect(self.app.quit)
        self.menu.addAction(quit_action)

        self.tray.setContextMenu(self.menu)
        # Sadece UCUZ blacklist menüsü her açılışta yenilenir (powershell yok)
        self.menu.aboutToShow.connect(self.rebuild_blacklist_menu)
        self.rebuild_blacklist_menu()

    def rebuild_blacklist_menu(self):
        self.blacklist_menu.clear()
        count = state.blacklist_count()
        info = self.blacklist_menu.addAction(f"{count} domain kayıtlı")
        info.setEnabled(False)
        if self._sel_scope == "full":
            note = self.blacklist_menu.addAction("(full modda hepsi zaten WARP'tan)")
            note.setEnabled(False)
        self.blacklist_menu.addSeparator()
        self.blacklist_menu.addAction("Düzenle…").triggered.connect(self.open_blacklist)
        self.blacklist_menu.addAction("Domain ekle…").triggered.connect(self.prompt_add_domain)
        self.blacklist_menu.addAction("DNS yenile").triggered.connect(self.reload_dns)

    # ------------------------------------------------------------------ events
    def _on_click(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            if state.current_state() is None:
                self.set_target(self._sel_transport, self._sel_scope)
            else:
                self.disconnect()

    def choose_transport(self, t: str):
        self._sel_transport = t
        state.write_desired(self._sel_transport, self._sel_scope)
        if state.current_state() is not None:
            self.set_target(t, self._sel_scope)

    def choose_scope(self, s: str):
        self._sel_scope = s
        state.write_desired(self._sel_transport, self._sel_scope)
        self.rebuild_blacklist_menu()
        if state.current_state() is not None:
            self.set_target(self._sel_transport, s)

    # ------------------------------------------------------------------ control
    def set_target(self, transport: str, scope: str):
        """İstenen moda geç (koşul-bazlı; sihirli gecikme yok)."""
        state.write_desired(transport, scope)
        cur = state.current_state()
        if cur is None:
            win.run_script("warp-on.ps1")
            self._watch(lambda: state.current_state() is not None)
        elif (cur["transport"], cur["scope"]) != (transport, scope):
            # Mod değişimi: önce kapat, kapandığını gör, sonra aç
            win.run_script("warp-off.ps1")
            self._after_off_then_on()
        win.notify("WARP", f"{_T_LABEL[transport]} · {_S_LABEL[scope]} açılıyor…")

    def disconnect(self):
        win.run_script("warp-off.ps1")
        self._watch(lambda: state.current_state() is None)

    def _after_off_then_on(self, attempts: int = 0):
        if state.current_state() is None:
            win.run_script("warp-on.ps1")
            self._watch(lambda: state.current_state() is not None)
        elif attempts < 25:
            QTimer.singleShot(400, lambda: self._after_off_then_on(attempts + 1))
        # değilse vazgeç; refresh gerçek durumu gösterir

    def _watch(self, cond, attempts: int = 0):
        """Koşul gerçekleşene dek (~10sn) poll'la, her adımda ikonu güncelle."""
        self.refresh()
        if cond() or attempts >= 25:
            self.refresh()
            return
        QTimer.singleShot(400, lambda: self._watch(cond, attempts + 1))

    # ------------------------------------------------------------------ blacklist
    def open_blacklist(self):
        BLACKLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
        BLACKLIST_PATH.touch(exist_ok=True)
        os.startfile(str(BLACKLIST_PATH))

    def prompt_add_domain(self):
        domain, ok = QInputDialog.getText(None, "Blacklist — Domain ekle", "Domain:")
        if not ok:
            return
        if state.add_domain(domain):
            win.notify("Blacklist", f"{domain.strip()} eklendi. 'DNS yenile' ile aktif et.")
        else:
            win.notify("Blacklist", "Eklenmedi (boş veya zaten mevcut).")
        self.rebuild_blacklist_menu()

    def reload_dns(self):
        if state.current_state() is None:
            win.notify("WARP Blacklist", "Önce WARP'ı aç.")
            return
        win.run_script("warp-dns-reload.ps1")
        win.notify("WARP Blacklist", "DNS yenileniyor…")

    # ------------------------------------------------------------------ poll
    def refresh(self):
        st = state.current_state()
        active = st is not None
        self.tray.setIcon(self.icon_on if active else self.icon_off)

        if active:
            self.tray.setToolTip(
                f"WARP: Connected ({_T_LABEL[st['transport']]} · {_S_LABEL[st['scope']]})"
            )
        else:
            self.tray.setToolTip("WARP: Disconnected")
        self.disconnect_action.setEnabled(active)

        # Checkmark: bağlıysa gerçek durum, değilse seçili istek
        shown_t = st["transport"] if active else self._sel_transport
        shown_s = st["scope"] if active else self._sel_scope
        for t, a in self.transport_actions.items():
            a.setChecked(t == shown_t)
        for s, a in self.scope_actions.items():
            a.setChecked(s == shown_s)

        if self._initialized and st != self._last_state:
            if active:
                win.notify("WARP", f"Connected ({_T_LABEL[st['transport']]} · {_S_LABEL[st['scope']]})")
            else:
                win.notify("WARP", "Disconnected")
        self._last_state = st
        self._initialized = True

    def emergency_cleanup(self):
        """Kapanırken WARP açıksa SENKRON kapat ki DNS/route teardown tamamlansın.

        Tray elevated olduğundan warp-off.ps1 doğrudan admin olarak koşar;
        wait=True ile bitmesini bekleriz (fire-and-forget'te yarıda kalmaz)."""
        if state.current_state() is None:
            return
        try:
            win.run_script("warp-off.ps1", wait=True, timeout=20)
        except Exception:
            win.run_script("warp-off.ps1")

    def run(self):
        import sys
        sys.exit(self.app.exec())
