<#
.SYNOPSIS
    warp-tray.exe üret (PyInstaller, tek dosya, konsolsuz).

.DESCRIPTION
    Uygun bir CPython yorumlayıcısı otomatik seçilir (PyPy reddedilir — PySide6/
    PyInstaller PyPy'de çalışmaz). Bağımlılıklar SEÇİLEN yorumlayıcıya kurulur
    (python/pip uyuşmazlığı böyle elenir). Build başarısızsa script hata verir.

.PARAMETER Python
    Kullanılacak Python'u elle belirt. Örn:
      .\build.ps1 -Python "$env:USERPROFILE\anaconda3\python.exe"

.PARAMETER NoInstall
    requirements.txt kurulumunu atla (zaten kuruluysa).

.NOTES
    Çıktı: dist\warp-tray.exe
#>
param(
    [string]$Python = "",
    [switch]$NoInstall
)
Set-StrictMode -Version 1.0
$ErrorActionPreference = "Stop"

function Test-CPython([string]$exe, [string[]]$pre) {
    try {
        $out = & $exe @pre -c "import sys;print(sys.implementation.name)" 2>$null
        if ($LASTEXITCODE -eq 0 -and "$out".Trim() -eq "cpython") { return $true }
    } catch {}
    return $false
}

Push-Location $PSScriptRoot
try {
    foreach ($f in @("bundled\usque.exe", "bundled\wintun.dll", "bundled\dnsproxy.exe")) {
        if (-not (Test-Path $f)) { throw "Eksik bundle dosyası: $f" }
    }
    if (-not (Test-Path "requirements.txt")) { throw "requirements.txt yok." }

    # --- Uygun CPython seç (PyPy DEĞİL) ---
    $candidates = @()
    if ($Python) { $candidates += ,@($Python, @()) }
    $candidates += ,@("py", @("-3"))
    $candidates += ,@("python", @())
    $candidates += ,@("$env:USERPROFILE\anaconda3\python.exe", @())

    $pyExe = $null; $pyPre = @()
    foreach ($c in $candidates) {
        if (Test-CPython $c[0] $c[1]) { $pyExe = $c[0]; $pyPre = $c[1]; break }
    }
    if (-not $pyExe) {
        throw ("Uygun CPython bulunamadı (PyPy kabul edilmez).`n" +
               "CPython 3.10+ kur (python.org) veya elle belirt:`n" +
               "  .\build.ps1 -Python C:\path\to\python.exe")
    }
    $ver = (& $pyExe @pyPre -c "import sys;print('.'.join(map(str,sys.version_info[:3])))").Trim()
    Write-Host "Python: $pyExe $($pyPre -join ' ')  [CPython $ver]" -ForegroundColor Cyan

    # --- Bağımlılıklar (SEÇİLEN yorumlayıcıya) ---
    if (-not $NoInstall) {
        Write-Host "Bağımlılıklar kuruluyor (requirements.txt)..." -ForegroundColor Cyan
        & $pyExe @pyPre -m pip install -r requirements.txt
        if ($LASTEXITCODE -ne 0) { throw "pip install başarısız (exit $LASTEXITCODE)" }
    }

    # --- Build ---
    Write-Host "PyInstaller çalışıyor..." -ForegroundColor Cyan
    & $pyExe @pyPre -m PyInstaller --noconfirm --clean --onefile --windowed `
        --name AsenaPlug `
        --icon "assets\AsenaPlug.ico" `
        --paths . `
        --add-data "bundled;bundled" `
        --add-data "scripts;scripts" `
        --add-data "assets;assets" `
        --hidden-import warp_tray `
        --hidden-import warp_tray.paths `
        --hidden-import warp_tray.win `
        --hidden-import warp_tray.state `
        --hidden-import warp_tray.install `
        --hidden-import warp_tray.tray `
        --hidden-import winotify `
        "AsenaPlug.pyw"
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller başarısız (exit $LASTEXITCODE)" }

    Write-Host "`nTamam -> dist\AsenaPlug.exe" -ForegroundColor Green
}
finally {
    Pop-Location
}
