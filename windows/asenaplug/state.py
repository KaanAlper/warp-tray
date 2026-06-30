"""Durum tek doğru kaynağı + blacklist okuma/yazma.

İki bağımsız eksen:
  transport: http2 | http3   (taşıma katmanı)
  scope:     selective | full (routing kapsamı)

  desired.json — tray'in İSTEDİĞİ (tray yazar, asena-on.ps1 okur)
  state.json   — GERÇEKTE çalışan durum (asena-on.ps1 yazar, asena-off.ps1 siler)

Tray "Asena açık mı + hangi modda?" sorusunu `current_state()` ile yanıtlar:
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
    # utf-8-sig: PowerShell Set-Content -Encoding UTF8 BOM ekler; BOM'u at
    try:
        d = json.loads(DESIRED_FILE.read_text(encoding="utf-8-sig"))
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
    # utf-8-sig ŞART: asena-on.ps1 (PowerShell 5.1) state.json'ı BOM'lu yazar;
    # düz utf-8 ile json.loads BOM'da patlar -> hep None -> tray hep "disconnected".
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8-sig"))
    except Exception:
        return None


def current_state() -> dict | None:
    """Asena gerçekten açık mı? Açıksa {transport, scope}, değilse None.

    state.json TEK doğru kaynaktır (asena-on adapter geldikten SONRA yazar,
    asena-off siler). state.json yoksa -> bağlı değil (None). ÖNEMLİ: adapter
    ayakta ama state.json yokken (off->on teardown anı) sahte 'http2' DÖNDÜRMEZ
    — yoksa mod değişiminde tray kısa süre http2 gösterip yanıltıyordu.
    """
    st = read_state()
    if not st:
        return None
    from . import win
    if not win.adapter_exists(TUN_NAME):
        return None
    t, s = _coerce(st.get("transport"), st.get("scope"))
    return {"transport": t, "scope": s}


# --- blacklist ---
def normalize_domain(line: str) -> str | None:
    """Bir satırı normalize et: yorum at, '*.'/baş-son nokta temizle, küçült.
    Boş/yorum satırı için None döner."""
    line = line.split("#", 1)[0].strip()
    if not line:
        return None
    if line.startswith("*."):
        line = line[2:]
    line = line.split("/", 1)[0].split(":", 1)[0]  # yol/port sıyır (ör. site.com:443)
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
        return parse_blacklist(BLACKLIST_PATH.read_text(encoding="utf-8-sig"))
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
