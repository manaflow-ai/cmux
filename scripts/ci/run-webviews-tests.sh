#!/usr/bin/env bash
# Runs every webviews test file in its own `bun test` process, run from webviews/.
#
# One `bun test` process for the whole suite stalled in a different file each run
# (ui-menu, markdown-viewer-shell, chips/linkChips) until the job timeout, and each
# of those files passes alone: state leaks from file to file (timers, handles,
# jsdom globals). A process per file keeps that leak inside one file, and a
# wall-clock timeout per file names a stuck file instead of hanging the job.
#
# CMUX_WEB_TEST_FILE_TIMEOUT: seconds one file may run (default 120); a file may declare more
# with a `// cmux-web-test-timeout: SECONDS` header line, up to CMUX_WEB_TEST_MAX_FILE_TIMEOUT
# (default 900). A 3000s attachment stress-file allowance can outlive the entire 40-minute CI job;
# longer runs must explicitly raise the ceiling outside the ordinary PR shard.
# CMUX_WEB_TEST_TIMEOUT_MS: one test's default limit (bun's own default is 5000); a test or file
# that sets its own (setDefaultTimeout, a per-test timeout) keeps it. 30000 by default: on a fleet
# worker that also runs GitHub runner jobs, a render-heavy jsdom test that takes 0.5 s alone took
# 5-23 s with six files beside it (cmuxs-Mac-mini-3, step 7a7920f90018502137c79111: 110 files over
# 5 s), and each of those files passed alone on the same worker.
# CMUX_WEB_TEST_RETRIES: files that fail run once more, one at a time, after every
# file has run (default 60 files; 0 turns it off). A file that passes alone is reported as a retry
# pass (a contention flake, listed so it stays visible); one that fails again fails the lane.
# Timed-out files keep their named failure without another full timeout. Serial retries stop
# after CMUX_WEB_TEST_RETRY_BUDGET seconds (default 120), including an in-flight retry;
# unretried failures stay red.
# CMUX_WEB_TEST_JOBS: files run at once (default: CMUX_CI_CPU_BUDGET, the cores a fleet
# worker granted the step, else the CPU count).
# CMUX_WEB_TEST_FILES: optional newline-separated test files (relative to webviews/) to run instead
# of every file, for focused runs (scripts/ci/car_guards.py). A name the git index does not list
# is an error, so a stale selection never passes by running nothing.
# CMUX_WEB_TEST_RESULTS: optional file to write each file's and failed test's result into
# (webviews_test_results.py), for webviews-tests-new-reds.sh.
# CMUX_WEB_TEST_RAW_LOG_DIR: optional artifact directory for complete per-attempt logs. The public
# step output is bounded, while this directory keeps the raw evidence for diagnosis and parsing.
# CMUX_WEB_TEST_SHARD / CMUX_WEB_TEST_SHARD_COUNT: optional one-based shard selector (for example
# 1/2 or 2/2). Sharding happens after the git-index file list is built, so every shard keeps the
# same per-file process and Vite-cache isolation rules while covering a disjoint deterministic set.
#
# Files that start a Vite dev server run after the rest: the agent pane and gallery configs
# (vite.config.acpmux-pane.mjs, vite.config.gallery-dev.ts), and files that spawn `vp dev`
# themselves (editor-page, ui-a11y, settings-scroll). On one node_modules/.vite two at once lose
# each other's optimized files, and three starting cold at once (agent-history,
# agent-pane-peer-chat, chat-find) stall in the optimizer's first bundle, even with a cache each;
# editor-page timed out the same way beside ui-a11y and text-field-focus. So one file per Vite
# config runs first, alone, and warms that config's cache (CMUX_VITE_CACHE_DIR, which the dev
# configs read); the rest then run CMUX_WEB_TEST_DEV_JOBS at once (default a quarter of the jobs), each
# on its own copy of its config's warm cache. A warming file that fails leaves no trustworthy
# cache, so the config's next file warms a fresh one, up to CMUX_WEB_TEST_WARM_ATTEMPTS files
# (default 3); a config none of them warms keeps its other files one at a time on a cold cache each.
#
# Run from webviews/ (CI, local dev) it tests what is there. Run from anywhere else in the
# checkout (a cmux-ci step starts at the checkout root) it first makes the web bundles
# current (scripts/ci/ensure-web-bundles.sh, which also provides the pinned bun), runs
# `bun install --frozen-lockfile` in webviews/, and then tests webviews/ only.
#
# Runs the same way on Linux CI and on a Mac (cmux-lawrence-2, nx-remote jobs): a full
# single-process `bun test` there fails about 630 tests after one slow test leaves a React
# act() scope open for every later file. Macs have no coreutils `timeout`, so the worker
# falls back to gtimeout, then to a perl stand-in with the same exit codes.
set -euo pipefail

# run_with_timeout SECONDS COMMAND...: exit 124 when SECONDS pass, as `timeout -k 10` does.
run_with_timeout() {
  if command -v timeout > /dev/null 2>&1; then
    timeout -k 10 "$@"
  elif command -v gtimeout > /dev/null 2>&1; then
    gtimeout -k 10 "$@"
  else
    # The child gets its own process group, so the TERM (and the KILL 10 s later) reach
    # everything bun started.
    perl -MPOSIX=WNOHANG -e '
      my ($seconds, @command) = @ARGV;
      my $pid = fork;
      die "fork: $!\n" unless defined $pid;
      if (!$pid) { setpgrp(0, 0); exec { $command[0] } @command or exit 127; }
      my ($deadline, $kill_at, $timed_out) = (time + $seconds, 0, 0);
      until (waitpid($pid, WNOHANG) == $pid) {
        if (!$timed_out && time >= $deadline) { $timed_out = 1; kill "TERM", -$pid; $kill_at = time + 10; }
        kill "KILL", -$pid if $timed_out && time >= $kill_at;
        select(undef, undef, undef, 0.1);
      }
      exit 124 if $timed_out;
      exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
    ' "$@"
  fi
}

# file_limit FILE DEFAULT: the seconds FILE may run. A file whose own tests need more than the
# default names its limit on a header line (first 20 lines), `// cmux-web-test-timeout: SECONDS`
# (editor-page: 24 browser tests in two engines, about 115 s on the CI runner, were killed at
# 120 s mid-WebKit). The longer of the two wins, up to the runner hard ceiling.
file_limit() {
  local declared limit maximum="${CMUX_WEB_TEST_MAX_FILE_TIMEOUT:-900}"
  [[ "$maximum" =~ ^[1-9][0-9]*$ ]] || maximum=900
  declared="$(head -n 20 "$1" 2> /dev/null | sed -n 's|^// cmux-web-test-timeout: \([1-9][0-9]*\)$|\1|p' | head -n 1)"
  limit="$2"
  if [ -n "$declared" ] && [ "$declared" -gt "$limit" ]; then limit="$declared"; fi
  if [ "$limit" -gt "$maximum" ]; then limit="$maximum"; fi
  echo "$limit"
}

test_timeout_ms="${CMUX_WEB_TEST_TIMEOUT_MS:-30000}"
[[ "$test_timeout_ms" =~ ^[1-9][0-9]*$ ]] || test_timeout_ms=30000
export CMUX_WEB_TEST_TIMEOUT_MS="$test_timeout_ms"

log_display_bytes="${CMUX_WEB_TEST_LOG_DISPLAY_BYTES:-200000}"
[[ "$log_display_bytes" =~ ^[1-9][0-9]*$ ]] || log_display_bytes=200000

# A browser can write one giant diagnostic line (for example a WPE inspector trace). Keep the
# complete log on disk, but never copy it into the Actions console more than the configured byte
# budget. The tail retains the final named assertion after a flood of diagnostics.
print_bounded_log() {
  python3 - "$1" "$log_display_bytes" <<'PY'
import os
import sys

path, requested = sys.argv[1], int(sys.argv[2])
with open(path, "rb") as stream:
    size = os.fstat(stream.fileno()).st_size
    if size <= requested:
        sys.stdout.buffer.write(stream.read())
        raise SystemExit
    if os.environ.get("CMUX_WEB_TEST_RAW_LOG_DIR"):
        note = b"complete log is in the configured webviews raw-log artifact"
    else:
        note = b"complete log remains in the runner's per-file log"
    marker = b"\n... output truncated; " + note + b" ...\n"
    available = max(0, requested - len(marker))
    head_size = available // 2
    tail_size = available - head_size
    head = stream.read(head_size)
    stream.seek(max(0, size - tail_size))
    tail = stream.read(tail_size)
    sys.stdout.buffer.write(head + marker + tail)
PY
}

if [ "${1:-}" = --one-cached ]; then
  # xargs -n 3 appends FILE CACHE SEED after the fixed arguments.
  exec bash "$0" --one "$4" "$2" "$3" "$5" "${6:-}"
fi
if [ "${1:-}" = --one ]; then
  # Worker: run one file, write its log and status into the results directory. A dev server
  # file gets a Vite cache of its own (CMUX_VITE_CACHE_DIR), a copy of a warm one when given.
  file="$2" results="$3" timeout_seconds="$(file_limit "$2" "$4")" cache="${5:-}" seed="${6:-}"
  log="$results/$(printf '%s' "$file" | tr '/' '_').log"
  status=0
  echo "START $file (hard limit ${timeout_seconds}s)"
  if [ -n "$cache" ]; then
    # `|| true` on cache upkeep: a failed copy or cleanup (a server outliving its timed-out file)
    # must still leave this file's result in the summary, not stop the lane under set -e.
    rm -rf "$cache" || true
    mkdir -p "$(dirname "$cache")"
    if [ -n "$seed" ] && [ -d "$seed" ]; then cp -R "$seed" "$cache" || true; fi
    mkdir -p "$cache"
    CMUX_VITE_CACHE_DIR="$cache" run_with_timeout "$timeout_seconds" bun test --timeout "$test_timeout_ms" "./$file" > "$log" 2>&1 < /dev/null ||
      status=$?
    # A warming file's cache (no seed) is the one the rest copy; any other one only costs disk.
    if [ -n "$seed" ]; then rm -rf "$cache" || true; fi
  else
    run_with_timeout "$timeout_seconds" bun test --timeout "$test_timeout_ms" "./$file" > "$log" 2>&1 < /dev/null || status=$?
  fi
  case "$status" in
    0) result=PASS ;;
    124 | 137) result=TIMEOUT ;;
    *) result=FAIL ;;
  esac
  printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
  # Keep the named verdict immediate; the complete log is emitted once in the final summary below.
  echo "$result $file (raw log retained for the final bounded summary)"
  exit 0
fi

self="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
case "$(git rev-parse --show-prefix)" in
  webviews/*) ;;
  *)
    cd "$(git rev-parse --show-toplevel)"
    bash scripts/ci/ensure-web-bundles.sh
    # ensure-web-bundles.sh puts the pinned bun on its own PATH only: use the same copy.
    bun_pin="$(python3 -c 'import json; print(json.load(open("webviews/package.json"))["devEngines"]["packageManager"]["version"])')"
    bun_dir="${CMUX_CI_CACHE_DIR:-$HOME/Library/Caches/cmux-ci}/tools/bun-$bun_pin/bin"
    if [ "$(bun --version 2>/dev/null || true)" != "$bun_pin" ] && [ -x "$bun_dir/bun" ]; then
      export PATH="$bun_dir:$PATH"
    fi
    cd webviews
    bun install --frozen-lockfile
    ;;
esac
# A fleet cmux-ci step that runs the browser lane (CMUX_BROWSER_TESTS=1, requireBrowserLane.ts) needs
# the engines PR CI installs; without them the lane only ever ran in PR CI. They live in the step
# cache, one directory per Playwright version, so a host downloads each once. GitHub Actions
# installs its own (cmux-next-web-bundles.yml).
if [ "${CMUX_BROWSER_TESTS:-}" = 1 ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
  playwright_version="$(python3 -c 'import json; print(json.load(open("package.json"))["devDependencies"]["playwright"])' 2> /dev/null || echo unknown)"
  export PLAYWRIGHT_BROWSERS_PATH="${CMUX_CI_CACHE_DIR:-$HOME/Library/Caches/cmux-ci}/playwright-$playwright_version"
  ./node_modules/.bin/playwright install --only-shell chromium webkit
fi

timeout_seconds="${CMUX_WEB_TEST_FILE_TIMEOUT:-120}"
default_jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
if [[ "${CMUX_CI_CPU_BUDGET:-}" =~ ^[1-9][0-9]*$ ]]; then
  default_jobs="$CMUX_CI_CPU_BUDGET"
fi
jobs="${CMUX_WEB_TEST_JOBS:-$default_jobs}"
results="$(mktemp -d)"
trap 'rm -rf "$results"' EXIT

# bun test's default file names, from the git index so the list is the same everywhere.
git ls-files -z -- '*.test.ts' '*.test.tsx' '*.test.js' '*.test.jsx' '*.test.mjs' \
  '*_test.ts' '*_test.tsx' '*.spec.ts' '*.spec.tsx' '*_spec.ts' '*_spec.tsx' > "$results/files"
if [ -n "${CMUX_WEB_TEST_FILES:-}" ]; then
  python3 - "$results/files" <<'PY'
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
listed = [item.decode() for item in path.read_bytes().split(b"\0") if item]
wanted = [line.strip() for line in os.environ["CMUX_WEB_TEST_FILES"].splitlines() if line.strip()]
missing = [name for name in wanted if name not in listed]
if missing:
    sys.exit("error: CMUX_WEB_TEST_FILES names files that are not webviews test files: " + ", ".join(missing))
keep = [name for name in listed if name in set(wanted)]
path.write_bytes(b"".join(name.encode() + b"\0" for name in keep))
PY
fi
shard="${CMUX_WEB_TEST_SHARD:-}"
shard_count="${CMUX_WEB_TEST_SHARD_COUNT:-}"
if [ -n "$shard" ] || [ -n "$shard_count" ]; then
  if [[ ! "$shard" =~ ^[1-9][0-9]*$ || ! "$shard_count" =~ ^[1-9][0-9]*$ || "$shard" -gt "$shard_count" ]]; then
    echo "error: CMUX_WEB_TEST_SHARD and CMUX_WEB_TEST_SHARD_COUNT must be a valid one-based shard" >&2
    exit 2
  fi
  python3 - "$results/files" "$shard" "$shard_count" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
shard = int(sys.argv[2])
count = int(sys.argv[3])
files = [item for item in path.read_bytes().split(b"\0") if item]
selected = [item for index, item in enumerate(files) if index % count == shard - 1]
path.write_bytes(b"\0".join(selected) + (b"\0" if selected else b""))
PY
fi
count="$(tr -cd '\0' < "$results/files" | wc -c | tr -d ' ')"
if [ "$count" -eq 0 ]; then
  echo "error: no webviews test files found under $PWD${shard:+ for shard $shard/$shard_count}" >&2
  exit 1
fi
# Two dev servers at once (composer-mention, composer-send-stop) optimize dependencies into the
# same node_modules/.vite, and each loses files the other wrote. `"dev",` is the argument a file
# passes when it spawns `vp dev` itself, `configFile: …` one that calls createServer. `--null`, not `-Z`: BSD grep reads -Z as decompress.
dev_servers='vite\.config\.(acpmux-pane\.mjs|gallery-dev\.ts)|"dev",|configFile: path\.join\(webviews, "vite\.config'
xargs -0 grep -lE --null -- "$dev_servers" < "$results/files" > "$results/serial" || true
serial="$(tr -cd '\0' < "$results/serial" | wc -c | tr -d ' ')"
xargs -0 grep -LE --null -- "$dev_servers" < "$results/files" > "$results/parallel" || true
# A quarter of the jobs: each dev server file runs a Vite server and a browser, and at jobs / 2 the
# 8-core runner was CPU bound (no faster per file) and frame-budget plays (instructions-notice)
# and attach timing (agent-pane-seen) failed.
dev_jobs="${CMUX_WEB_TEST_DEV_JOBS:-$((jobs > 3 ? jobs / 4 : 1))}"
shard_note=""
if [ -n "$shard" ]; then shard_note=", shard $shard/$shard_count"; fi
echo "running $count webviews test files${shard_note}, $jobs at a time ($serial dev server files after, $dev_jobs at a time), ${timeout_seconds}s each"
: > "$results/summary"
xargs -0 -P "$jobs" -I{} bash "$self" --one {} "$results" "$timeout_seconds" < "$results/parallel"

# vite_config FILE: the Vite config whose dependency cache FILE's dev server fills.
vite_config() {
  if grep -q 'vite\.config\.acpmux-pane\.mjs' "$1"; then echo pane
  elif grep -q 'vite\.config\.gallery-dev\.ts' "$1"; then echo gallery
  elif grep -q 'vite\.config\.settings-page\.mjs' "$1"; then echo settings
  else echo default
  fi
}
# One file per config warms its cache, alone; the others wait for it. A warming file that fails
# hands warming to the config's next file, on a fresh cache: one red pane file once sent every
# other pane file one at a time onto a cold cache, 7 minutes of a 13-minute shard (job 118973285057).
warm_attempts="${CMUX_WEB_TEST_WARM_ATTEMPTS:-3}"
[[ "$warm_attempts" =~ ^[1-9][0-9]*$ ]] || warm_attempts=3
vite="$results/vite"
: > "$results/warmed"
: > "$results/warm-tries"
: > "$results/dev-rest"
while IFS= read -r -d '' file; do
  config="$(vite_config "$file")"
  tried="$(grep -cxF "$config" "$results/warm-tries" || true)"
  if grep -q "^$config " "$results/warmed" || [ "$tried" -ge "$warm_attempts" ]; then
    printf '%s\0%s\0' "$config" "$file" >> "$results/dev-rest"
    continue
  fi
  echo "$config" >> "$results/warm-tries"
  seed="$vite/seed-$config-$((tried + 1))"
  bash "$self" --one "$file" "$results" "$timeout_seconds" "$seed"
  if grep -qxF "PASS $file $results/$(printf '%s' "$file" | tr '/' '_').log" "$results/summary"; then
    printf '%s %s\n' "$config" "$seed" >> "$results/warmed"
  else
    rm -rf "$seed" || true
  fi
done < "$results/serial"
# The rest copy their config's warm cache and run at once; a config no file warmed has no
# trustworthy cache, so its files run one at a time, each on a cold cache of its own.
: > "$results/dev-warm"
: > "$results/dev-cold"
index=0
while IFS= read -r -d '' config && IFS= read -r -d '' file; do
  index=$((index + 1))
  seed="$(sed -n "s/^$config //p" "$results/warmed")"
  if [ -n "$seed" ]; then
    printf '%s\0%s\0%s\0' "$file" "$vite/$index" "$seed" >> "$results/dev-warm"
  else
    printf '%s\0%s\0%s\0' "$file" "$vite/$index" "$vite/none" >> "$results/dev-cold"
  fi
done < "$results/dev-rest"
# Without input, xargs would run the command once with no file (BSD xargs has no -r).
if [ -s "$results/dev-warm" ]; then
  xargs -0 -n 3 -P "$dev_jobs" bash "$self" --one-cached "$results" "$timeout_seconds" < "$results/dev-warm"
fi
if [ -s "$results/dev-cold" ]; then
  xargs -0 -n 3 -P 1 bash "$self" --one-cached "$results" "$timeout_seconds" < "$results/dev-cold"
fi

# Retry failed files once, alone, so a file that only lost a race for the CPU
# with its neighbours gets a verdict of its own. Its first log is kept beside the retry's.
retries="${CMUX_WEB_TEST_RETRIES:-60}"
[[ "$retries" =~ ^[0-9]+$ ]] || retries=60
first="$results/first-summary"
mv "$results/summary" "$first"
: > "$results/summary"
retried=0
retry_budget="${CMUX_WEB_TEST_RETRY_BUDGET:-120}"
[[ "$retry_budget" =~ ^[0-9]+$ ]] || retry_budget=120
retry_started=$SECONDS
: > "$results/retry-passed"
while read -r result file log; do
  if [ "$result" = PASS ] || [ "$result" = TIMEOUT ] || [ "$retried" -ge "$retries" ]; then
    printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
    continue
  fi
  normal_limit="$(file_limit "$file" "$timeout_seconds")"
  remaining=$((retry_budget - (SECONDS - retry_started)))
  if [ "$remaining" -le 0 ]; then
    echo "retry budget exhausted: keeping $result $file"
    printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
    continue
  fi
  retry_limit="$normal_limit"
  if [ "$remaining" -lt "$retry_limit" ]; then retry_limit="$remaining"; fi
  echo "RETRY $file (remaining budget ${remaining}s, hard limit ${retry_limit}s)"
  retried=$((retried + 1))
  mv "$log" "$log.first"
  cache=""
  if tr '\0' '\n' < "$results/serial" | grep -qxF -- "$file"; then cache="$vite/retry-$retried"; fi
  CMUX_WEB_TEST_MAX_FILE_TIMEOUT="$retry_limit" bash "$self" --one "$file" "$results" "$timeout_seconds" "$cache" < /dev/null
  if [ -n "$cache" ]; then rm -rf "$cache" || true; fi
  if [ "$retry_limit" -lt "$normal_limit" ] && grep -qxF "TIMEOUT $file $log" "$results/summary"; then
    # An incomplete retry is not a full-file timeout: keep the first run's actual named
    # failure. Otherwise an old base assertion would become a new file-level head red.
    echo "retry budget exhausted during $file; retaining its first failure"
    while read -r saved_result saved_file saved_log; do
      if [ "$saved_file" = "$file" ]; then saved_result=FAIL; fi
      printf '%s %s %s\n' "$saved_result" "$saved_file" "$saved_log"
    done < "$results/summary" > "$results/adjusted-summary"
    mv "$results/adjusted-summary" "$results/summary"
    { echo "--- retry stopped at shared budget ---"; cat "$log"; echo "--- first failure retained ---"; cat "$log.first"; } > "$log.both"
    mv "$log.both" "$log"
  elif grep -qxF "PASS $file $log" "$results/summary"; then
    echo "$file (first run: $result)" >> "$results/retry-passed"
  else
    { echo "--- first run: $result ---"; cat "$log.first"; echo "--- retry, alone ---"; cat "$log"; } > "$log.both"
    mv "$log.both" "$log"
  fi
done < "$first"

# Keep complete attempts in the existing head-results artifact directory. This runs before the
# parser and final display, so raw files remain available even when a named failure is enormous.
if [ -n "${CMUX_WEB_TEST_RAW_LOG_DIR:-}" ]; then
  mkdir -p "$CMUX_WEB_TEST_RAW_LOG_DIR"
  for log in "$results"/*.log "$results"/*.log.first; do
    [ -f "$log" ] || continue
    cp "$log" "$CMUX_WEB_TEST_RAW_LOG_DIR/$(basename "$log")"
  done
  for summary in "$results"/summary "$results"/first-summary; do
    [ -f "$summary" ] || continue
    cp "$summary" "$CMUX_WEB_TEST_RAW_LOG_DIR/$(basename "$summary")"
  done
fi

failed=0
while read -r result file log; do
  # A passing file's workflow annotations (prScope.ts warns about base-branch findings) still reach the run.
  if [ "$result" = PASS ]; then
    annotations="$results/$(basename "$log").annotations"
    grep -E '^::(warning|notice)( |::)' "$log" > "$annotations" || true
    if [ -s "$annotations" ]; then print_bounded_log "$annotations"; fi
    continue
  fi
  failed=$((failed + 1))
  echo "::group::$result $file"
  print_bounded_log "$log"
  echo "::endgroup::"
done < <(sort -k2 "$results/summary")

# Per-test results for webviews-tests-new-reds.sh, which compares them with the base's.
if [ -n "${CMUX_WEB_TEST_RESULTS:-}" ]; then
  python3 "$(dirname "$self")/webviews_test_results.py" "$results/summary" "$CMUX_WEB_TEST_RESULTS"
fi

echo "### webviews tests: $count files, $failed failed or timed out ($retried retried alone, $(wc -l < "$results/retry-passed" | tr -d ' ') passed alone)"
if [ -s "$results/retry-passed" ]; then
  echo "passed only when run alone (failed or timed out beside other files):"
  sed 's/^/  /' "$results/retry-passed"
fi
while read -r result file _; do
  [ "$result" = PASS ] || echo "$result $file (limit $(file_limit "$file" "$timeout_seconds")s)"
done < <(sort -k2 "$results/summary")
[ "$failed" -eq 0 ]
