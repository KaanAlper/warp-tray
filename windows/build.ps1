<#
.SYNOPSIS
    warp-tray.exe üret (PyInstaller, tek dosya, konsolsuz).
    Gömülü binary'ler (bundled/) ve scriptler (scripts/) exe'ye eklenir.

.NOTES
    Gereksinim:  pip install pyinstaller PySide6 winotify
    Çıktı:       dist\warp-tray.exe
#>
Set-StrictMode -Version 1.0
$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot
try {
    foreach ($f in @("bundled\usque.exe", "bundled\wintun.dll", "bundled\dnsproxy.exe")) {
        if (-not (Test-Path $f)) { throw "Eksik bundle dosyası: $f" }
    }

    python -m PyInstaller --noconfirm --clean --onefile --windowed `
        --name warp-tray `
        --paths . `
        --add-data "bundled;bundled" `
        --add-data "scripts;scripts" `
        --hidden-import warp_tray `
        --hidden-import warp_tray.paths `
        --hidden-import warp_tray.win `
        --hidden-import warp_tray.state `
        --hidden-import warp_tray.install `
        --hidden-import warp_tray.tray `
        --hidden-import winotify `
        "warp-tray.pyw"

    Write-Host "`nTamam -> dist\warp-tray.exe" -ForegroundColor Green
}
finally {
    Pop-Location
}
