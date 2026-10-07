#!/usr/bin/env bash
# scripts/ci/tests/package-test-lane-suite-args.test.sh: package-test-lane.sh
# refuses a malformed suite filter before it builds anything. A trailing dot
# (`CmuxNextAppTests.`, hand-typed from the route's regex) matched no test and
# cost a full build three times; it must fail at once with a clear error.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT"
fails=0
refuse() {
  local want="$1"; shift
  local out code=0
  out=$(bash scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext "$@" 2>&1) || code=$?
  if [ "$code" -ne 2 ] || [[ "$out" != *"$want"* ]]; then
    echo "FAIL: suite $* exited $code, output: $out" >&2; fails=$((fails + 1))
  fi
}
refuse "ends with '.'" "CmuxNextAppTests."
refuse "ends with '.'" "CmuxNextAgentPaneTests,CmuxNextAppTests."
refuse "ends with '/'" "CmuxNextAppTests.SomeSuite/"
refuse "test filters such as" "CmuxNextAppTests,,CmuxNextPagesTests"
if [ "$fails" -ne 0 ]; then exit 1; fi
echo "package-test-lane suite args: ok"
