#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

case "$(uname -m)" in
    arm64|aarch64) zig_arch=aarch64 ;;
    x86_64|amd64) zig_arch=x86_64 ;;
    *) echo "Unsupported host architecture" >&2; exit 1 ;;
esac
case "$(uname -s)" in
    Darwin) zig_platform=macos ;;
    Linux) zig_platform=linux-musl ;;
    *) echo "Use the cached Zig compiler directly on this OS" >&2; exit 1 ;;
esac
zig_version="$(dependency_value zig.version)"
zig_bin="$repo_root/.tools/zig/$zig_version/zig-relsafe-$zig_arch-$zig_platform-baseline/zig"
if [[ ! -x "$zig_bin" ]]; then
    echo "Pinned Zig is missing. Run ./scripts/idf.sh build first." >&2
    exit 1
fi
if [[ "$("$zig_bin" version)" != "$zig_version" ]]; then
    echo "Zig compiler differs from dependencies.json" >&2
    exit 1
fi
exec "$zig_bin" "$@"
