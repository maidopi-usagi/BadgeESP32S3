#!/usr/bin/env bash
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
if [[ -d /opt/homebrew/opt/python@3.12/libexec/bin ]]; then
    export PATH="/opt/homebrew/opt/python@3.12/libexec/bin:$PATH"
fi

dependency_value() {
    python3 - "$repo_root/dependencies.json" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    value = json.load(source)
for key in sys.argv[2].split('.'):
    value = value[key]
print(value)
PY
}

idf_version="$(dependency_value esp_idf.version)"
idf_checkout="${ESP32_IDF_PATH:-$repo_root/.tools/esp-idf-v$idf_version}"
export IDF_TOOLS_PATH="${IDF_TOOLS_PATH:-$repo_root/.tools/idf-tools}"
export IDF_TARGET="esp32s3"

verify_idf_checkout() {
    local expected actual
    expected="$(dependency_value esp_idf.commit)"
    actual="$(git -C "$idf_checkout" rev-parse HEAD)"
    if [[ "$actual" != "$expected" ]]; then
        echo "ESP-IDF commit mismatch: $actual; expected $expected" >&2
        return 1
    fi
}
