#!/bin/bash
# Fleet measurement workers invoke scripts with Bash, regardless of their shebang.
set -euo pipefail
exec python3 "$(dirname "$0")/cloud-first-byte.py" "$@"
