param(
    [switch]$Isolated
)

$ErrorActionPreference = "Stop"
$root = $PWD.Path

if ($Isolated) {
    $venv = Join-Path $root ".venv-build"
    if (-not (Test-Path (Join-Path $venv "Scripts\python.exe"))) {
        Write-Host "[0/5] Creation du venv de build..."
        python -m venv $venv
    }
    $python = Join-Path $venv "Scripts\python.exe"
} else {
    $python = (Get-Command python).Source
}

Write-Host "[1/5] Python : $python"
& $python -m pip install --quiet --upgrade pip pyinstaller requests imageio-ffmpeg yt-dlp websocket-client
if ($LASTEXITCODE -ne 0) { throw "Installation des dependances echouee" }

$dist = Join-Path $root "dist\XGrab"
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }

Get-ChildItem -Path $root -Filter "__pycache__" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike "*\.venv-build\*" } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "[2/5] Compilation PyInstaller..."
& $python -m PyInstaller --noconfirm --clean xgrab.spec
if ($LASTEXITCODE -ne 0) { throw "PyInstaller a echoue" }

Write-Host "[3/5] Copie de yt-dlp.exe..."
$scriptsDir = & $python -c "import sysconfig; print(sysconfig.get_path('scripts'))"
$ytDlp = Join-Path $scriptsDir "yt-dlp.exe"
if (-not (Test-Path $ytDlp)) { throw "yt-dlp.exe introuvable dans $scriptsDir" }
Copy-Item $ytDlp $dist -Force

Write-Host "[4/5] Verification du bundle..."
foreach ($needed in @("XGrab.exe", "yt-dlp.exe")) {
    if (-not (Test-Path (Join-Path $dist $needed))) { throw "Fichier manquant : $needed" }
}
$ffmpeg = Get-ChildItem -LiteralPath $dist -Recurse -File -Filter "ffmpeg*.exe" -ErrorAction SilentlyContinue
if (-not $ffmpeg) { Write-Host "[avertissement] ffmpeg absent du bundle" -ForegroundColor Yellow }

$total = (Get-ChildItem -LiteralPath $dist -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host ("[5/5] Termine - {0} Mo" -f [math]::Round($total / 1MB, 1))
Write-Host "Lancement : $dist\XGrab.exe"
