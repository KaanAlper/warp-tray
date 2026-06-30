"""Durum tek doğru kaynağı + blacklist okuma/yazma.

İki bağımsız eksen:
  transport: http2 | http3   (taşıma katmanı)
  scope:     selective | full (routing kapsamı)

  desired.json — tray'in İSTEDİĞİ (tray yazar, warp-on.ps1 okur)
  state.json   — GERÇEKTE çalışan durum (warp-on.ps1 yazar, warp-off.ps1 siler)

Tray "WARP açık mı + hangi modda?" sorusunu `current_state()` ile yanıtlar:
adapter gerçekten ayakta MI + state.json ne diyor. Eski koddaki import edilmemiş
`psutil` + çıplak except (hep None → hep disconnected) hatası böyle çözülür.

normalize_domain / parse_blacklist saf fonksiyonlardır (Windows gerektirmez,
Linux'ta unit-test edilebilir).
"""
import json

from .paths import (
    BLACKLIST_PATH, DESIRED_FILE, STATE_FILE, TUN_NAME,
    DEFAULT_TRANSPORT, DEFAULT_SCOPE, TRANSPORTS, SCOPES,
)


# --- desired / state ---
def _coerce(transport, scope):
    t = transport if transport in TRANSPORTS else DEFAULT_TRANSPORT
    s = scope if scope in SCOPES else DEFAULT_SCOPE
    return t, s


def read_desired() -> dict:
    try:
        d = json.loads(DESIRED_FILE.read_text(encoding="utf-8"))
    except Exception:
        d = {}
    t, s = _coerce(d.get("transport"), d.get("scope"))
    return {"transport": t, "scope": s}


def write_desired(transport: str, scope: str):
    t, s = _coerce(transport, scope)
    DESIRED_FILE.parent.mkdir(parents=True, exist_ok=True)
    DESIRED_FILE.write_text(
        json.dumps({"transport": t, "scope": s}), encoding="utf-8"
    )


def read_state() -> dict | None:
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return None


def current_state() -> dict | None:
    """WARP gerçekten açık mı? Açıksa {transport, scope}, değilse None.

    Hem 'usque' adapteri ayakta olmalı (ctypes, anlık) hem state.json bulunmalı.
    Adapter var ama state.json yoksa (tutarsız durum) varsayılanları döndürür.
    """
    from . import win
    if not win.adapter_exists(TUN_NAME):
        return None
    st = read_state()
    if st:
        t, s = _coerce(st.get("transport"), st.get("scope"))
        return {"transport": t, "scope": s}
    return {"transport": DEFAULT_TRANSPORT, "scope": DEFAULT_SCOPE}


# --- blacklist ---
def normalize_domain(line: str) -> str | None:
    """Bir satırı normalize et: yorum at, '*.'/baş-son nokta temizle, küçült.
    Boş/yorum satırı için None döner."""
    line = line.split("#", 1)[0].strip()
    if not line:
        return None
    if line.startswith("*."):
        line = line[2:]
    line = line.strip().strip(".").lower()
    return line or None


def parse_blacklist(text: str) -> list[str]:
    """Metni domain listesine çevir (sıralı, tekrarsız)."""
    out: list[str] = []
    seen: set[str] = set()
    for raw in text.splitlines():
        d = normalize_domain(raw)
        if d and d not in seen:
            seen.add(d)
            out.append(d)
    return out


def read_blacklist() -> list[str]:
    try:
        return parse_blacklist(BLACKLIST_PATH.read_text(encoding="utf-8"))
    except Exception:
        return []


def blacklist_count() -> int:
    return len(read_blacklist())


def add_domain(domain: str) -> bool:
    """Domain'i blacklist'e ekle. Zaten varsa/boşsa False döner."""
    d = normalize_domain(domain)
    if not d or d in read_blacklist():
        return False
    BLACKLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
    prefix = ""
    if BLACKLIST_PATH.exists():
        cur = BLACKLIST_PATH.read_text(encoding="utf-8")
        if cur and not cur.endswith("\n"):
            prefix = "\n"
    with BLACKLIST_PATH.open("a", encoding="utf-8") as f:
        f.write(prefix + d + "\n")
    return True
