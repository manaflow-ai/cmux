#!/usr/bin/env bash
# Pins scripts/ci/github-egress-direct.sh and its callers: a self-hosted mini's github.com egress proxy
# (git config http.https://github.com/.proxy, a loopback ssh -R tunnel) that is half-dead (accepts, never
# answers) or refused sends package fetches direct, once, instead of failing the job; the proxy stays the
# default route. Seen: cmux runs 45830236598, 45836332236 and 45839650010 (2026-11-26).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/ci/github-egress-direct.sh"
GUARD="$ROOT/scripts/ci/swiftpm-binary-module-guard.sh"
WRAPPER="$ROOT/scripts/ci/run-xcodebuild-with-diagnostics.sh"
TMP_DIR="$(mktemp -d)"
listener_pid=""
cleanup() {
  [ -z "$listener_pid" ] || kill "$listener_pid" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; [ ! -f "$TMP_DIR/out" ] || { echo "--- output"; cat "$TMP_DIR/out"; }; exit 1; }

# A half-dead proxy: accepts connections and never answers.
python3 -I -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(16)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
held = []
while True:
    c, _ = s.accept(); held.append(c)
' "$TMP_DIR/port" &
listener_pid=$!
for _ in $(seq 1 50); do [ -s "$TMP_DIR/port" ] && break; sleep 0.1; done
[ -s "$TMP_DIR/port" ] || fail "the half-dead proxy did not start"
dead_port="$(cat "$TMP_DIR/port")"

# A git global config naming PROXY for github.com, as the mini rollout writes it; no system config.
use_proxy() {
  printf '[http "https://github.com/"]\n\tproxy = %s\n' "$1" > "$TMP_DIR/gitconfig"
}
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP_DIR/gitconfig"
unset HTTPS_PROXY https_proxy ALL_PROXY all_proxy CMUX_GITHUB_EGRESS_DIRECT CMUX_GITHUB_EGRESS_PROBED
clean_env=(env -u CMUX_GITHUB_EGRESS_DIRECT -u CMUX_GITHUB_EGRESS_PROBED GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0=pack.threads GIT_CONFIG_VALUE_0=6)

# 1. A proxy that accepts and never answers: the probe goes direct within its bound and keeps earlier configs.
use_proxy "http://127.0.0.1:$dead_port"
start=$(date +%s)
"${clean_env[@]}" CMUX_GITHUB_EGRESS_PROBE_S=2 HTTPS_PROXY="http://127.0.0.1:$dead_port" bash -c '
  set -euo pipefail; source "$1"; github_egress_probe
  echo "proxy=[$(git config --get-urlmatch http.proxy https://github.com/ || true)]"
  echo "threads=$(git config pack.threads) env=${HTTPS_PROXY:-unset} direct=${CMUX_GITHUB_EGRESS_DIRECT:-0}"
' _ "$HELPER" > "$TMP_DIR/out" 2>&1 || fail "probe of a half-dead proxy exited nonzero"
elapsed=$(( $(date +%s) - start ))
grep -q "did not answer a CONNECT in 2 s; going direct" "$TMP_DIR/out" || fail "half-dead proxy: no going-direct line"
grep -q '^proxy=\[\]$' "$TMP_DIR/out" || fail "half-dead proxy: git still routes github.com through it"
grep -q 'threads=6 env=unset direct=1' "$TMP_DIR/out" || fail "half-dead proxy: lost pack.threads or kept HTTPS_PROXY"
[ "$elapsed" -le 8 ] || fail "half-dead proxy: the probe took ${elapsed}s, past its 2 s bound"
echo "PASS: a half-dead proxy is probed within its bound and git goes direct"

# 2. A refused proxy: the probe goes direct at once.
use_proxy "http://127.0.0.1:1"
"${clean_env[@]}" CMUX_GITHUB_EGRESS_PROBE_S=2 bash -c '
  set -euo pipefail; source "$1"; github_egress_probe
  echo "proxy=[$(git config --get-urlmatch http.proxy https://github.com/ || true)]"
' _ "$HELPER" > "$TMP_DIR/out" 2>&1 || fail "probe of a refused proxy exited nonzero"
grep -q '^proxy=\[\]$' "$TMP_DIR/out" || fail "refused proxy: git still routes github.com through it"
echo "PASS: a refused proxy goes direct"

# 3. No proxy: nothing changes, and a failed fetch is not retried direct (there is no other route).
rm -f "$TMP_DIR/gitconfig"
echo "fatal: unable to access 'https://github.com/a/b/': Recv failure: Connection reset by peer" > "$TMP_DIR/fetch.log"
"${clean_env[@]}" bash -c '
  set -euo pipefail; source "$1"; github_egress_probe
  if github_egress_retry_direct "$2"; then echo retried; else echo "no retry"; fi
  echo "count=$GIT_CONFIG_COUNT"
' _ "$HELPER" "$TMP_DIR/fetch.log" > "$TMP_DIR/out" 2>&1 || fail "no proxy: exited nonzero"
grep -q 'no retry' "$TMP_DIR/out" && grep -q 'count=1' "$TMP_DIR/out" || fail "no proxy: the route changed"
echo "PASS: with no proxy nothing changes"

# 4. retry_direct: a proxy-shaped failure goes direct once; a second failure, or another kind, does not.
use_proxy "http://127.0.0.1:18434"
echo "fatal: unable to access 'https://github.com/apple/swift-atomics.git/': Failed to connect to 127.0.0.1 port 18434 after 0 ms: Couldn't connect to server" > "$TMP_DIR/fetch.log"
echo "error: manifest parse error" > "$TMP_DIR/other.log"
"${clean_env[@]}" bash -c '
  set -euo pipefail; source "$1"
  if github_egress_retry_direct "$3"; then echo "other: retried"; else echo "other: no retry"; fi
  if github_egress_retry_direct "$2"; then echo "first: retried"; else echo "first: no retry"; fi
  if github_egress_retry_direct "$2"; then echo "second: retried"; else echo "second: no retry"; fi
  echo "proxy=[$(git config --get-urlmatch http.proxy https://github.com/ || true)]"
' _ "$HELPER" "$TMP_DIR/fetch.log" "$TMP_DIR/other.log" > "$TMP_DIR/out" 2>&1 || fail "retry_direct exited nonzero"
grep -q 'other: no retry' "$TMP_DIR/out" || fail "a non-proxy failure was retried direct"
grep -q 'first: retried' "$TMP_DIR/out" || fail "a refused-proxy failure was not retried direct"
grep -q 'second: no retry' "$TMP_DIR/out" || fail "a failure after going direct was retried again"
grep -q '^proxy=\[\]$' "$TMP_DIR/out" || fail "retry_direct left the proxy in place"
echo "PASS: a proxy-shaped fetch failure is retried once, direct"

# A fake `swift` and `xcodebuild` (as a command for the wrapper): they fail with the proxy's error while git
# would route github.com through the proxy, and succeed once it would not. Each call is counted in CALLS.
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/pkg"
printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "P")\n' > "$TMP_DIR/pkg/Package.swift"
cat > "$TMP_DIR/bin/fake-fetch" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "Swift version 6.3 (stub)"; exit 0; fi
n=$(cat "$CALLS" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CALLS"
# Like xcodebuild: refuse a -resultBundlePath that already exists, else create it.
prev=""
for a in "$@"; do
  if [ "$prev" = "-resultBundlePath" ]; then
    if [ -e "$a" ]; then echo "xcodebuild: error: Existing file at -resultBundlePath \"$a\""; exit 64; fi
    mkdir -p "$a"
  fi
  prev="$a"
done
if [ "${FAIL_KIND:-proxy}" = compile ]; then echo "/x/A.swift:1:1: error: cannot find 'x' in scope"; exit 65; fi
if [ -n "$(git config --get-urlmatch http.proxy https://github.com/)" ]; then
  echo "xcodebuild: error: Could not resolve package dependencies:"
  echo "  Failed to clone repository https://github.com/getsentry/sentry-cocoa.git:"
  echo "    fatal: unable to access 'https://github.com/getsentry/sentry-cocoa.git/': Recv failure: Connection reset by peer"
  exit 74
fi
echo "resolved (stub)"
STUB
chmod +x "$TMP_DIR/bin/fake-fetch"
ln -sf fake-fetch "$TMP_DIR/bin/swift"

# 5. swift package resolve through the proxy fails, then resolves direct at once (no backoff try spent).
use_proxy "http://127.0.0.1:18434"
rm -f "$TMP_DIR/calls"
"${clean_env[@]}" PATH="$TMP_DIR/bin:$PATH" CALLS="$TMP_DIR/calls" CMUX_GITHUB_EGRESS_PROBE=0 \
  CMUX_SWIFTPM_RESOLVE_RETRY_DELAYS="30 30" CMUX_SWIFTPM_SEED_ARTIFACTS=0 \
  bash -c 'set -euo pipefail; source "$1"; swiftpm_resolve_package "$2"; echo "resolve returned"' _ "$GUARD" "$TMP_DIR/pkg" \
  > "$TMP_DIR/out" 2>&1 || fail "swift package resolve did not recover direct"
[ "$(cat "$TMP_DIR/calls")" -eq 2 ] || fail "swift package resolve: $(cat "$TMP_DIR/calls") call(s), expected 2"
grep -q 'going direct' "$TMP_DIR/out" && grep -q 'resolve returned' "$TMP_DIR/out" || fail "swift package resolve: no direct retry"
echo "PASS: swift package resolve retries once, direct, on a proxy failure"

# 6. The xcodebuild wrapper: a package resolve that failed on the proxy runs the build once more, direct.
rm -f "$TMP_DIR/calls"
"${clean_env[@]}" CALLS="$TMP_DIR/calls" CMUX_GITHUB_EGRESS_PROBE=0 CMUX_XCODEBUILD_HEARTBEAT_SECONDS=30 \
  RUNNER_TEMP="$TMP_DIR" "$WRAPPER" -- "$TMP_DIR/bin/fake-fetch" > "$TMP_DIR/out" 2>&1 \
  || fail "the wrapper did not recover from a proxy resolve failure"
[ "$(cat "$TMP_DIR/calls")" -eq 2 ] || fail "wrapper: $(cat "$TMP_DIR/calls") build(s), expected 2"
grep -q 'running it once more, direct' "$TMP_DIR/out" || fail "wrapper: no direct-retry line"
echo "PASS: the xcodebuild wrapper reruns a proxy-failed package resolve once, direct"

# 6b. The rerun clears the result bundle the first attempt wrote (xcodebuild refuses an existing one,
# status 64; capture run 45909447010 failed that way).
rm -rf "$TMP_DIR/calls" "$TMP_DIR/attempt-1.xcresult"
"${clean_env[@]}" CALLS="$TMP_DIR/calls" CMUX_GITHUB_EGRESS_PROBE=0 CMUX_XCODEBUILD_HEARTBEAT_SECONDS=30 \
  RUNNER_TEMP="$TMP_DIR" "$WRAPPER" -- "$TMP_DIR/bin/fake-fetch" -resultBundlePath "$TMP_DIR/attempt-1.xcresult" \
  > "$TMP_DIR/out" 2>&1 || fail "wrapper: the direct rerun failed on the first attempt's result bundle: $(tail -3 "$TMP_DIR/out")"
[ "$(cat "$TMP_DIR/calls")" -eq 2 ] || fail "wrapper with a result bundle: $(cat "$TMP_DIR/calls") build(s), expected 2"
echo "PASS: the direct rerun clears the first attempt's result bundle"

# 7. The wrapper does not rerun a build that failed on its own code.
rm -f "$TMP_DIR/calls"
set +e
"${clean_env[@]}" CALLS="$TMP_DIR/calls" FAIL_KIND=compile CMUX_GITHUB_EGRESS_PROBE=0 RUNNER_TEMP="$TMP_DIR" \
  "$WRAPPER" -- "$TMP_DIR/bin/fake-fetch" > "$TMP_DIR/out" 2>&1
code=$?
set -e
[ "$code" -eq 65 ] || fail "wrapper: a compile error exited $code, expected 65"
[ "$(cat "$TMP_DIR/calls")" -eq 1 ] || fail "wrapper: a compile error ran $(cat "$TMP_DIR/calls") build(s), expected 1"
echo "PASS: a compile error is not rerun"
