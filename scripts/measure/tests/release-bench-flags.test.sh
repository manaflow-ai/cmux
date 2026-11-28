#!/usr/bin/env bash
# A measure script that builds a package's tests with `-c release` uses package-test-lane.sh's release suite flags:
# -enable-testing (@testable imports) and -DDEBUG (the DEBUG-only test helpers every package's tests use). Without
# them the whole test build fails on unrelated suites: hang-collector-note-stall.sh failed twice on 2026-11-27 (on
# 69 errors in four CmuxNext test files, then on CmuxNextDesignTests' debug pointer helpers), hours into the queue.
# Checks each `swift test ... -c release` and `swift build --build-tests ... -c release` command in scripts/measure
# (a continued line read as one); builds nothing. Run: bash scripts/measure/tests/release-bench-flags.test.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
fail=0
while IFS= read -r -d '' f; do
  # Join backslash-continued lines, keeping the first line's number.
  while IFS=$'\t' read -r n cmd; do
    [[ "$cmd" =~ swift[[:space:]]+(test|build)[[:space:]] ]] || continue
    [[ "$cmd" == *"-c release"* ]] || continue
    [[ "$cmd" == *"swift test"* || "$cmd" == *"--build-tests"* ]] || continue
    if [[ "$cmd" != *"-enable-testing"* || "$cmd" != *"-DDEBUG"* ]]; then
      echo "FAIL: $f:$n builds tests -c release without -Xswiftc -enable-testing -Xswiftc -DDEBUG (package-test-lane.sh's release suite flags)"
      echo "    $cmd"
      fail=1
    fi
  done < <(awk '{ if (buf == "") start = NR; if (sub(/\\$/, "")) { buf = buf $0 " "; next } print start "\t" buf $0; buf = "" }' "$f")
done < <(find scripts/measure -name '*.sh' -not -path 'scripts/measure/tests/*' -print0)
[[ $fail -eq 0 ]] && echo "release-bench-flags: ok"
exit $fail
