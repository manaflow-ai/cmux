#!/usr/bin/env bash
set -euo pipefail
EVAL_APPLE_MODE=standard exec bash "$(dirname "$0")/apple.sh" "$@"
