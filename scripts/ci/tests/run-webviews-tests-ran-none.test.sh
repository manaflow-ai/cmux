#!/usr/bin/env bash
# scripts/ci/tests/run-webviews-tests-ran-none.test.sh: a browser file whose engine does not launch skips every
# test, and bun exits 0, so run-webviews-tests.sh read it as PASS and kept its log out of the summary: a fleet
# step with CMUX_BROWSER_TESTS=1 printed 30 PASS files and "0 failed" while no browser test ran. The runner now
# lists a file that ran no test as RAN NONE with the line that says why, and a run that asked for the browser
# lane (CMUX_BROWSER_TESTS=1) fails when an engine did not launch, unless CMUX_BROWSER_SKIP_UNLAUNCHABLE=1 keeps
# the skip (a laptop or a VM without the engines). Handbook: green-that-judged-nothing.md.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/tests/lib/git-fixture.sh"  # drops inherited GIT_DIR/GIT_CONFIG redirects; turns off background maintenance
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=$(mktemp -d)
git_fixture_trap_exit 'rm -rf "$WORK"'
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

repo="$WORK/repo"
mkdir -p "$repo/webviews/test" "$WORK/bin"
echo "// a-real" > "$repo/webviews/test/a-real.test.ts"
printf '// b-skip\nrequireBrowserLane("b", () => {});\n' > "$repo/webviews/test/b-skip.test.ts"
git -C "$repo" init -q
git -C "$repo" add -A

cat > "$WORK/bin/bun" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  *a-real*) printf '(pass) real\n\n 1 pass\n 0 fail\nRan 1 tests across 1 file.\n'; exit 0 ;;
  *b-skip*) printf 'b: skipping, webkit did not launch here (Executable does not exist)\n(skip) b\n\n 0 pass\n 1 skip\n 0 fail\nRan 1 tests across 1 file.\n'; exit 0 ;;
esac
exit 1
EOF
chmod +x "$WORK/bin/bun"

# GITHUB_ACTIONS=true only keeps the runner from installing engines for CMUX_BROWSER_TESTS=1.
run() {
  local out="$1"; shift
  local status=0
  (cd "$repo/webviews" && env -u GITHUB_ACTIONS -u CMUX_BROWSER_TESTS -u CMUX_BROWSER_SKIP_UNLAUNCHABLE \
    PATH="$WORK/bin:$PATH" CMUX_WEB_TEST_JOBS=1 CMUX_WEB_TEST_RETRIES=0 "$@" \
    bash "$ROOT/scripts/ci/run-webviews-tests.sh") > "$out" 2>&1 || status=$?
  echo "$status"
}

# Outside the browser lane: the skip stays a pass, but the run says the file judged nothing and why.
status=$(run "$WORK/out1")
[ "$status" -eq 0 ] || fail "outside the browser lane a skipped file does not fail the run (exit $status)"
grep -q "^PASS test/a-real.test.ts" "$WORK/out1" || fail "a file that ran a test is a plain PASS"
grep -q "^PASS test/b-skip.test.ts (ran no test: b: skipping, webkit did not launch here" "$WORK/out1" ||
  fail "a file that ran no test says so on its verdict line"
grep -q "^ran no test (every test skipped; a pass that judged nothing): 1 of 2 files" "$WORK/out1" ||
  fail "the run counts the files that ran no test"
grep -q "^  RAN NONE test/b-skip.test.ts: b: skipping, webkit did not launch here" "$WORK/out1" ||
  fail "the summary names each file that ran no test with its reason"
grep -q "RAN NONE test/a-real" "$WORK/out1" && fail "a file that ran a test is not RAN NONE"

# The browser lane asked for: an engine that did not launch fails the run.
status=$(run "$WORK/out2" GITHUB_ACTIONS=true CMUX_BROWSER_TESTS=1)
[ "$status" -ne 0 ] || fail "with CMUX_BROWSER_TESTS=1 a file whose engine did not launch fails the run"
grep -q "^browser lane asked for (CMUX_BROWSER_TESTS=1) but an engine did not launch, so these files skipped: 1" "$WORK/out2" ||
  fail "the run says why it failed"

# The explicit local skip keeps it a pass.
status=$(run "$WORK/out3" GITHUB_ACTIONS=true CMUX_BROWSER_TESTS=1 CMUX_BROWSER_SKIP_UNLAUNCHABLE=1)
[ "$status" -eq 0 ] || fail "CMUX_BROWSER_SKIP_UNLAUNCHABLE=1 keeps the skip a pass (exit $status)"
grep -q "^  RAN NONE test/b-skip.test.ts" "$WORK/out3" || fail "a kept skip is still listed as RAN NONE"

if [ "$fails" -ne 0 ]; then
  for out in "$WORK"/out1 "$WORK"/out2 "$WORK"/out3; do echo "--- $out" >&2; cat "$out" >&2; done
  exit 1
fi
echo "run-webviews-tests-ran-none: ok"
