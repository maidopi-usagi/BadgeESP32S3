$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
if (-not (Test-Path -LiteralPath (Join-Path $BadgeIdfCheckout 'export.ps1')) -or
    -not (Test-Path -LiteralPath (Join-Path $BadgePythonEnv 'Scripts/python.exe'))) {
    throw 'ESP-IDF is missing. Run .\scripts\bootstrap-idf.ps1 first.'
}
Confirm-BadgeIdfCheckout
$env:IDF_PYTHON_ENV_PATH = $BadgePythonEnv
. (Join-Path $BadgeIdfCheckout 'export.ps1')
if (-not $env:IDF_PATH -or $env:IDF_PATH -ne $BadgeIdfCheckout) {
    throw 'ESP-IDF environment activation failed.'
}
& (Join-Path $BadgePythonEnv 'Scripts/python.exe') (Join-Path $BadgeIdfCheckout 'tools/idf.py') @args
exit $LASTEXITCODE
