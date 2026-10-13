$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$BadgeZig = Join-Path $BadgeRepoRoot ('.tools/zig/' + $BadgePins.zig.version + '/zig-relsafe-x86_64-windows-baseline/zig.exe')
if (-not (Test-Path -LiteralPath $BadgeZig)) {
    throw 'Pinned Zig is missing. Run .\scripts\idf.ps1 build first.'
}
$actual = & $BadgeZig version
if ($LASTEXITCODE -ne 0 -or $actual -ne $BadgePins.zig.version) {
    throw 'Zig compiler differs from dependencies.json.'
}
& $BadgeZig @args
exit $LASTEXITCODE
