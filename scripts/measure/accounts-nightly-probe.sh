#!/usr/bin/env bash
# Preserve the signed NIGHTLY identity; the launcher supplies a private state root.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 scripts/measure/accounts-nightly-launch.py "$@"
