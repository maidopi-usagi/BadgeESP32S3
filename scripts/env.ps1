$BadgeRepoRoot = Split-Path $PSScriptRoot -Parent
Set-Location -LiteralPath $BadgeRepoRoot
$BadgePins = Get-Content -LiteralPath (Join-Path $BadgeRepoRoot 'dependencies.json') -Raw | ConvertFrom-Json
$BadgeIdfCheckout = if ($env:ESP32_IDF_PATH) { $env:ESP32_IDF_PATH } else {
    Join-Path $BadgeRepoRoot ('.tools/esp-idf-v' + $BadgePins.esp_idf.version)
}
if (-not $env:IDF_TOOLS_PATH) {
    $env:IDF_TOOLS_PATH = Join-Path $BadgeRepoRoot '.tools/idf-tools'
}
$env:IDF_TARGET = 'esp32s3'
$env:PYTHONNOUSERSITE = '1'

$BadgeBasePython = $env:BADGE_PYTHON
if (-not $BadgeBasePython -and (Get-Command py -ErrorAction SilentlyContinue)) {
    try {
        $BadgeBasePython = & py -3.12 -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -ne 0) { $BadgeBasePython = $null }
    } catch { $BadgeBasePython = $null }
}
if (-not $BadgeBasePython) {
    $BadgeBasePython = (Get-Command python -ErrorAction Stop).Source
}
$BadgePythonVersion = & $BadgeBasePython -c 'import sys; print(sys.version_info.major, sys.version_info.minor, sep=chr(46))'
if ($LASTEXITCODE -ne 0 -or [version]$BadgePythonVersion -lt [version]'3.10' -or [version]$BadgePythonVersion -ge [version]'3.14') {
    throw 'Use Python 3.10-3.13 (3.12 recommended); set BADGE_PYTHON to its python.exe if needed.'
}
$BadgeIdfMajorMinor = ($BadgePins.esp_idf.version.Split('.')[0..1] -join '.')
$BadgePythonEnv = Join-Path $env:IDF_TOOLS_PATH ('python_env/idf' + $BadgeIdfMajorMinor + '_py' + $BadgePythonVersion + '_env')
$BadgePython = Join-Path $BadgePythonEnv 'Scripts/python.exe'
if (-not (Test-Path -LiteralPath $BadgePython)) { $BadgePython = $BadgeBasePython }
$env:PATH = (Split-Path $BadgePython) + ';' + (Split-Path $BadgeBasePython) + ';' + $env:PATH

function Confirm-BadgeIdfCheckout {
    $actual = & git -C $BadgeIdfCheckout rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $actual -ne $BadgePins.esp_idf.commit) {
        throw "ESP-IDF commit mismatch: $actual; expected $($BadgePins.esp_idf.commit)"
    }
}
