"""Sistem tepsisi arayüzü.

İki bağımsız seçici:
  Transport: HTTP/2 · HTTP/3   (exclusive)
  Routing:   Sadece blacklist · Her şey  (exclusive)

Durum tespiti ctypes ile (powershell yok) → 3sn poll bedava, menü anında açılır.
Mod geçişleri sihirli singleShot gecikmeleri yerine KOŞUL-BAZLI poll ile yapılır.
"""
import os
import sys
from pathlib import Path

from PySide6.QtCore import QRect, Qt, QTimer
from PySide6.QtGui import QAction, QActionGroup, QBrush, QColor, QFont, QIcon, QPainter, QPen, QPixmap
from PySide6.QtWidgets import QApplication, QInputDialog, QMenu, QSystemTrayIcon

from . import state, win
from .paths import BLACKLIST_PATH, APP_NAME

TRAY_REF = None  # win.notify fallback'ı için

_T_LABEL = {"http2": "HTTP/2", "http3": "HTTP/3"}
_S_LABEL = {"selective": "Sadece blacklist", "full": "Her şey"}

ICON_SIZE = 64
_GREEN = QColor(76, 175, 80)
_GRAY = QColor(158, 158, 158)


def _asset(name: str) -> Path:
    """Bundle (PyInstaller _MEIPASS) veya repo'daki assets/."""
    base = getattr(sys, "_MEIPASS", str(Path(__file__).resolve().parent.parent))
    return Path(base) / "assets" / name


_WOLF = None


def _wolf_base() -> QPixmap:
    global _WOLF
    if _WOLF is None:
        p = _asset("AsenaPlug.png")
        _WOLF = QPixmap(str(p)) if p.exists() else QPixmap()
    return _WOLF


def make_icon(connected: bool) -> QIcon:
    """Asena kurt logosu + sağ altta durum noktası (yeşil=bağlı, gri=değil).
    Bağlı değilken kurt soluk gösterilir. Logo yoksa 'W' fallback'ı çizilir."""
    base = _wolf_base()
    if base.isNull():
        return _make_icon_fallback(connected)

    canvas = QPixmap(ICON_SIZE, ICON_SIZE)
    canvas.fill(Qt.GlobalColor.transparent)
    p = QPainter(canvas)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
    wolf = base.scaled(ICON_SIZE, ICON_SIZE, Qt.AspectRatioMode.KeepAspectRatio,
                       Qt.TransformationMode.SmoothTransformation)
    p.setOpacity(1.0 if connected else 0.45)  # kapalıyken soluk
    p.drawPixmap((ICON_SIZE - wolf.width()) // 2, (ICON_SIZE - wolf.height()) // 2, wolf)
    p.setOpacity(1.0)
    d = ICON_SIZE * 5 // 16  # durum noktası ~20px, sağ alt
    p.setPen(QPen(QColor(255, 255, 255), 2))
    p.setBrush(QBrush(_GREEN if connected else _GRAY))
    p.drawEllipse(QRect(ICON_SIZE - d - 1, ICON_SIZE - d - 1, d, d))
    p.end()
    return QIcon(canvas)


def _make_icon_fallback(connected: bool) -> QIcon:
    pixmap = QPixmap(ICON_SIZE, ICON_SIZE)
    pixmap.fill(Qt.GlobalColor.transparent)
    p = QPainter(pixmap)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    color = _GREEN if connected else _GRAY
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

        _wp = _asset("AsenaPlug.png")  # dialog/taskbar ikonu
        if _wp.exists():
            self.app.setWindowIcon(QIcon(str(_wp)))

        self.icon_on = make_icon(True)
        self.icon_off = make_icon(False)

        # Tray'in seçili istediği (kullanıcı seçimi)
        d = state.read_desired()
        self._sel_transport = d["transport"]
        self._sel_scope = d["scope"]
        self._last_state: dict | None = None
        self._pending: tuple[str, str] | None = None
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

        # Connect/Disconnect — duruma göre metni değişen, HER ZAMAN tıklanabilir
        self.toggle_action = QAction("Connect")
        self.toggle_action.triggered.connect(self.toggle)
        self.menu.addAction(self.toggle_action)

        # Durum satırı (bilgi amaçlı, tıklanamaz)
        self.status_action = QAction("Durum: Bağlı değil")
        self.status_action.setEnabled(False)
        self.menu.addAction(self.status_action)
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

        # parent=self.menu + self.* referansı: QAction GC'ye gidip menüden DÜŞMESİN
        self.quit_action = QAction("Çıkış", self.menu)
        self.quit_action.triggered.connect(self.app.quit)
        self.menu.addAction(self.quit_action)

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
    def toggle(self):
        """Bağlı değilse bağlan (seçili mod), bağlıysa kes."""
        if state.current_state() is None:
            self.set_target(self._sel_transport, self._sel_scope)
        else:
            self.disconnect()

    def _on_click(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.toggle()

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
        """İstenen moda geç. transport/scope warp-on'a ARGÜMAN olarak geçer
        (desired.json round-trip'ine güvenmez). Ayar-değişimi bildirimi YOK;
        sadece refresh() gerçek connect/disconnect'i bildirir."""
        state.write_desired(transport, scope)          # kalıcılık (boot/route-sync)
        self._pending = (transport, scope)
        cur = state.current_state()
        if cur is None:
            self._start(transport, scope)
        elif (cur["transport"], cur["scope"]) != (transport, scope):
            # Mod değişimi: önce kapat, kapandığını gör, sonra hedefle aç
            win.run_script("warp-off.ps1")
            self._after_off_then_on()

    def _start(self, transport: str, scope: str):
        win.run_script("warp-on.ps1", args=["-Transport", transport, "-Scope", scope])
        self._watch(lambda: state.current_state() is not None)

    def disconnect(self):
        win.run_script("warp-off.ps1")
        self._watch(lambda: state.current_state() is None)

    def _after_off_then_on(self, attempts: int = 0):
        if state.current_state() is None:
            t, s = self._pending or (self._sel_transport, self._sel_scope)
            self._start(t, s)
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
            win.notify(f"{APP_NAME} Blacklist", f"Önce {APP_NAME}'ı aç.")
            return
        win.run_script("warp-dns-reload.ps1")
        win.notify(f"{APP_NAME} Blacklist", "DNS yenileniyor…")

    # ------------------------------------------------------------------ poll
    def refresh(self):
        st = state.current_state()
        active = st is not None
        self.tray.setIcon(self.icon_on if active else self.icon_off)

        if active:
            detail = f"{_T_LABEL[st['transport']]} · {_S_LABEL[st['scope']]}"
            self.tray.setToolTip(f"{APP_NAME}: Connected ({detail})")
            self.toggle_action.setText("Disconnect")
            self.status_action.setText(f"Durum: Bağlı — {detail}")
        else:
            self.tray.setToolTip(f"{APP_NAME}: Disconnected")
            self.toggle_action.setText("Connect")
            self.status_action.setText("Durum: Bağlı değil")

        # Checkmark: bağlıysa gerçek durum, değilse seçili istek
        shown_t = st["transport"] if active else self._sel_transport
        shown_s = st["scope"] if active else self._sel_scope
        for t, a in self.transport_actions.items():
            a.setChecked(t == shown_t)
        for s, a in self.scope_actions.items():
            a.setChecked(s == shown_s)

        if self._initialized and st != self._last_state:
            if active:
                win.notify(APP_NAME, f"Connected ({_T_LABEL[st['transport']]} · {_S_LABEL[st['scope']]})")
            else:
                win.notify(APP_NAME, "Disconnected")
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
