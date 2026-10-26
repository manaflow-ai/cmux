#!/usr/bin/env bash
# Swift sanitizer sweep over CmuxNext and its mac closure (p10-stability-013).
#
#   cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh \
#     -- --sanitize thread[,address,undefined,coop-strict] [--ref SHA] [--out findings.jsonl]
#        [--out-dir DIR] [--package Packages/...] [--target NAME] [--include-base-red] [--list]
#
# It enumerates the test targets (swift package dump-package, following path
# dependencies), runs them once with no sanitizer to list the base-red suites,
# then runs scripts/ci/package-test-lane.sh `suite` per package and mode, and
# counts only tsan/asan/ubsan signatures from crash_signature.py (and hangs under
# coop-strict). Base-red suites are printed and not counted.
# Exit 0 clean, 1 findings, 2 refused or usage, 3 no verdict.
# scripts/cmux-next/README-sanitizers.md has the details and the suppression rules.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

for arg in "$@"; do
  case "$arg" in -h|--help) exec python3 -I scripts/cmux-next/sanitizer_sweep.py --help ;; esac
done

# shellcheck source=scripts/cmux-next/lib/fleet-only.sh
source scripts/cmux-next/lib/fleet-only.sh
cmux_next_require_fleet sanitizer-sweep.sh 'swift build and swift test under sanitizers' \
  'none (a fleet step)' \
  'cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh -- --sanitize thread'

# The manifests are read with the Xcode the lane builds with (package-test-lane.sh
# select_xcode keeps a DEVELOPER_DIR that is already set).
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  xcode_env=$(mktemp -t sanitizer-sweep-xcode.XXXXXX)
  trap 'rm -f "$xcode_env"' EXIT
  GITHUB_ENV="$xcode_env" CMUX_CI_SKIP_XCODE_SELECT=1 ./scripts/select-ci-xcode.sh
  DEVELOPER_DIR=$(sed -n 's/^DEVELOPER_DIR=//p' "$xcode_env" | tail -n 1)
  [[ -n "$DEVELOPER_DIR" ]] || { echo "sanitizer-sweep.sh: select-ci-xcode.sh chose no Xcode" >&2; exit 3; }
  export DEVELOPER_DIR
fi

python3 -I scripts/cmux-next/sanitizer_sweep.py "$@"
