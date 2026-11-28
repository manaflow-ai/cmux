#!/usr/bin/env bash
# Fleet entry for scripts/measure/crash-notice-nightly.py (see its docstring).
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 scripts/measure/crash-notice-nightly.py "$@"
