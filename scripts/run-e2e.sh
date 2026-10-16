#!/usr/bin/env bash
# Launch a focused suite or method on an exact pushed commit.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/ci/dispatch-focused-test.py" "$@"
