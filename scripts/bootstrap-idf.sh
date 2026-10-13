#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
mkdir -p .tools
if [[ ! -d "$idf_checkout/.git" ]]; then
    git clone --depth 1 --branch "$(dependency_value esp_idf.ref)" --recursive --shallow-submodules --jobs 8 \
        "$(dependency_value esp_idf.repository)" "$idf_checkout"
else
    verify_idf_checkout
    git -C "$idf_checkout" submodule update --init --recursive --depth 1 --jobs 8
fi
verify_idf_checkout
"$idf_checkout/install.sh" esp32s3
