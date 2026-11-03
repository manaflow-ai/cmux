#!/usr/bin/env bash
# Pins swiftpm_binary_module_guard's resolve (scripts/ci/swiftpm-binary-module-guard.sh): a `swift package
# resolve` that fails on a network fetch error retries (3 tries with backoff) and shows its output in the
# step log; when every try fails the step exits 75 with "fetch failed, no test ran", so an infrastructure
# failure is never read as a test failure. A resolve that fails for another reason keeps the old rule
# (purge the build outputs, let the build say why). Seen: step 9bc9eadb on cmux14 (2026-10-28): "RPC failed;
# curl 18 Transferred a partial file", then "binary target 'CCmuxAppFFI' could not be mapped to an
# artifact", exit 1 with no test run (handoff/v224-gate-triage.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/ci/swiftpm-binary-module-guard.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/pkg"
printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "P")\n' > "$TMP_DIR/pkg/Package.swift"
# A fake `swift`: `swift package resolve` fails FAILS times (FAIL_KIND network or manifest), then succeeds;
# each call is counted in CALLS. `swift --version` answers for the digest.
cat > "$TMP_DIR/bin/swift" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "Swift version 6.3 (stub)"; exit 0; fi
n=$(cat "$CALLS" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CALLS"
if [ "$n" -le "$FAILS" ]; then
  if [ "$FAIL_KIND" = network ]; then
    echo "error: Couldn’t fetch updates from remote repositories:"
    echo "    error: RPC failed; curl 18 Transferred a partial file"
    echo "error: 'cmuxnext': binary target 'CCmuxAppFFI' could not be mapped to an artifact with expected name 'CCmuxAppFFI'"
  else
    echo "error: manifest parse error: unexpected token in Package.swift"
  fi
  exit 1
fi
echo "resolved (stub)"
exit 0
STUB
chmod +x "$TMP_DIR/bin/swift"

# Runs the guard in a child bash as a lane does (set -euo pipefail, the script sourced); prints its output,
# returns its exit code.
run_guard() {
  local fails="$1" kind="$2" calls="$TMP_DIR/calls-$1-$2"
  rm -f "$calls"
  mkdir -p "$TMP_DIR/pkg/.build/out" # a kept build output the failed-resolve rule removes
  set +e
  PATH="$TMP_DIR/bin:$PATH" CALLS="$calls" FAILS="$fails" FAIL_KIND="$kind" CMUX_SWIFTPM_RESOLVE_RETRY_DELAYS="0 0" \
    bash -c 'set -euo pipefail; source "$1"; swiftpm_binary_module_guard "$2"; echo "guard returned"' _ "$GUARD" "$TMP_DIR/pkg" \
    > "$TMP_DIR/out" 2>&1
  local code=$?
  set -e
  echo "$code $(cat "$calls" 2>/dev/null || echo 0)"
}

fail() { echo "FAIL: $*"; echo "--- output"; cat "$TMP_DIR/out"; exit 1; }

# 1. Two network failures, then a resolve: the guard retries and the step goes on.
read -r code calls < <(run_guard 2 network)
[ "$code" -eq 0 ] || fail "two network fetch failures then success: exit $code, expected 0"
[ "$calls" -eq 3 ] || fail "two network fetch failures then success: $calls resolve call(s), expected 3 (retries)"
grep -q 'curl 18' "$TMP_DIR/out" || fail "the failed resolve's output is not in the step log"
grep -q 'guard returned' "$TMP_DIR/out" || fail "the guard did not return after a resolve that succeeded on retry"
echo "PASS: a network fetch failure is retried and its output is in the step log"

# 2. Every try fails on the network: exit 75, "fetch failed, no test ran", the build outputs purged.
read -r code calls < <(run_guard 9 network)
[ "$code" -eq 75 ] || fail "three network fetch failures: exit $code, expected 75"
[ "$calls" -eq 3 ] || fail "three network fetch failures: $calls resolve call(s), expected 3"
grep -q 'fetch failed, no test ran' "$TMP_DIR/out" || fail "no 'fetch failed, no test ran' line"
grep -q 'guard returned' "$TMP_DIR/out" && fail "the step went on after every fetch failed"
[ ! -e "$TMP_DIR/pkg/.build/out" ] || fail "the build outputs stayed after the fetch failed"
echo "PASS: when every try fails on the network the step exits 75 with 'fetch failed, no test ran'"

# 3. A resolve that fails for another reason (the commit's own manifest): no retry, the old rule (purge, go on).
read -r code calls < <(run_guard 9 manifest)
[ "$code" -eq 0 ] || fail "a manifest failure: exit $code, expected 0 (the build reports why)"
[ "$calls" -eq 1 ] || fail "a manifest failure: $calls resolve call(s), expected 1 (no retry)"
grep -q 'ci-phase swift package resolve failed' "$TMP_DIR/out" || fail "a manifest failure lost the 'resolve failed' line"
grep -q 'manifest parse error' "$TMP_DIR/out" || fail "a manifest failure's output is not in the step log"
echo "PASS: a non-network resolve failure is not retried and keeps the old rule"

# 4. The package lane (scripts/ci/package-test-lane.sh packages) with two packages: Alpha's tests fail, Beta's
#    resolve fails on the network every try. The lane must not stop at Beta (exit 75 from inside the loop would
#    hide Alpha's red): every package gets a row, Beta's is "no verdict", and the lane exits with Alpha's failure.
#    With Alpha passing, the lane ends with 75 (no verdict), not 1.
LANE="$TMP_DIR/lane"
mkdir -p "$LANE/scripts" "$LANE/Packages/macOS/Alpha" "$LANE/Packages/macOS/Beta" "$TMP_DIR/lanebin"
cp -R "$ROOT/scripts/ci" "$LANE/scripts/ci"
for p in Alpha Beta; do printf '// swift-tools-version: 6.0\n' > "$LANE/Packages/macOS/$p/Package.swift"; done
cat > "$TMP_DIR/lanebin/swift" <<'STUB'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "Swift version 6.3 (stub)"; exit 0; fi
pkg=""; prev=""
for a in "$@"; do [ "$prev" = "--package-path" ] && pkg="$a"; prev="$a"; done
case "$1 $2 $pkg" in
  "package resolve "*Beta*)
    echo "error: Couldn’t fetch updates from remote repositories:"
    echo "    error: RPC failed; curl 18 Transferred a partial file"; exit 1 ;;
  "package resolve "*) echo "resolved"; exit 0 ;;
  "test "*)
    if [ "${ALPHA_FAILS:-1}" = 1 ]; then
      echo "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue."; exit 1
    fi
    echo "✔ Test run with 1 test in 1 suite passed after 0.1 seconds."; exit 0 ;;
  *) echo "Build complete!"; exit 0 ;;
esac
STUB
chmod +x "$TMP_DIR/lanebin/swift"
printf 'Alpha\nBeta\n' > "$TMP_DIR/selected.txt"
run_lane() {
  set +e
  (cd "$LANE" && env PATH="$TMP_DIR/lanebin:$PATH" RUNNER_TEMP="$TMP_DIR/lanework" ALPHA_FAILS="$1" \
    CMUX_SWIFTPM_RESOLVE_RETRY_DELAYS="0 0" CMUX_SWIFT_PACKAGE_BUILD_JOBS=1 \
    SELECTED_PACKAGES="$TMP_DIR/selected.txt" SELECTED_COUNT=2 bash scripts/ci/package-test-lane.sh packages) \
    > "$TMP_DIR/out" 2>&1
  local code=$?
  set -e
  echo "$code"
}
mkdir -p "$TMP_DIR/lanework"
code="$(run_lane 1)"
grep -Eq '^Beta +no verdict \(fetch\)' "$TMP_DIR/out" || fail "the lane has no 'no verdict' row for Beta (it stopped at Beta?)"
grep -Eq '^Alpha +failed' "$TMP_DIR/out" || fail "the lane has no failed row for Alpha"
[ "$code" -eq 1 ] || fail "Alpha failed and Beta had no verdict: lane exit $code, expected Alpha's 1"
echo "PASS: a package whose fetch failed does not stop the lane or hide another package's red"
code="$(run_lane 0)"
grep -Eq '^Alpha +passed' "$TMP_DIR/out" || fail "Alpha did not pass in the second run"
[ "$code" -eq 75 ] || fail "Alpha passed and Beta had no verdict: lane exit $code, expected 75"
grep -q 'fetch failed, no test ran' "$TMP_DIR/out" || fail "the lane's 75 has no 'fetch failed, no test ran' line"
echo "PASS: a lane with no red and a package whose fetch failed ends with 75 (no verdict)"
