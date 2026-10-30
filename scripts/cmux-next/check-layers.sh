#!/usr/bin/env bash
# Layer ratchet: no new raw z-index or bare backdrop-filter in webviews/src (check-layers.py).
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/check-layers.py" "$@"
