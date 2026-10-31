#!/usr/bin/env bash
# scripts/ci/tests/run-webviews-tests-retry.test.sh: on a contended fleet worker (cmuxs-Mac-mini-3,
# step 7a7920f90018502137c79111) 47 webviews files failed or timed out beside their neighbours, on
# bun's 5 s test default, and each one tried passed alone on the same worker. run-webviews-tests.sh
# gives every test a 30 s default (CMUX_WEB_TEST_TIMEOUT_MS) and reruns a failed or timed-out file
# once, alone: a file that then passes is listed as passing only alone, and the lane passes; a file
# that fails twice fails the lane with both logs.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

# A checkout with a webviews/ folder of three test files (run from webviews/, the script tests what
# is there and builds nothing).
repo="$WORK/repo"
mkdir -p "$repo/webviews/test" "$WORK/bin" "$WORK/state"
for name in steady flaky broken; do echo "// $name" > "$repo/webviews/test/$name.test.ts"; done
git -C "$repo" init -q
git -C "$repo" add -A

# Fake bun: records its arguments; steady passes, flaky fails its first run only, broken always fails.
cat > "$WORK/bin/bun" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STATE/calls"
file="${*: -1}"
case "$file" in
  *steady*) echo "(pass) steady"; exit 0 ;;
  *flaky*)
    if [ -f "$STATE/flaky-ran" ]; then echo "(pass) flaky alone"; exit 0; fi
    touch "$STATE/flaky-ran"; echo "(fail) flaky beside others"; exit 1 ;;
  *broken*) echo "(fail) broken"; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/bun"

run() {
  (cd "$repo/webviews" && STATE="$WORK/state" PATH="$WORK/bin:$PATH" CMUX_WEB_TEST_JOBS=3 "$@" \
    bash "$ROOT/scripts/ci/run-webviews-tests.sh")
}

status=0
run env > "$WORK/out" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "a file that fails alone too must fail the lane"
grep -q "1 failed or timed out" "$WORK/out" || fail "only broken fails: $(grep '###' "$WORK/out")"
grep -qE "^  test/flaky.test.ts \(first run: FAIL\)$" "$WORK/out" || fail "flaky must be listed as passing only alone"
grep -q -- "--- retry, alone ---" "$WORK/out" || fail "broken's log must carry its first run and its retry"
[ "$(grep -c 'flaky' "$WORK/state/calls")" -eq 2 ] || fail "flaky must run twice: $(cat "$WORK/state/calls")"
[ "$(grep -c 'steady' "$WORK/state/calls")" -eq 1 ] || fail "a passing file must run once"
grep -q -- "--timeout 30000 ./test/steady.test.ts" "$WORK/state/calls" || fail "bun must get a 30 s test default"

# With broken gone, the flaky file alone decides nothing: the lane passes.
git -C "$repo" rm -qf webviews/test/broken.test.ts # staged, never committed: rm needs -f
rm -f "$WORK/state/flaky-ran" "$WORK/state/calls"
run env > "$WORK/out" 2>&1 || fail "a file that passes alone must not fail the lane: $(tail -5 "$WORK/out")"

# CMUX_WEB_TEST_RETRIES=0 keeps the first verdict.
rm -f "$WORK/state/flaky-ran" "$WORK/state/calls"
status=0
run env CMUX_WEB_TEST_RETRIES=0 > "$WORK/out" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "with retries off a first failure must fail the lane"

if [ "$fails" -ne 0 ]; then
  cat "$WORK/out" >&2
  exit 1
fi
echo "run-webviews-tests-retry: ok"
