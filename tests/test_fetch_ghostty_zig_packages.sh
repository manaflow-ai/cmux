#!/usr/bin/env bash
# scripts/ci/fetch-ghostty-zig-packages.sh hydrates Zig's package cache for a
# Ghostty source before cargo builds libghostty-vt, retrying a failed fetch:
# a DNS flake (UnknownHostName, cmux-tui-artifacts run 37401272899) failed a
# macOS build. Zig checks every package against its build.zig.zon hash.
# An attempt that stops making progress is stopped: a stalled download hung the
# fetch for 58 minutes (cmux-tui publisher run 40630560459). A stopped attempt
# is killed with every process it started, cut-short archives are removed, and
# the next attempt runs. A slow fetch that keeps progressing is left alone.
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
if [ -e "$FAKE_CACHE/p/N-bad.tar.gz" ]; then
  # Zig unpacks a cached archive without checking it.
  echo "error: unable to unpack tarball to temporary directory: ReadFailed" >&2
  exit 1
fi
if [ "$count" -le "${FAKE_ZIG_HANGS:-0}" ]; then
  # What a stalled download leaves: an unfinished unpack and a cut-short archive.
  mkdir -p "zig-pkg/.tmp-$count"
  echo half > "zig-pkg/.tmp-$count/data"
  echo half > "$FAKE_CACHE/p/N-cut-$count.tar.gz"
  # Another job on the machine finishes a download meanwhile.
  echo whole | gzip > "$FAKE_CACHE/p/N-other-$count.tar.gz"
  sleep 600 &
  echo "$!" >> "${FAKE_ZIG_CHILDREN:?}"
  wait
  exit 0
fi
if [ "$count" -le $(( ${FAKE_ZIG_HANGS:-0} + ${FAKE_ZIG_FAILURES:-0} )) ]; then
  echo "error: unable to connect to server: UnknownHostName" >&2
  exit 1
fi
# A slow download that keeps arriving: a new piece every second.
for i in $(seq 1 "${FAKE_ZIG_SLOW:-0}"); do
  mkdir -p zig-pkg/.tmp-slow; echo "$i" > "zig-pkg/.tmp-slow/$i"; sleep 1
done
rm -rf zig-pkg/.tmp-slow
mkdir -p "$FAKE_CACHE/p/N-done"
if [ "${FAKE_ZIG_ORPHAN:-0}" = 1 ]; then
  # A downloader that outlives zig, holding the step's output open.
  sleep 600 &
  echo "$!" >> "${FAKE_ZIG_CHILDREN:?}"
fi
STUB
chmod +x "$TMP/bin/zig"
run() { # <hangs> <failures> -> status in $status, seconds in $elapsed
  rm -rf "$TMP/count" "$TMP/children" "$TMP/cache/tmp"/* "$TMP/cache/p"/* "$TMP/src/zig-pkg"
  : > "$TMP/children"
  # Packages an earlier run finished, which a stopped attempt must not touch.
  mkdir -p "$TMP/src/zig-pkg/N-old"
  echo whole | gzip > "$TMP/cache/p/N-old.tar.gz"
  # Another job's download in progress: the global tmp/ is shared on a reused machine.
  mkdir -p "$TMP/cache/tmp/other-job"
  if [ "${PRE_CUT:-0}" = 1 ]; then
    head -c 4096 /dev/urandom | gzip | head -c 100 > "$TMP/cache/p/N-bad.tar.gz"
  fi
  status=0
  local start=$SECONDS
  env -u ZIG_GLOBAL_CACHE_DIR -u CMUX_ZIG CMUX_ZIG_SEED=0 PATH="$TMP/bin:$PATH" FAKE_ZIG_COUNT="$TMP/count" FAKE_ZIG_HANGS="$1" FAKE_ZIG_FAILURES="$2" \
    FAKE_ZIG_CHILDREN="$TMP/children" FAKE_ZIG_DIR="$(cd "$TMP/src" && pwd -P)" FAKE_CACHE="$TMP/cache" \
    CMUX_ZIG_FETCH_ATTEMPTS=3 CMUX_ZIG_FETCH_STALL_TIMEOUT=2 CMUX_ZIG_FETCH_SAMPLE=1 \
    CMUX_ZIG_FETCH_ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-60}" CMUX_ZIG_FETCH_RETRY_DELAY=0 \
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

# A cut-short archive already in the cache fails the fetch (ReadFailed); it is
# removed and the retry succeeds.
PRE_CUT=1 run 0 0
[ "$status" = 0 ] || fail "a cut-short cached archive was not cleared for the retry"
[ "$(cat "$TMP/count")" = 2 ] || fail "expected 2 attempts around a cut-short archive, got $(cat "$TMP/count")"
[ ! -e "$TMP/cache/p/N-bad.tar.gz" ] || fail "the cut-short archive was left in the cache"
[ -e "$TMP/cache/p/N-old.tar.gz" ] || fail "clearing a cut-short archive removed a whole one"

# A hung first attempt is stopped once it makes no progress, with its child,
# and the second attempt succeeds.
run 1 0
[ "$status" = 0 ] || fail "a hung fetch then a success did not pass"
[ "$(cat "$TMP/count")" = 2 ] || fail "expected 2 fetch attempts after one hang, got $(cat "$TMP/count")"
grep -q "attempt 1 of 3 was stopped: it made no download progress for 2s; retrying" "$TMP/out" || fail "the stall was not reported"
children_gone || fail "the hung attempt's child process outlived its deadline"
[ -d "$TMP/cache/tmp/other-job" ] || fail "clearing a hung attempt removed another job's download from the shared tmp/"
[ -z "$(ls -d "$TMP/src/zig-pkg"/.tmp-* 2>/dev/null)" ] || fail "the hung attempt's partial unpack was left in zig-pkg/"
[ ! -e "$TMP/cache/p/N-cut-1.tar.gz" ] || fail "the hung attempt's cut-short archive was left in the cache"
[ -e "$TMP/cache/p/N-other-1.tar.gz" ] || fail "clearing a hung attempt removed another job's whole archive written during it"
[ -d "$TMP/src/zig-pkg/N-old" ] && [ -e "$TMP/cache/p/N-old.tar.gz" ] || fail "clearing a hung attempt removed a finished package"
[ -d "$TMP/cache/p/N-done" ] || fail "the second attempt did not fetch"
(( elapsed < 20 )) || fail "one 2 s stall took ${elapsed}s"

# A slow fetch that keeps progressing runs past the stall timeout and passes.
FAKE_ZIG_SLOW=6 run 0 0
[ "$status" = 0 ] || fail "a slow but progressing fetch was stopped"
[ "$(cat "$TMP/count")" = 1 ] || fail "a slow but progressing fetch was retried"

# A fetch that keeps progressing but never ends is stopped at the attempt limit.
FAKE_ZIG_SLOW=600 ATTEMPT_TIMEOUT=3 run 0 0
[ "$status" != 0 ] || fail "a fetch past its attempt limit passed"
grep -q "attempt 3 of 3 was stopped: it ran past its 3s limit; giving up" "$TMP/out" || fail "the attempt limit was not reported"
(( elapsed < 40 )) || fail "three 3 s attempts took ${elapsed}s"

# A child that outlives a successful zig is stopped, and the fetch passes.
FAKE_ZIG_ORPHAN=1 run 0 0
[ "$status" = 0 ] || fail "a successful fetch that left a child running did not pass"
children_gone || fail "a child zig left running outlived the fetch"
(( elapsed < 10 )) || fail "stopping a leftover child took ${elapsed}s"

# Three hangs give up with a clear error, well inside a job's timeout.
run 5 0
[ "$status" != 0 ] || fail "three hung fetches passed"
[ "$(cat "$TMP/count")" = 3 ] || fail "expected 3 attempts for three hangs, got $(cat "$TMP/count")"
grep -q "attempt 3 of 3 was stopped: it made no download progress for 2s; giving up" "$TMP/out" || fail "three hangs did not end with a clear error"
children_gone || fail "a hung attempt's child process outlived its deadline"
[ ! -e "$TMP/cache/p/N-done" ] || fail "a hung fetch left a package that looks complete"
(( elapsed < 40 )) || fail "three 2 s stalls took ${elapsed}s"

# Cancelling the script (a job timeout or cancel signals its process group)
# stops the fetch too, though the fetch runs in a process group of its own.
rm -rf "$TMP/count" "$TMP/children" "$TMP/cache/p"/* "$TMP/src/zig-pkg"; : > "$TMP/children"
set -m
env -u ZIG_GLOBAL_CACHE_DIR -u CMUX_ZIG CMUX_ZIG_SEED=0 PATH="$TMP/bin:$PATH" FAKE_ZIG_COUNT="$TMP/count" FAKE_ZIG_HANGS=5 \
  FAKE_ZIG_CHILDREN="$TMP/children" FAKE_ZIG_DIR="$(cd "$TMP/src" && pwd -P)" FAKE_CACHE="$TMP/cache" \
  CMUX_ZIG_FETCH_STALL_TIMEOUT=60 "$SCRIPT" "$TMP/src" >"$TMP/out" 2>&1 &
script_pid=$!
set +m
for _ in $(seq 1 100); do [ -s "$TMP/children" ] && break; sleep 0.1; done
[ -s "$TMP/children" ] || fail "the hanging fetch did not start"
kill -TERM -- "-$script_pid"
cancel_status=0
wait "$script_pid" || cancel_status=$?
[ "$cancel_status" != 0 ] || fail "a cancelled fetch passed"
children_gone || fail "cancelling the script left the fetch running"

# The attempt limit is a backstop: it stays well above the slowest healthy
# fetch seen (20 minutes, publisher run 40630560459 attempt 3).
default_limit="$(sed -n 's/^attempt_timeout="${CMUX_ZIG_FETCH_ATTEMPT_TIMEOUT:-\([0-9]*\)}"$/\1/p' "$SCRIPT")"
[ -n "$default_limit" ] && (( default_limit >= 1500 )) || fail "the default attempt limit (${default_limit:-unset}s) would stop a healthy 20-minute fetch"

# Workflows fetch through the action, which skips the download when the
# packages are on the machine or in the cache store, and runs this script.
direct="$(grep -ln 'fetch-ghostty-zig-packages\.sh' "$ROOT"/.github/workflows/*.yml || true)"
[ -z "$direct" ] || { echo "FAIL: these workflows run the fetch script directly instead of .github/actions/ghostty-zig-packages: $direct" >&2; exit 1; }
grep -q 'scripts/ci/fetch-ghostty-zig-packages.sh' "$ROOT/.github/actions/ghostty-zig-packages/action.yml" \
  || { echo "FAIL: the ghostty-zig-packages action no longer runs the deadlined fetch" >&2; exit 1; }
# Only a push writes the package cache: a pull request or pull_request_target
# run must never be able to seed what later builds restore.
save_if="$(grep -A1 'name: Save the Zig packages' "$ROOT/.github/actions/ghostty-zig-packages/action.yml" | sed -n 's/.*if: //p')"
[[ "$save_if" == *"github.event_name == 'push'"* ]] \
  || { echo "FAIL: the Zig package cache is saved on more than push events: $save_if" >&2; exit 1; }

echo "PASS: Ghostty Zig packages are fetched with bounded, progress-deadlined retries"
