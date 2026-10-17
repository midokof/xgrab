<#
  Installe l'extension XGrab dans tous les navigateurs detectes sur ce poste.

  Chrome et ses derivés (Edge, Brave, Opera, Vivaldi) exigent un chargement
  manuel en mode developpeur. Firefox accepte l'extension via about:debugging.
  Le script detecte les navigateurs, copie l'extension dans un dossier stable
  et affiche les gestes exacts pour chacun.

  Utilisation : powershell -ExecutionPolicy Bypass -File .\install_extension.ps1
#>

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Source = Join-Path $Root 'extension'
$Target = Join-Path $env:LOCALAPPDATA 'XGrab\extension'

if (-not (Test-Path -LiteralPath $Source)) {
    Write-Host "Extension introuvable : $Source" -ForegroundColor Red
    exit 1
}

# --- copie dans un dossier stable -------------------------------------------
# config.json contient le port et le jeton ecrits par XGrab en cours : il doit
# survivre a la reinstall, sinon l'extension repart avec un jeton perime.

$liveConfig = Join-Path $Target 'config.json'
$keptConfig = $null
if (Test-Path -LiteralPath $liveConfig) {
    $keptConfig = Get-Content -LiteralPath $liveConfig -Raw
}

if (Test-Path -LiteralPath $Target) {
    Remove-Item -LiteralPath $Target -Recurse -Force
}
New-Item -ItemType Directory -Path $Target -Force | Out-Null
Copy-Item -Path (Join-Path $Source '*') -Destination $Target -Recurse -Force

if ($keptConfig) {
    Set-Content -LiteralPath $liveConfig -Value $keptConfig -Encoding UTF8
    Write-Host 'config.json vivant conserve (port et jeton preserves)' -ForegroundColor DarkGray
}
Write-Host "Extension copiee dans $Target" -ForegroundColor Green
# --- detection des navigateurs ------------------------------------------------

$candidates = @(
    @{ Name = 'Chrome';     Path = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe";                     Alt = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe" }
    @{ Name = 'Edge';       Path = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe";                    Alt = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe" }
    @{ Name = 'Brave';      Path = "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe";         Alt = "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe" }
    @{ Name = 'Opera';      Path = "$env:LOCALAPPDATA\Programs\Opera\opera.exe";                                 Alt = "$env:ProgramFiles\Opera\opera.exe" }
    @{ Name = 'Vivaldi';    Path = "$env:LOCALAPPDATA\Vivaldi\Application\vivaldi.exe";                          Alt = "$env:ProgramFiles\Vivaldi\Application\vivaldi.exe" }
    @{ Name = 'Firefox';    Path = "$env:ProgramFiles\Mozilla Firefox\firefox.exe";                             Alt = "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe" }
)

$found = @()
foreach ($app in $candidates) {
    if ((Test-Path -LiteralPath $app.Path) -or (Test-Path -LiteralPath $app.Alt)) {
        $found += $app.Name
    }
}

# --- hote natif : permet a l'extension de lancer XGrab ----------------------
#
# Une extension est bac a sable : elle ne peut pas demarrer un processus. Le
# navigateur sait le faire via "native messaging", a condition qu'un manifeste
# declare l'executable et qu'une cle de registre pointe dessus.

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Exe = Join-Path $Root 'dist\XGrab\XGrab.exe'
$HostDir = Join-Path $env:LOCALAPPDATA 'XGrab'
$HostName = 'com.xgrab.app'

function Get-ExtensionId([string]$manifestPath) {
    # Avec une cle "key" dans le manifest, Chromium ignore completement le chemin
    # de chargement : l'identifiant devient le meme partout et sur toute machine.
    # C'est ce qu'on utilise ici, parce que le calcul par chemin est fragile
    # (casse, encodage, sous-dossier) et ne correspondait pas au vrai Edge.
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manifest.key) {
        throw "manifest.json sans cle 'key' : impossible de determiner l'identifiant de l'extension"
    }
    $der = [System.Convert]::FromBase64String([string]$manifest.key)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($der)
    $id = ''
    for ($i = 0; $i -lt 16; $i++) {
        $b = $hash[$i]
        $id += [char](97 + ($b -shr 4))
        $id += [char](97 + ($b -band 15))
    }
    return $id
}

$extId = Get-ExtensionId (Join-Path $Target 'manifest.json')
$chromiumManifest = Join-Path $HostDir 'native-host.json'
$firefoxManifest = Join-Path $HostDir 'native-host-firefox.json'

if (Test-Path -LiteralPath $Exe) {
    New-Item -ItemType Directory -Path $HostDir -Force | Out-Null

    # PowerShell 5.1 ecrit un BOM avec -Encoding UTF8 ; Chrome refuse de lire
    # un manifeste JSON qui en contient un.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $hostSpec = [ordered]@{
        name             = $HostName
        description      = 'XGrab - telechargement video'
        path             = $Exe
        type             = 'stdio'
        allowed_origins  = @("chrome-extension://$extId/")
    }
    [System.IO.File]::WriteAllText(
        $chromiumManifest,
        ($hostSpec | ConvertTo-Json -Depth 4),
        $utf8NoBom)

    $ffSpec = [ordered]@{
        name                = $HostName
        description         = 'XGrab - telechargement video'
        path                = $Exe
        type                = 'stdio'
        allowed_extensions = @('xgrab@local')
    }
    [System.IO.File]::WriteAllText(
        $firefoxManifest,
        ($ffSpec | ConvertTo-Json -Depth 4),
        $utf8NoBom)

    Write-Host "ID extension  : $extId" -ForegroundColor DarkGray
    Write-Host "Hote natif     : $chromiumManifest" -ForegroundColor Green

    $keys = @(
        @{ Path = "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$HostName"; Manifest = $chromiumManifest }
        @{ Path = "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\$HostName"; Manifest = $chromiumManifest }
        @{ Path = "HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\$HostName"; Manifest = $chromiumManifest }
        @{ Path = "HKCU:\Software\Opera Software\Opera Stable\NativeMessagingHosts\$HostName"; Manifest = $chromiumManifest }
        @{ Path = "HKCU:\Software\Vivaldi\NativeMessagingHosts\$HostName"; Manifest = $chromiumManifest }
        @{ Path = "HKCU:\Software\Mozilla\NativeMessagingHosts\$HostName"; Manifest = $firefoxManifest }
    )
    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key.Path)) {
            New-Item -Path $key.Path -Force | Out-Null
        }
        Set-Item -Path $key.Path -Value $key.Manifest
        Write-Host ("  enregistre : " + ($key.Path -replace '^.*?NativeMessagingHosts', 'NativeMessagingHosts')) -ForegroundColor DarkGray
    }
} else {
    Write-Host "Exe introuvable : $Exe" -ForegroundColor Red
    Write-Host "Lancement automatique indisponible, le reste fonctionne." -ForegroundColor Yellow
}

Write-Host ''
if ($found.Count -eq 0) {
    Write-Host 'Aucun navigateur connu detecte.' -ForegroundColor Yellow
    Write-Host "Chargez manuellement le dossier : $Target"
    exit 0
}

Write-Host ("Navigateurs detectes : " + ($found -join ', ')) -ForegroundColor Cyan
Write-Host ''

# --- verification du port du serveur -----------------------------------------

$port = 0
$config = Join-Path $Target 'config.json'
if (Test-Path -LiteralPath $config) {
    try {
        $port = (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).port
    } catch { $port = 0 }
}

if ($port -gt 0) {
    $alive = $false
    try {
        $ping = Invoke-RestMethod -Uri "http://127.0.0.1:$port/ping" -TimeoutSec 2
        $alive = $ping.ok
    } catch { $alive = $false }

    if ($alive) {
        Write-Host "XGrab repond sur le port $port - le bouton apparaitra sur les videos." -ForegroundColor Green
    } else {
        Write-Host "Port $port configure mais XGrab ne repond pas : lancez XGrab puis rechargez l'extension." -ForegroundColor Yellow
    }
} else {
    Write-Host 'Aucun config.json : lancez XGrab une fois pour generer le port et le jeton.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Chargement manuel, une seule fois par navigateur :' -ForegroundColor White
Write-Host ''
Write-Host '  Chrome, Edge, Brave, Opera, Vivaldi :'
Write-Host '    1. ouvrir chrome://extensions (ou edge://extensions, brave://extensions,'
Write-Host '       opera://extensions, vivaldi://extensions)'
Write-Host '    2. activer "Mode developpeur"'
Write-Host '    3. "Charger l''extension non empaquetee" -> choisir le dossier ci-dessus'
Write-Host "       $Target"
Write-Host ''
Write-Host '  Firefox :'
Write-Host '    1. ouvrir about:debugging#/runtime/this-firefox'
Write-Host '    2. "Charger un module temporaire..." -> choisir manifest.json dans'
Write-Host "       $Target"
Write-Host ''
Write-Host 'Apres installation : redemarrer XGrab, puis recharger les pages video.' -ForegroundColor Cyan
