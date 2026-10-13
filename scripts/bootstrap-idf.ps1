$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
New-Item -ItemType Directory -Path (Join-Path $BadgeRepoRoot '.tools') -Force | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $BadgeIdfCheckout '.git'))) {
    & git -c core.longpaths=true clone --depth 1 --branch $BadgePins.esp_idf.ref --recursive --shallow-submodules --jobs 8 $BadgePins.esp_idf.repository $BadgeIdfCheckout
    if ($LASTEXITCODE -ne 0) { throw 'ESP-IDF clone failed; rerun to resume submodule setup.' }
} else {
    Confirm-BadgeIdfCheckout
    & git -c core.longpaths=true -C $BadgeIdfCheckout submodule update --init --recursive --depth 1 --jobs 8
    if ($LASTEXITCODE -ne 0) { throw 'ESP-IDF submodule setup failed.' }
}
Confirm-BadgeIdfCheckout
& $BadgeBasePython (Join-Path $BadgeIdfCheckout 'tools/idf_tools.py') --idf-path $BadgeIdfCheckout install --targets=esp32s3 required cmake ninja
if ($LASTEXITCODE -ne 0) { throw 'ESP-IDF tool installation failed.' }
& $BadgeBasePython (Join-Path $BadgeIdfCheckout 'tools/idf_tools.py') --idf-path $BadgeIdfCheckout install-python-env
if ($LASTEXITCODE -ne 0) { throw 'ESP-IDF Python environment installation failed.' }
Write-Output 'Ready. Run .\scripts\idf.ps1 build to fetch the pinned Zig compiler and build firmware.'
