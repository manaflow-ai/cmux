#!/usr/bin/env bash
# `cmux ios verify`: the iOS verify loop (scripts/ci/ios_verify.py has the steps and flags).
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 -I scripts/ci/ios_verify.py "$@"
