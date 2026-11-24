#!/usr/bin/env bash
# scripts/measure/tests/run-all.sh on a host with no GNU timeout (no `timeout`, no `gtimeout`: no Mac has either,
# 2026-11-18): every test still runs, and a slow one is cut at the bound and named as timed out, never exit 127. With
# no way to bound a test at all, it says so once and fails, instead of failing every test.
# Runs a copy of run-all.sh in a scratch tree with its own tests, on a PATH holding only the tools it names.
# Run: bash scripts/measure/tests/run-all-bound.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

tree() {  # tree DIR: a repo tree with run-all.sh and three tests (passes, fails, sleeps past the bound)
  mkdir -p "$1/scripts/measure/tests"
  cp "$ROOT/scripts/measure/tests/run-all.sh" "$1/scripts/measure/tests/"
  printf 'echo fast ok\n' > "$1/scripts/measure/tests/fast.test.sh"
  printf 'echo broke; exit 3\n' > "$1/scripts/measure/tests/red.test.sh"
  printf 'echo slow started; sleep 30; echo slow ended\n' > "$1/scripts/measure/tests/slow.test.sh"
}

bin() {  # bin DIR TOOL...: DIR holds links to these tools and nothing else
  mkdir -p "$1"
  local tool
  for tool in "${@:2}"; do ln -s "$(command -v "$tool")" "$1/$tool"; done
}

fail() { echo "FAIL: $*" >&2; echo "--- output:" >&2; cat "$TMP/out" >&2; exit 1; }

BASE_TOOLS=(bash dirname mktemp rm tail sed cat sleep kill)

# 1. No timeout and no gtimeout, perl present: the tests run, the slow one is cut at the bound.
tree "$TMP/a"
bin "$TMP/a-bin" "${BASE_TOOLS[@]}" perl
start=$SECONDS
set +e
PATH="$TMP/a-bin" MEASURE_TEST_TIMEOUT=2 "$(command -v bash)" "$TMP/a/scripts/measure/tests/run-all.sh" >"$TMP/out" 2>&1
rc=$?
set -e
took=$((SECONDS - start))
[[ "$rc" == 1 ]] || fail "exit $rc, want 1 (red.test.sh and slow.test.sh fail)"
grep -q '^PASS fast.test.sh$' "$TMP/out" || fail "fast.test.sh did not pass"
grep -q '^FAIL red.test.sh (exit 3)' "$TMP/out" || fail "red.test.sh's own exit is not reported"
grep -q '^FAIL slow.test.sh (timed out after 2 s)' "$TMP/out" || fail "slow.test.sh was not cut at the bound"
grep -q 'exit 127' "$TMP/out" && fail "a missing tool read as a test's exit 127"
grep -q 'slow ended' "$TMP/out" && fail "slow.test.sh ran past the bound"
(( took < 20 )) || fail "took ${took}s: the bound did not hold"

# 2. No way to bound a test (no timeout, gtimeout or perl): one line, the job fails, no test runs.
tree "$TMP/b"
bin "$TMP/b-bin" "${BASE_TOOLS[@]}"
set +e
PATH="$TMP/b-bin" MEASURE_TEST_TIMEOUT=2 "$(command -v bash)" "$TMP/b/scripts/measure/tests/run-all.sh" >"$TMP/out" 2>&1
rc=$?
set -e
[[ "$rc" == 2 ]] || fail "exit $rc, want 2 (no bound can be set)"
[[ "$(grep -c 'cannot bound' "$TMP/out")" == 1 ]] || fail "the missing bound is not said exactly once"
grep -qE '^(PASS|FAIL) ' "$TMP/out" && fail "a test ran with no bound"

echo "ok: run-all.sh bounds each test without GNU timeout, and refuses once with no bound at all"
