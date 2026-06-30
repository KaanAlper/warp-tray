"""state.py saf mantık testleri — Windows gerektirmez (Linux'ta da koşar).

Çalıştır:  cd windows && python -m pytest tests/   (veya python tests/test_state.py)
"""
from asenaplug import state
from asenaplug.paths import DEFAULT_TRANSPORT, DEFAULT_SCOPE


# --- normalize_domain ---
def test_normalize_basic():
    assert state.normalize_domain("Example.COM") == "example.com"


def test_normalize_strips_wildcard():
    assert state.normalize_domain("*.example.com") == "example.com"


def test_normalize_strips_trailing_dot():
    assert state.normalize_domain("example.com.") == "example.com"


def test_normalize_strips_comment():
    assert state.normalize_domain("foo.com # not  ") == "foo.com"


def test_normalize_blank_and_comment_lines():
    assert state.normalize_domain("") is None
    assert state.normalize_domain("   ") is None
    assert state.normalize_domain("# sadece yorum") is None


# --- parse_blacklist ---
def test_parse_dedup_and_order():
    text = "a.com\nB.com\na.com\n# yorum\n*.c.com\n\n"
    assert state.parse_blacklist(text) == ["a.com", "b.com", "c.com"]


def test_parse_empty():
    assert state.parse_blacklist("") == []
    assert state.parse_blacklist("# hepsi\n# yorum\n") == []


# --- desired coerce / defaults ---
def test_read_desired_defaults_when_missing():
    # Linux'ta DESIRED_FILE yok -> varsayılanlar
    d = state.read_desired()
    assert d == {"transport": DEFAULT_TRANSPORT, "scope": DEFAULT_SCOPE}


def test_coerce_invalid_falls_back():
    t, s = state._coerce("garbage", "garbage")
    assert t == DEFAULT_TRANSPORT and s == DEFAULT_SCOPE
    t, s = state._coerce("http3", "full")
    assert (t, s) == ("http3", "full")


def test_read_state_handles_powershell_bom():
    """Regresyon: asena-on.ps1 (PS 5.1) state.json'ı BOM'lu yazar; read_state
    utf-8-sig ile BOM'u atıp parse edebilmeli (yoksa hep None -> tray hep
    disconnected)."""
    import json as _json
    import os
    import tempfile
    from pathlib import Path
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    p = Path(path)
    old = state.STATE_FILE
    try:
        p.write_bytes(b"\xef\xbb\xbf" + _json.dumps(
            {"transport": "http3", "scope": "full"}).encode("utf-8"))
        state.STATE_FILE = p
        assert state.read_state() == {"transport": "http3", "scope": "full"}
    finally:
        state.STATE_FILE = old
        p.unlink()


if __name__ == "__main__":
    # pytest yoksa basit koşucu
    import traceback
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    fails = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS  {fn.__name__}")
        except Exception:
            fails += 1
            print(f"FAIL  {fn.__name__}")
            traceback.print_exc()
    print(f"\n{len(fns) - fails}/{len(fns)} passed")
    raise SystemExit(1 if fails else 0)
