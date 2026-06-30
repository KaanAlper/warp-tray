"""asena Windows portu — modüler paket.

Sorumluluk ayrımı:
  paths   — tüm yol sabitleri + Task Scheduler görev adları (tek kaynak)
  win     — Windows'a özgü düşük seviye (admin, schtasks, ctypes adapter, bildirim)
  state   — durum tek doğru kaynağı (state.json/desired.json) + blacklist r/w
  install — ilk kurulum (binary kopya, task kaydı, ACL, usque register, startup)
  tray    — sistem tepsisi arayüzü (transport + scope seçici)
"""
