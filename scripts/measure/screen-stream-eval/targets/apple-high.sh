#!/usr/bin/env bash
set -euo pipefail
EVAL_APPLE_MODE=high exec bash "$(dirname "$0")/apple.sh" "$@"
