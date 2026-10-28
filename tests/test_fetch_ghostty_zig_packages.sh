#!/usr/bin/env bash
# scripts/ci/fetch-ghostty-zig-packages.sh hydrates Zig's package cache for a
# Ghostty source before cargo builds libghostty-vt, retrying a failed fetch:
# a DNS flake (UnknownHostName, cmux-tui-artifacts run 37401272899) failed a
# macOS build. Zig checks every package against its build.zig.zon hash.
# Each attempt has a deadline: a stalled download hung the fetch for 58 minutes
# (cmux-tui publisher run 40630560459). A hung attempt is killed with every
# process it started, its scratch is cleared, and the next attempt runs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci/fetch-ghostty-zig-packages.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/src" "$TMP/cache/tmp" "$TMP/cache/p"
echo '.{}' > "$TMP/src/build.zig.zon"
cat > "$TMP/bin/zig" <<'STUB'
#!/usr/bin/env bash
# Hangs the first FAKE_ZIG_HANGS fetches (with a child of its own, as zig's
# downloads are), fails the next FAKE_ZIG_FAILURES, then succeeds.
if [ "$*" = env ]; then printf '.{\n    .global_cache_dir = "%s",\n}\n' "${FAKE_CACHE:?}"; exit 0; fi
count_file="${FAKE_ZIG_COUNT:?}"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$count" > "$count_file"
[ "$*" = "build --fetch=all" ] || { echo "unexpected zig args: $*" >&2; exit 2; }
[ "$(pwd -P)" = "${FAKE_ZIG_DIR:?}" ] || { echo "zig ran in $(pwd -P)" >&2; exit 2; }
if [ "$count" -le "${FAKE_ZIG_HANGS:-0}" ]; then
  # What a stalled download leaves: an unfinished unpack (Zig 0.16 stages it
  # in zig-pkg/.tmp-*, older Zig in the cache's tmp/) and a cut-short archive.
  mkdir -p "$FAKE_CACHE/tmp/partial-$count" "zig-pkg/.tmp-$count"
  echo half > "$FAKE_CACHE/tmp/partial-$count/data"
  echo half > "zig-pkg/.tmp-$count/data"
  echo half > "$FAKE_CACHE/p/N-cut-$count.tar.gz"
  sleep 600 &
  echo "$!" >> "${FAKE_ZIG_CHILDREN:?}"
  wait
  exit 0
fi
if [ "$count" -le $(( ${FAKE_ZIG_HANGS:-0} + ${FAKE_ZIG_FAILURES:-0} )) ]; then
  echo "error: unable to connect to server: UnknownHostName" >&2
  exit 1
fi
mkdir -p "$FAKE_CACHE/p/N-done"
STUB
chmod +x "$TMP/bin/zig"
run() { # <hangs> <failures> -> status in $status, seconds in $elapsed
  rm -rf "$TMP/count" "$TMP/children" "$TMP/cache/tmp"/* "$TMP/cache/p"/* "$TMP/src/zig-pkg"
  : > "$TMP/children"
  # Packages an earlier run finished, which a killed attempt must not touch.
  mkdir -p "$TMP/src/zig-pkg/N-old"
  echo whole > "$TMP/cache/p/N-old.tar.gz"
  touch -t 202001010000 "$TMP/cache/p/N-old.tar.gz"
  status=0
  local start=$SECONDS
  PATH="$TMP/bin:$PATH" FAKE_ZIG_COUNT="$TMP/count" FAKE_ZIG_HANGS="$1" FAKE_ZIG_FAILURES="$2" \
    FAKE_ZIG_CHILDREN="$TMP/children" FAKE_ZIG_DIR="$(cd "$TMP/src" && pwd -P)" FAKE_CACHE="$TMP/cache" \
    CMUX_ZIG_FETCH_ATTEMPTS=3 CMUX_ZIG_FETCH_ATTEMPT_TIMEOUT=2 CMUX_ZIG_FETCH_RETRY_DELAY=0 \
    "$SCRIPT" "$TMP/src" >"$TMP/out" 2>&1 || status=$?
  elapsed=$((SECONDS - start))
}
fail() { cat "$TMP/out" >&2; echo "FAIL: $*" >&2; exit 1; }
children_gone() {
  local child
  while read -r child; do
    [ -n "$child" ] || continue
    if kill -0 "$child" 2>/dev/null; then kill "$child" 2>/dev/null; return 1; fi
  done < "$TMP/children"
}

run 0 2
[ "$status" = 0 ] || fail "two failed fetches then a success did not pass"
[ "$(cat "$TMP/count")" = 3 ] || fail "expected 3 fetch attempts, got $(cat "$TMP/count")"

run 0 5
[ "$status" != 0 ] || fail "a fetch that always fails passed"
[ "$(cat "$TMP/count")" = 3 ] || fail "the attempts are not bounded"
grep -q "UnknownHostName" "$TMP/out" || fail "the fetch error was hidden"

# A hung first attempt is killed on its deadline, with its child, and the
# second attempt succeeds.
run 1 0
[ "$status" = 0 ] || fail "a hung fetch then a success did not pass"
[ "$(cat "$TMP/count")" = 2 ] || fail "expected 2 fetch attempts after one hang, got $(cat "$TMP/count")"
grep -q "timed out after 2s (attempt 1 of 3)" "$TMP/out" || fail "the timeout was not reported"
children_gone || fail "the hung attempt's child process outlived its deadline"
[ -z "$(ls -A "$TMP/cache/tmp")" ] || fail "the hung attempt's partial download was left in Zig's scratch dir"
[ -z "$(ls -d "$TMP/src/zig-pkg"/.tmp-* 2>/dev/null)" ] || fail "the hung attempt's partial unpack was left in zig-pkg/"
[ ! -e "$TMP/cache/p/N-cut-1.tar.gz" ] || fail "the hung attempt's cut-short archive was left in the cache"
[ -d "$TMP/src/zig-pkg/N-old" ] && [ -e "$TMP/cache/p/N-old.tar.gz" ] || fail "clearing a hung attempt removed a finished package"
[ -d "$TMP/cache/p/N-done" ] || fail "the second attempt did not fetch"
(( elapsed < 20 )) || fail "one 2 s hang took ${elapsed}s"

# Three hangs give up with a clear error, well inside a job's timeout.
run 5 0
[ "$status" != 0 ] || fail "three hung fetches passed"
[ "$(cat "$TMP/count")" = 3 ] || fail "expected 3 attempts for three hangs, got $(cat "$TMP/count")"
grep -q "attempt 3 of 3 timed out after 2s; giving up" "$TMP/out" || fail "three hangs did not end with a clear error"
children_gone || fail "a hung attempt's child process outlived its deadline"
[ ! -e "$TMP/cache/p/N-done" ] || fail "a hung fetch left a package that looks complete"
(( elapsed < 40 )) || fail "three 2 s hangs took ${elapsed}s"

echo "PASS: Ghostty Zig packages are fetched with bounded, deadlined retries"
