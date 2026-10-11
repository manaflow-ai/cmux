#!/usr/bin/env bash
# The cmux-next crash-class rules job (cmux-next-crash-class.yml).
#
#   scripts/ci/crash-class-gate.sh [--pr]
#
# --pr: the checkout is a pull request's merge commit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
CHECK_CONCURRENCY_ONLY=crash-class exec scripts/cmux-next/check-concurrency.sh "$ROOT/Packages/macOS/CmuxNext"
