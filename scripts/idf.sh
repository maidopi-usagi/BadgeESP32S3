#!/usr/bin/env bash
set -eo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
if [[ ! -f "$idf_checkout/export.sh" ]]; then
    echo "ESP-IDF is missing. Run ./scripts/bootstrap-idf.sh first." >&2
    exit 1
fi
verify_idf_checkout
source "$idf_checkout/export.sh"
exec idf.py "$@"
