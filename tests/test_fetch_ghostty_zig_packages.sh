#!/usr/bin/env bash
# scripts/ci/fetch-ghostty-zig-packages.sh hydrates Zig's package cache for a
# Ghostty source before cargo builds libghostty-vt, retrying a failed fetch:
# a DNS flake (UnknownHostName, cmux-tui-artifacts run 37401272899) failed a
# macOS build. Zig checks every package against its build.zig.zon hash. A
# fetch that stalls is ended and retried (cmux-tui-artifacts run 40632104722).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci/fetch-ghostty-zig-packages.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/src"
echo '.{}' > "$TMP/src/build.zig.zon"
cat > "$TMP/bin/zig" <<'STUB'
#!/usr/bin/env bash
# Fails (or with FAKE_ZIG_HANG=1 stalls) the first FAKE_ZIG_FAILURES fetches, then succeeds.
count_file="${FAKE_ZIG_COUNT:?}"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$count" > "$count_file"
[ "$*" = "build --fetch=all" ] || { echo "unexpected zig args: $*" >&2; exit 2; }
[ "$(pwd -P)" = "${FAKE_ZIG_DIR:?}" ] || { echo "zig ran in $(pwd -P)" >&2; exit 2; }
if [ "$count" -le "${FAKE_ZIG_FAILURES:?}" ]; then
  [ "${FAKE_ZIG_HANG:-0}" = 1 ] && exec sleep 60
  echo "error: unable to connect to server: UnknownHostName" >&2
  exit 1
fi
STUB
chmod +x "$TMP/bin/zig"
run() { # <failures> [hang] -> status in $status
  rm -f "$TMP/count"
  status=0
  PATH="$TMP/bin:$PATH" FAKE_ZIG_HANG="${2:-0}" CMUX_ZIG_FETCH_ATTEMPT_SECONDS=2 FAKE_ZIG_COUNT="$TMP/count" FAKE_ZIG_FAILURES="$1" FAKE_ZIG_DIR="$(cd "$TMP/src" && pwd -P)" \
    CMUX_ZIG_FETCH_ATTEMPTS=3 CMUX_ZIG_FETCH_RETRY_DELAY=0 \
    "$SCRIPT" "$TMP/src" >"$TMP/out" 2>&1 || status=$?
}
run 2
[ "$status" = 0 ] || { cat "$TMP/out"; echo "FAIL: two failed fetches then a success did not pass" >&2; exit 1; }
[ "$(cat "$TMP/count")" = 3 ] || { echo "FAIL: expected 3 fetch attempts, got $(cat "$TMP/count")" >&2; exit 1; }
run 5
[ "$status" != 0 ] || { echo "FAIL: a fetch that always fails passed" >&2; exit 1; }
[ "$(cat "$TMP/count")" = 3 ] || { echo "FAIL: the attempts are not bounded" >&2; exit 1; }
grep -q "UnknownHostName" "$TMP/out" || { echo "FAIL: the fetch error was hidden" >&2; exit 1; }
started=$SECONDS
run 1 1
[ "$status" = 0 ] || { cat "$TMP/out"; echo "FAIL: a stalled fetch was not ended and retried" >&2; exit 1; }
[ "$(cat "$TMP/count")" = 2 ] || { echo "FAIL: expected 2 fetch attempts after a stall, got $(cat "$TMP/count")" >&2; exit 1; }
(( SECONDS - started < 30 )) || { echo "FAIL: the stalled attempt was not ended at its limit" >&2; exit 1; }
echo "PASS: Ghostty Zig packages are fetched with bounded retries and bounded attempts"
