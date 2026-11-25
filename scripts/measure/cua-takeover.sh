#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Computer Use takeover detector on a real window server (TakeoverBench.swift):
# false takeovers under agent input on each route Cua Driver posts by, and the latency
# from a second process's input to the tap. Run on a logged-in GUI worker:
#   cmux-ci run --class exclusive --display --script scripts/measure/cua-takeover.sh --ref SHA \
#     [--arg=events=500] --artifact .build/cua-takeover/result.json
# Builds the helper at this ref and runs `cmux-cua-helper --takeover-bench`. It posts only
# harmless input (zero scrolls, in-place pointer moves, F19) and asks for no grant: without
# Accessibility for this process tree it prints the reason and exits 2.
# Output: one CUA-TAKEOVER line with the JSON, also in .build/cua-takeover/result.json.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
events=500
for arg in "$@"; do
  case "$arg" in
    events=*) events="${arg#events=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done
if [ -z "${DEVELOPER_DIR:-}" ]; then
  xcode_env="$(mktemp)"
  GITHUB_ENV="$xcode_env" CMUX_CI_SKIP_XCODE_SELECT=1 ./scripts/select-ci-xcode.sh
  DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$xcode_env" | tail -n 1)"
  rm -f "$xcode_env"
  test -n "$DEVELOPER_DIR"
  export DEVELOPER_DIR
fi
package=Packages/macOS/CmuxComputerUseHelper
swift build -c release --package-path "$package" --product cmux-cua-helper
bin="$(swift build -c release --package-path "$package" --show-bin-path)/cmux-cua-helper"
out=.build/cua-takeover
mkdir -p "$out"
status=0
"$bin" --takeover-bench --events "$events" >"$out/result.json" || status=$?
echo "CUA-TAKEOVER $(cat "$out/result.json")"
exit "$status"
