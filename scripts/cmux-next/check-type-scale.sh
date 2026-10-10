#!/usr/bin/env bash
# Type-scale ratchet: no new raw font sizes in webviews/src (check-type-scale.py).
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/check-type-scale.py" "$@"
