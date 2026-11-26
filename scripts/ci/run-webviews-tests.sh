#!/usr/bin/env bash
# tooling-steps runs: scripts/ci/run-webviews-tests.sh scripts/ci/webviews_*.py
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
# Serial retries of failed files stop after CMUX_WEB_TEST_RETRY_BUDGET seconds (default 120),
# including an in-flight retry; unretried failures stay red.
# A timed-out file gets its own single retry, alone, at its full limit, outside that budget and
# outside the CMUX_WEB_TEST_RETRIES count: one slow file must not eat the failed files' retries, nor
# they its (#27130's shard 4: two files timed out at 120 s beside 15 others, never retried, and
# both passed alone in 61 s and 22 s on the base replay). Timeout retries have their own budget,
# CMUX_WEB_TEST_TIMEOUT_RETRY_BUDGET seconds when set; one starts only when its whole limit fits in
# what is left. Unset (the default), every timed-out file gets its retry: a fixed 240 s fit two
# retries of 21 s and 42 s and a third of 63 s, then kept 7 of 12 timed-out files red on a
# 32-wide shard (job 123436110075), and each of those passed alone on the base replay. A retry that times out again
# stays a TIMEOUT (never a pass, and never a named failure a base could share); one that passes
# is listed as passing alone. CMUX_WEB_TEST_RETRIES=0 turns these retries off too.
# CMUX_WEB_TEST_RETRY_DEADLINE: optional seconds after the runner starts by which every retry must
# be done. A timeout retry starts only when its whole limit fits before it, and a failed file's
# retry is cut at it, so the step stays inside its job's timeout-minutes however many files
# timed out.
# CMUX_WEB_TEST_RETRY_WALL: optional seconds the whole retry phase may take after the first pass ends; it pulls the
# retry deadline in to then when that is earlier. The job-derived deadline alone let retries fill a 90 min shard: on a
# base with 36-84 red webview files a shard, full-suite pull request runs spent 36-40 min retrying after a 39-44 min
# first pass and clustered at ~4,800 s (jobs 138640454439, 138534278453, 138786846480, 138936477461; 3 of 26 alone
# retries passed, so the breaker never tripped). A red left unretried goes to react-apps-base-check, which replays it on
# the base and re-runs alone on the head any red it would charge to the change, so the verdict does not move.
# CMUX_WEB_TEST_STOP_AT: optional epoch second after which no file starts; a file still running then is stopped at it
# and, like a file that never started, left out of the results (named NOT RUN, and the run fails). For a job whose
# timeout-minutes are shorter than its files can take: react-apps-base-early runs files red on the base, which fail at
# their long limits (accent-glass-invariants 7.7 min, control-contrast 9.9 min) one at a time while each Vite config
# warms, and 41 of 73 of its runs (11-21 09:30-16:50Z) were cancelled at the job limit still testing, with no verdict
# at all (jobs 136500566506, 136741984962, 136800345011). With it the step ends in time and keeps what it finished.
# CMUX_WEB_TEST_BASE_REDS: optional JSON (webviews_test_history.py known-reds: the names red on the base's
# newest recorded push). A pull request's shard sets it: a failed or timed-out file whose every first-run red
# is in it gets no alone retry, and its first run goes to react-apps-base-check, which judges every red as
# before (and re-runs alone on the head any red it would charge to the change). Its retry could only pass a
# test the base fails too: shard 2 of run 43374261361 spent 10 of its 25 min retrying three such files, one
# a 600 s timeout. A missing or unreadable file skips nothing, so every red file is retried as before.
# CMUX_WEB_TEST_JOBS: files run at once (default: CMUX_CI_CPU_BUDGET, the cores a fleet
# worker granted the step, else the CPU count).
# CMUX_WEB_TEST_SIZED_FOR_VCPU: optional vCPU count the widths were set for; a runner with fewer cores
# runs at that share of them and the shard split keeps the declared widths (see below).
# CMUX_WEB_TEST_BROWSER_JOBS: plain files that drive a real browser at once (default a quarter of the
# jobs); they run beside the other plain files, which take the rest of the jobs.
# CMUX_WEB_TEST_FILES: optional newline-separated test files (relative to webviews/) to run instead
# of every file, for focused runs (scripts/ci/car_guards.py). A name the file list does not hold
# is an error, so a stale selection never passes by running nothing.
# Arguments (`bun run test [PATH|FILTER]...` from webviews/, which runs this script): each is a test
# file or a directory (relative to where you run it), or else a substring of test file names, as a
# bare `bun test FILTER` takes it. They select files the way CMUX_WEB_TEST_FILES does, still one
# process per file: a single `bun test` over many files leaks globals from file to file and fails
# tests that pass alone and in CI. An argument that selects no test file is an error.
# CMUX_WEB_TEST_RESULTS: optional file to write each file's and failed test's result into
# (webviews_test_results.py), for webviews-tests-new-reds.sh.
# CMUX_WEB_TEST_RAW_LOG_DIR: optional artifact directory for complete per-attempt logs. The public
# step output is bounded, while this directory keeps the raw evidence for diagnosis and parsing.
# CMUX_WEB_TEST_SHARD / CMUX_WEB_TEST_SHARD_COUNT: optional one-based shard selector (for example
# 1/2 or 2/2). Sharding happens after the git-index file list is built, so every shard keeps the
# same per-file process and Vite-cache isolation rules while covering a disjoint deterministic set.
# Files with a recorded duration split by load, longest first; the rest by a stable hash of their
# path, so a new file moves only itself (webviews_test_shards.py). CMUX_WEB_TEST_SHARD_HEAD_START
# (`SHARD:SECONDS,...`, read by the split) gives a shard whose job does other work first that much less.
# CMUX_WEB_TEST_DURATIONS: optional JSON manifest {file: seconds} of earlier runs. Every shard of one
# run must read the same copy. With it, each Vite config warms on its shortest file and the files
# start longest first, so a long file never runs last alone.
# CMUX_WEB_TEST_DURATIONS_OUT: optional file to write each file's first-run seconds into, as JSON,
# for the next manifest (webviews_test_shards.py merge).
# CMUX_WEB_TEST_LIST_ONLY: 1 prints the files this run (this shard) would test, one a line, and runs none.
#
# Files that start a Vite dev server run after the rest: the agent pane and gallery configs
# (vite.config.acpmux-pane.mjs, vite.config.gallery-dev.ts), and files that spawn `vp dev`
# themselves (editor-page, ui-a11y, settings-scroll). On one node_modules/.vite two at once lose
# each other's optimized files, and three starting cold at once (agent-history,
# agent-pane-peer-chat, chat-find) stall in the optimizer's first bundle, even with a cache each;
# editor-page timed out the same way beside ui-a11y and text-field-focus. So one file per Vite
# config runs first, alone, and warms that config's cache (CMUX_VITE_CACHE_DIR, which the dev
# configs read); the rest then run CMUX_WEB_TEST_DEV_JOBS at once (default a quarter of the jobs), each
# on its own copy of its config's warm cache. A warming file that fails with no committed dependency
# cache (deps/_metadata.json) leaves no trustworthy cache, so the config's next file warms a fresh one, up to CMUX_WEB_TEST_WARM_ATTEMPTS files
# (default 3); a config none of them warms keeps its other files one at a time on a cold cache each.
# Every file of the run shares one cache of the React Compiler's output (CMUX_VITE_TRANSFORM_CACHE,
# a folder of the run's own unless set; webviews/reactCompiler.mjs), keyed by each module's exact code.
#
# Run from webviews/ (CI, local dev) it tests what is there. Run from anywhere else in the
# checkout (a cmux-ci step starts at the checkout root) it first makes the web bundles
# current (scripts/ci/ensure-web-bundles.sh, which also provides the pinned bun), runs
# `bun install --frozen-lockfile` in webviews/, and then tests webviews/ only.
#
# Runs the same way on Linux CI and on a Mac (cmux-lawrence-2, nx-remote jobs): a full
# single-process `bun test` there fails about 630 tests after one slow test leaves a React
# act() scope open for every later file. Macs have no coreutils `timeout`, so the worker
# bounds each file through scripts/ci/timeout.sh (gtimeout, else a perl watchdog, same exit codes).
set -euo pipefail

# run_with_timeout SECONDS COMMAND...: exit 124 when SECONDS pass, as `timeout -k 10` does. scripts/ci/timeout.sh
# runs the command in its own process group, so the TERM (and the KILL 10 s later) reach everything bun started.
ci_timeout="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/timeout.sh"
run_with_timeout() {
  bash "$ci_timeout" --kill-after=10 "$@"
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
  started=$SECONDS
  # CMUX_WEB_TEST_STOP_AT: past it the file does not start; before it, its limit is cut to what is left, and a file the
  # cut stopped gets no verdict (a TIMEOUT there would be the deadline's, not the file's).
  stop_at="${CMUX_WEB_TEST_STOP_AT:-}" cut=0
  if [[ "$stop_at" =~ ^[1-9][0-9]*$ ]]; then
    left=$((stop_at - $(date +%s)))
    if [ "$left" -lt 1 ]; then
      echo "NOT RUN $file: past CMUX_WEB_TEST_STOP_AT"
      printf '%s\n' "$file" >> "$results/not-run"
      exit 0
    fi
    if [ "$left" -lt "$timeout_seconds" ]; then timeout_seconds="$left" cut=1; fi
  fi
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
  if [ "$result" = TIMEOUT ] && [ "$cut" -eq 1 ]; then
    echo "NOT RUN $file: stopped at CMUX_WEB_TEST_STOP_AT after $((SECONDS - started))s"
    printf '%s\n' "$file" >> "$results/not-run"
    exit 0
  fi
  printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
  # CMUX_WEB_TEST_PASSED_OUT: each file that passes, as it passes, so a run a newer head cancels still leaves its passes
  # to that head's shard (ci-web.yml reuses those its change cannot reach).
  if [ "$result" = PASS ] && [ -n "${CMUX_WEB_TEST_PASSED_OUT:-}" ]; then printf '%s\n' "$file" >> "$CMUX_WEB_TEST_PASSED_OUT"; fi
  # Each run's wall seconds; a retry's line comes after its first run's, which the manifest keeps.
  printf '%s %s\n' "$((SECONDS - started))" "$file" >> "$results/durations"
  # Keep the named verdict immediate; the complete log is emitted once in the final summary below.
  echo "$result $file (raw log retained for the final bounded summary)"
  exit 0
fi

self="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
shards_py="$(dirname "$self")/webviews_test_shards.py"
# Selection arguments, made absolute when they name a path, so the cd below keeps their meaning.
selection=()
for arg in "$@"; do
  case "$arg" in
    -*)
      echo "error: run-webviews-tests.sh takes test files, directories or name filters, not bun options ($arg);" \
        "for bun options on one file, run \`bun test FILE $arg\`" >&2
      exit 2
      ;;
  esac
  if [ -e "$arg" ]; then
    selection+=("$(cd "$(dirname "$arg")" && pwd -P)/$(basename "$arg")")
  else
    selection+=("$arg")
  fi
done
case "$(git rev-parse --show-prefix)" in
  webviews/*) ;;
  *)
    cd "$(git rev-parse --show-toplevel)"
    bash scripts/ci/ensure-web-bundles.sh
    # ensure-web-bundles.sh puts the pinned bun on its own PATH only: use the same copy.
    bun_pin="$(python3 -I scripts/webviews_bun_version.py webviews/package.json)"
    bun_dir="${CMUX_CI_CACHE_DIR:-$HOME/Library/Caches/cmux-ci}/tools/bun-$bun_pin/bin"
    if [ "$(bun --version 2>/dev/null || true)" != "$bun_pin" ] && [ -x "$bun_dir/bun" ]; then
      export PATH="$bun_dir:$PATH"
    fi
    cd webviews
    bun install --frozen-lockfile
    ;;
esac
# No Playwright on Macs (Lawrence, 2026-11-02): no Playwright, Puppeteer or downloaded Chromium on his
# Mac or on a fleet Mac. The engines Playwright downloads are an old Chromium (the headless shell) and
# Playwright turns the Chromium sandbox off, and this install had left about 4.6 GB of them on 10 fleet
# Macs. So a Mac outside GitHub Actions never installs an engine: it runs the lane without the browser
# files, which then skip as they do without CMUX_BROWSER_TESTS (requireBrowserLane.ts). Playwright
# looks for engines in a folder that cannot hold one, so an engine an earlier run left on the Mac never
# launches either (a file that probes its engine skips when the launch fails). The browser lane runs
# in CI or on a Linux cloud VM.
# Elsewhere (Linux), a cmux-ci step that runs the browser lane (CMUX_BROWSER_TESTS=1) needs the
# engines PR CI installs; without them the lane only ever ran in PR CI. They live in the step
# cache, one directory per Playwright version, so a host downloads each once. GitHub Actions
# installs its own (cmux-next-web-bundles.yml).
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "$(uname -s)" = Darwin ]; then
  if [ "${CMUX_BROWSER_TESTS:-}" = 1 ]; then
    echo "browser lane: not on a Mac (Lawrence's rule: no Playwright on Macs); run it in CI or on a cloud VM"
  fi
  unset CMUX_BROWSER_TESTS
  export PLAYWRIGHT_BROWSERS_PATH=/var/empty/cmux-no-playwright-on-macs
elif [ "${CMUX_BROWSER_TESTS:-}" = 1 ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
  playwright_version="$(python3 -c 'import json; print(json.load(open("package.json"))["devDependencies"]["playwright"])' 2> /dev/null || echo unknown)"
  export PLAYWRIGHT_BROWSERS_PATH="${CMUX_CI_CACHE_DIR:-$HOME/Library/Caches/cmux-ci}/playwright-$playwright_version"
  ./node_modules/.bin/playwright install webkit
  # Chromium is the system Google Chrome (test/preload.ts), never Playwright's bundled build, which
  # lacks recent security fixes and runs unsandboxed. A host without a current Chrome skips Chromium.
  chrome_out="$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure-system-chrome.sh" --optional)"
  printf '%s\n' "$chrome_out"
  shell_line="$(printf '%s\n' "$chrome_out" | grep '^CMUX_CHROME_HEADLESS_SHELL=' | tail -1 || true)"
  [ -n "$shell_line" ] && export CMUX_CHROME_HEADLESS_SHELL="${shell_line#CMUX_CHROME_HEADLESS_SHELL=}"
fi

timeout_seconds="${CMUX_WEB_TEST_FILE_TIMEOUT:-120}"
default_jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
if [[ "${CMUX_CI_CPU_BUDGET:-}" =~ ^[1-9][0-9]*$ ]]; then
  default_jobs="$CMUX_CI_CPU_BUDGET"
fi
jobs="${CMUX_WEB_TEST_JOBS:-$default_jobs}"
results="$(mktemp -d)"
trap 'rm -rf "$results"' EXIT
# One React Compiler output cache for every file of this run (webviews/reactCompiler.mjs): without it
# each dev server file compiled the agent pane again in its own Vite (App.tsx alone took 33 s), and
# that start put dev server files past their limits on a busy shard.
export CMUX_VITE_TRANSFORM_CACHE="${CMUX_VITE_TRANSFORM_CACHE:-$results/vite-transforms}"

# bun test's default file names, from the git index so the list is the same everywhere. Outside
# GitHub Actions (`bun run test` on a checkout, a fleet step) untracked files that git does not
# ignore count too, so a new test runs before it is staged, as a bare `bun test` would run it.
others=(--others --exclude-standard)
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  others=()
fi
git ls-files -z --cached ${others[@]+"${others[@]}"} -- '*.test.ts' '*.test.tsx' '*.test.js' '*.test.jsx' '*.test.mjs' \
  '*_test.ts' '*_test.tsx' '*.spec.ts' '*.spec.tsx' '*_spec.ts' '*_spec.tsx' > "$results/files"
if [ -n "${CMUX_WEB_TEST_FILES:-}" ] || [ "${#selection[@]}" -gt 0 ]; then
  python3 - "$results/files" ${selection[@]+"${selection[@]}"} <<'PY'
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
listed = [item.decode() for item in path.read_bytes().split(b"\0") if item]
wanted = [line.strip() for line in os.environ.get("CMUX_WEB_TEST_FILES", "").splitlines() if line.strip()]
missing = [name for name in wanted if name not in listed]
if missing:
    sys.exit("error: CMUX_WEB_TEST_FILES names files that are not webviews test files: " + ", ".join(missing))
selected = set(wanted)
unmatched = []
for arg in sys.argv[2:]:
    if os.path.isabs(arg):
        # A file or directory: the test files at or under it.
        rel = os.path.relpath(arg)
        if rel == ".":
            found = listed
        else:
            found = [name for name in listed if name == rel or name.startswith(rel.rstrip("/") + "/")]
    else:
        # Not a path: a substring of the file names, as `bun test FILTER` matches them.
        found = [name for name in listed if arg in name]
    if not found:
        unmatched.append(arg)
    selected.update(found)
if unmatched:
    sys.exit("error: no webviews test file matches " + ", ".join(unmatched))
keep = [name for name in listed if name in selected]
path.write_bytes(b"".join(name.encode() + b"\0" for name in keep))
PY
fi
# A quarter of the jobs: each dev server file runs a Vite server and a browser, and at jobs / 2 the
# 8-core runner was CPU bound (no faster per file) and frame-budget plays (instructions-notice)
# and attach timing (agent-pane-seen) failed.
dev_jobs="${CMUX_WEB_TEST_DEV_JOBS:-$((jobs > 3 ? jobs / 4 : 1))}"
# The plain files that drive a real browser (they import playwright or wait on requireBrowserLane)
# run in a pool of their own, CMUX_WEB_TEST_BROWSER_JOBS wide (default a quarter of the jobs, as
# for the dev server files, which run a browser too), beside the other plain files on the rest of
# the jobs. Started 32 at once with the jsdom files, the longest-first order put 29 browser files
# (each launching Chromium and WebKit) on one 32 vCPU shard together: eight timed out at 120 s and
# frame-timing plays read 71 ms frames and one painted frame of three (agent-pane-wheel-glide), and
# every one of them passed when the base replay ran it alone (react-apps-check 1/4, job
# 123385326827, against react-apps-base-check job 123394574731). The first-run failures then ate
# the retry budget, so a later failed file's retry got 3 s. At one job (the base replay) the two
# pools run one after the other, so nothing runs beside anything.
browser_files='from "playwright"|import\("playwright"\)|requireBrowserLane\('
browser_jobs="${CMUX_WEB_TEST_BROWSER_JOBS:-$((jobs > 3 ? jobs / 4 : 1))}"
[[ "$browser_jobs" =~ ^[1-9][0-9]*$ ]] || browser_jobs=1
if [ "$browser_jobs" -gt "$jobs" ]; then browser_jobs="$jobs"; fi
plain_jobs=$((jobs - browser_jobs))
# The split weighs each file by the pool it runs in, so it gets these widths, but only widths the
# workflow set (CMUX_WEB_TEST_JOBS): widths from this runner's cores could differ between shards,
# and shards that split differently skip or repeat files. Unset, the split keeps its own widths.
# At one job there is no plain lane beside the browser one (the pools run in turn); the split then
# counts one plain lane, which only an unsharded run (the base replay) ever has.
split_widths=""
if [[ "${CMUX_WEB_TEST_JOBS:-}" =~ ^[1-9][0-9]*$ && "$browser_jobs$dev_jobs" =~ ^[0-9]+$ ]]; then split_widths="$((plain_jobs > 0 ? plain_jobs : 1)),$browser_jobs,$dev_jobs"; fi
# CMUX_WEB_TEST_SIZED_FOR_VCPU: the vCPU count the widths above were set for (the workflow's declared
# runner size). A runner with fewer cores (CMUX_CI_CPU_BUDGET, else the CPU count) runs its files at that
# share of each width, at least 1; the split above keeps the declared widths, so every shard still picks
# the same files. The 16 vCPU shards' 8 jobs on a 2 vCPU runner (a pool that held only small sizes) ran
# every shard of run 44249075431 into its 40 min timeout.
sized_for="${CMUX_WEB_TEST_SIZED_FOR_VCPU:-}"
if [[ "$sized_for" =~ ^[1-9][0-9]*$ && "$default_jobs" =~ ^[1-9][0-9]*$ ]] && [ "$default_jobs" -lt "$sized_for" ]; then
  fit_width() { local width=$(( $1 * default_jobs / sized_for )); echo $(( width > 0 ? width : 1 )); }
  jobs="$(fit_width "$jobs")" dev_jobs="$(fit_width "$dev_jobs")" browser_jobs="$(fit_width "$browser_jobs")"
  if [ "$browser_jobs" -gt "$jobs" ]; then browser_jobs="$jobs"; fi
  plain_jobs=$((jobs - browser_jobs))
  echo "this runner has $default_jobs of the $sized_for vCPU these widths are for: $jobs files at a time, $dev_jobs dev server files"
fi
shard="${CMUX_WEB_TEST_SHARD:-}"
shard_count="${CMUX_WEB_TEST_SHARD_COUNT:-}"
durations="${CMUX_WEB_TEST_DURATIONS:-/dev/null}"
# Two dev servers at once (composer-mention, composer-send-stop) optimize dependencies into the
# same node_modules/.vite, and each loses files the other wrote. `"dev",` is the argument a file
# passes when it spawns `vp dev` itself, `configFile: …` one that calls createServer. `--null`, not `-Z`: BSD grep reads -Z as decompress.
dev_servers='vite\.config\.(acpmux-pane\.mjs|gallery-dev\.ts)|"dev",|configFile: path\.join\(webviews, "vite\.config'
if [ -n "$shard" ] || [ -n "$shard_count" ]; then
  if [[ ! "$shard" =~ ^[1-9][0-9]*$ || ! "$shard_count" =~ ^[1-9][0-9]*$ || "$shard" -gt "$shard_count" ]]; then
    echo "error: CMUX_WEB_TEST_SHARD and CMUX_WEB_TEST_SHARD_COUNT must be a valid one-based shard" >&2
    exit 2
  fi
  # The split weighs dev-server files by how few run at once, so it needs them before it splits.
  xargs -0 grep -lE --null -- "$dev_servers" < "$results/files" > "$results/all-serial" || true
  python3 "$shards_py" assign "$results/files" "$results/all-serial" "$durations" "$shard" "$shard_count" \
    ${split_widths:+"$split_widths"} > "$results/shard-files"
  mv "$results/shard-files" "$results/files"
fi
# CMUX_WEB_TEST_REUSED: a file of test files (one a line) that passed at the pull request's previous head and that no
# change since can reach (ci-web.yml reads them with webviews_affected.py). This run drops them as passed, after the
# split, so every shard still picks the same files, and lists them in CMUX_WEB_TEST_PASSED_OUT for the head after it.
: > "$results/reused"
if [ -n "${CMUX_WEB_TEST_REUSED:-}" ] && [ -s "$CMUX_WEB_TEST_REUSED" ]; then
  python3 - "$results/files" "$CMUX_WEB_TEST_REUSED" "$results/reused" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
listed = [item.decode() for item in path.read_bytes().split(b"\0") if item]
reusable = {line.strip() for line in pathlib.Path(sys.argv[2]).read_text().splitlines() if line.strip()}
path.write_bytes(b"".join(name.encode() + b"\0" for name in listed if name not in reusable))
pathlib.Path(sys.argv[3]).write_text("".join(name + "\n" for name in listed if name in reusable))
PY
  if [ -s "$results/reused" ]; then
    echo "passed at the previous head, and no change since reaches them, so not run again: $(grep -c . "$results/reused")"
    sed 's/^/  REUSED /' "$results/reused"
    if [ -n "${CMUX_WEB_TEST_PASSED_OUT:-}" ]; then cat "$results/reused" >> "$CMUX_WEB_TEST_PASSED_OUT"; fi
  fi
fi
count="$(tr -cd '\0' < "$results/files" | wc -c | tr -d ' ')"
if [ "$count" -eq 0 ] && [ -s "$results/reused" ] && [ "${CMUX_WEB_TEST_LIST_ONLY:-}" != 1 ]; then
  echo "### webviews tests: 0 files; all $(grep -c . "$results/reused") of this shard passed at the previous head"
  if [ -n "${CMUX_WEB_TEST_RESULTS:-}" ]; then
    : > "$results/summary"
    python3 "$(dirname "$self")/webviews_test_results.py" "$results/summary" "$CMUX_WEB_TEST_RESULTS"
  fi
  exit 0
fi
if [ "$count" -eq 0 ]; then
  echo "error: no webviews test files found under $PWD${shard:+ for shard $shard/$shard_count}" >&2
  exit 1
fi
# CMUX_WEB_TEST_LIST_ONLY=1: print this shard's files, one a line, and run nothing (webviews_pr_shards.py
# picks a pull request's shards from the very split each shard makes here).
if [ "${CMUX_WEB_TEST_LIST_ONLY:-}" = 1 ]; then
  tr '\0' '\n' < "$results/files"
  exit 0
fi
xargs -0 grep -lE --null -- "$dev_servers" < "$results/files" > "$results/serial" || true
serial="$(tr -cd '\0' < "$results/serial" | wc -c | tr -d ' ')"
xargs -0 grep -LE --null -- "$dev_servers" < "$results/files" > "$results/parallel" || true
# With recorded durations: plain files start longest first, and each Vite config warms on its
# shortest file (accent-glass-invariants warmed alone for 549 s of an 18.6 min shard, run 40815704587).
if [ "$durations" != /dev/null ]; then
  for list in parallel:desc serial:asc; do
    python3 "$shards_py" order "$results/${list%%:*}" "$durations" "${list#*:}" > "$results/ordered"
    mv "$results/ordered" "$results/${list%%:*}"
  done
fi
# Both lists keep the parallel list's order (longest first with durations): grep prints in input order.
: > "$results/browser"
: > "$results/plain"
if [ -s "$results/parallel" ]; then
  xargs -0 grep -lE --null -- "$browser_files" < "$results/parallel" > "$results/browser" || true
  xargs -0 grep -LE --null -- "$browser_files" < "$results/parallel" > "$results/plain" || true
fi
browser="$(tr -cd '\0' < "$results/browser" | wc -c | tr -d ' ')"
shard_note=""
if [ -n "$shard" ]; then shard_note=", shard $shard/$shard_count"; fi
if [ "$plain_jobs" -ge 1 ]; then pool_note="$plain_jobs at a time, beside $browser browser files $browser_jobs at a time"
else pool_note="$jobs at a time, then $browser browser files $browser_jobs at a time"; fi
echo "running $count webviews test files${shard_note}, $pool_note ($serial dev server files after, $dev_jobs at a time), ${timeout_seconds}s each"
: > "$results/summary"
: > "$results/not-run"
# warm_transforms: once per run, before the first browser or dev server file, compile the agent pane's
# modules into the run's React Compiler cache (webviews/scripts/warm-react-compiler-cache.mjs, about
# 35 s), so the files that start together read it instead of each compiling App.tsx at once. A base
# without the script, or a warm that fails, leaves each file to compile what it needs, as before.
warm_transforms() {
  [ -e "$results/transforms-warmed" ] && return 0
  : > "$results/transforms-warmed"
  [ -f scripts/warm-react-compiler-cache.mjs ] || return 0
  { [ -s "$results/browser" ] || [ -s "$results/serial" ]; } || return 0
  local limit=300
  if [[ "${CMUX_WEB_TEST_STOP_AT:-}" =~ ^[1-9][0-9]*$ ]]; then
    limit=$((CMUX_WEB_TEST_STOP_AT - $(date +%s)))
    if [ "$limit" -lt 1 ]; then return 0; fi
    if [ "$limit" -gt 300 ]; then limit=300; fi
  fi
  if run_with_timeout "$limit" bun scripts/warm-react-compiler-cache.mjs > "$results/warm-transforms.log" 2>&1 < /dev/null; then
    grep '^warm-react-compiler-cache:' "$results/warm-transforms.log" || true
  else
    echo "warm-react-compiler-cache failed (exit $?); each file compiles its own modules"
    tail -n 20 "$results/warm-transforms.log" || true
  fi
}
# gallery_stages: once per run, when a selected file scans the gallery's stages (accent-glass-invariants,
# control-contrast, gallery-control-surfaces), build the gallery (`bun run gallery:build`, about 60 s on
# 16 cores) and name the folder in CMUX_GALLERY_STAGE_BUILD, which test/support/galleryStageServer.ts
# serves in place of a Vite dev server. Each dev server stage loaded about 650 unbundled modules from
# one Vite thread: 80 stages took 29.3 s pinned to 4 cores and 59.8 s pinned to 2, against 15.4 s from
# the build. CMUX_GALLERY_STAGE_CSS=dev keeps the CSS as the dev server serves it (no Tailwind optimize,
# no CSS minify): the shipped CSS lowers light-dark() and reorders rules, and the scans' baselines were
# read from the dev server's. A build that fails or runs out of time leaves the dev servers, as before.
# A later call (the serial phase, the retries) reuses the folder.
gallery_stage_files='accentGlassInvariants|controlContrast|galleryControlSurfaces'
gallery_stages() {
  local build="$results/gallery-build"
  if [ ! -e "$results/gallery-tried" ]; then
    : > "$results/gallery-tried"
    if grep -q '"gallery:build"' package.json 2> /dev/null && [ -f test/support/galleryStageServer.ts ] &&
      xargs -0 grep -lE -- "$gallery_stage_files" < "$results/files" > /dev/null 2>&1; then
      local limit=600
      if [[ "${CMUX_WEB_TEST_STOP_AT:-}" =~ ^[1-9][0-9]*$ ]]; then
        limit=$((CMUX_WEB_TEST_STOP_AT - $(date +%s)))
        if [ "$limit" -gt 600 ]; then limit=600; fi
      fi
      local started=$SECONDS
      if [ "$limit" -ge 1 ] && CMUX_GALLERY_STAGE_CSS=dev CMUX_GALLERY_OUT_DIR="$build" run_with_timeout "$limit" bun run gallery:build > "$results/gallery-build.log" 2>&1 < /dev/null &&
        [ -f "$build/frame.html" ]; then
        echo "gallery-build: built the gallery stages in $((SECONDS - started))s"
      else
        echo "::warning::gallery-build failed or timed out after $((SECONDS - started))s; the gallery scans use Vite dev servers"
        tail -n 20 "$results/gallery-build.log" 2> /dev/null || true
        rm -rf "$build"
      fi
    fi
  fi
  if [ -f "$build/frame.html" ]; then export CMUX_GALLERY_STAGE_BUILD="$build"; fi
  return 0
}
if [ "$plain_jobs" -ge 1 ] && [ -s "$results/browser" ] && [ -s "$results/plain" ]; then
  # The plain jsdom files start at once; the browser files wait for the warm, beside them.
  { warm_transforms; gallery_stages; xargs -0 -P "$browser_jobs" -I{} bash "$self" --one {} "$results" "$timeout_seconds" < "$results/browser"; } &
  browser_pool=$!
  # A failed plain pool still waits for the browser pool, so no worker outlives the results directory.
  plain_status=0
  xargs -0 -P "$plain_jobs" -I{} bash "$self" --one {} "$results" "$timeout_seconds" < "$results/plain" || plain_status=$?
  wait "$browser_pool"
  [ "$plain_status" -eq 0 ] || exit "$plain_status"
else
  if [ -s "$results/plain" ]; then
    xargs -0 -P "$jobs" -I{} bash "$self" --one {} "$results" "$timeout_seconds" < "$results/plain"
  fi
  if [ -s "$results/browser" ]; then
    warm_transforms
    gallery_stages
    xargs -0 -P "$browser_jobs" -I{} bash "$self" --one {} "$results" "$timeout_seconds" < "$results/browser"
  fi
fi
[ ! -s "$results/serial" ] || warm_transforms
# Builds for the serial files, or picks up the browser pool's build for them and the retries.
gallery_stages

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
  elif [ -s "$seed/deps/_metadata.json" ]; then
    # A red warming file whose dev server committed its optimized dependencies still warmed the cache: Vite
    # optimizes into deps_temp_* and renames it to deps/ only once the bundle is whole, so deps/_metadata.json
    # is a finished cache whatever the test then asserted. Red gallery files (accent-glass-invariants,
    # control-contrast, red on the base too) each took the next warming try alone, 450-900 s apiece, and left
    # the config's other files one at a time: 17.5 of a shard's 51 min ran one file at a time (33 shard logs,
    # 2026-11-21 07:21-08:55Z).
    echo "$config cache warm from $file's dev server (the file itself is red)"
    printf '%s %s\n' "$config" "$seed" >> "$results/warmed"
  else
    rm -rf "$seed" || true
  fi
done < "$results/serial"
# The rest copy their config's warm cache and run at once; a config no file warmed has no
# trustworthy cache, so its files run one at a time, each on a cold cache of its own.
# A file that loads the machine itself declares `// cmux-web-test-alone` (first 20 lines) and runs
# after the others, alone, on its config's cache: agent-pane-attach-huge-files (2 GB uploads,
# about 6 minutes) beside three composer files made them time out and its own typing read 85 ms
# (run 40732464791); alone, as its config's warming file, it passed (run 40721887225).
: > "$results/dev-warm"
: > "$results/dev-cold"
: > "$results/dev-alone"
index=0
while IFS= read -r -d '' config && IFS= read -r -d '' file; do
  index=$((index + 1))
  seed="$(sed -n "s/^$config //p" "$results/warmed")"
  if head -n 20 "$file" 2> /dev/null | grep -qx '// cmux-web-test-alone'; then
    printf '%s\0%s\0%s\0' "$file" "$vite/$index" "${seed:-$vite/none}" >> "$results/dev-alone"
  elif [ -n "$seed" ]; then
    printf '%s\0%s\0%s\0' "$file" "$vite/$index" "$seed" >> "$results/dev-warm"
  else
    printf '%s\0%s\0%s\0' "$file" "$vite/$index" "$vite/none" >> "$results/dev-cold"
  fi
done < "$results/dev-rest"
if [ "$durations" != /dev/null ] && [ -s "$results/dev-warm" ]; then
  python3 "$shards_py" order-triples "$results/dev-warm" "$durations" desc > "$results/ordered"
  mv "$results/ordered" "$results/dev-warm"
fi
# Without input, xargs would run the command once with no file (BSD xargs has no -r).
if [ -s "$results/dev-warm" ]; then
  xargs -0 -n 3 -P "$dev_jobs" bash "$self" --one-cached "$results" "$timeout_seconds" < "$results/dev-warm"
fi
if [ -s "$results/dev-cold" ]; then
  xargs -0 -n 3 -P 1 bash "$self" --one-cached "$results" "$timeout_seconds" < "$results/dev-cold"
fi
if [ -s "$results/dev-alone" ]; then
  xargs -0 -n 3 -P 1 bash "$self" --one-cached "$results" "$timeout_seconds" < "$results/dev-alone"
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
# Unset (the default), every timed-out file gets its retry: there are finitely many, each retry is
# bounded by its own limit, and CMUX_WEB_TEST_RETRY_DEADLINE bounds them all. A budget summed from
# their limits would not do: a retry's kill grace and cache upkeep run past its limit and would
# cost the last file its retry.
timeout_retry_budget="${CMUX_WEB_TEST_TIMEOUT_RETRY_BUDGET:-}"
[[ "$timeout_retry_budget" =~ ^[0-9]+$ ]] || timeout_retry_budget=""
retry_deadline="${CMUX_WEB_TEST_RETRY_DEADLINE:-}"
[[ "$retry_deadline" =~ ^[0-9]+$ ]] || retry_deadline=""
# CMUX_WEB_TEST_RETRY_WALL=S (unset: none): the whole retry phase (pool, alone and timeout retries) ends S seconds
# after the first pass, by moving the retry deadline earlier when it is later. See the header.
retry_wall="${CMUX_WEB_TEST_RETRY_WALL:-}"
[[ "$retry_wall" =~ ^[0-9]+$ ]] || retry_wall=""
if [ -n "$retry_wall" ]; then
  wall_end=$((SECONDS + 10#$retry_wall))
  if [ -z "$retry_deadline" ] || [ "$wall_end" -lt "$retry_deadline" ]; then retry_deadline=$wall_end; fi
fi
# deadline_left: seconds until the retry deadline (a large number when none is set).
deadline_left() {
  if [ -n "$retry_deadline" ]; then echo $((retry_deadline - SECONDS)); else echo 999999; fi
}
timeout_retried=0
timeout_retry_spent=0
: > "$results/retry-passed"
# Each red file whose retry was due but did not run to its end (a budget, the deadline or the retry cap stopped it):
# its log holds only the first run, so webviews_test_results.py must not read that run's tally as the retry's (#34017).
: > "$results/retry-skipped"
: > "$results/base-red"
if [ "$retries" -ne 0 ] && [ -n "${CMUX_WEB_TEST_BASE_REDS:-}" ] && [ -s "$CMUX_WEB_TEST_BASE_REDS" ] && grep -qv '^PASS ' "$first"; then
  history_py="$(dirname "$self")/webviews_test_history.py"
  { python3 "$(dirname "$self")/webviews_test_results.py" "$first" "$results/first.json" &&
    python3 "$history_py" base-red-files "$CMUX_WEB_TEST_BASE_REDS" --names "$results/first.json" > "$results/base-red"; } ||
    : > "$results/base-red"
fi
base_red_skipped=0
# CMUX_WEB_TEST_RETRY_BREAKER=K (0 or unset: off): once K alone retries have run and none passed, the rest of the red
# files get no alone retry and go to react-apps-base-check with their first run, as a base red does. A shard where
# nothing passes alone is not losing races for the CPU, so its retries only re-confirm reds: 24 h of shards to
# 2026-11-22 07:17Z had 2,440 jobs with a 30-80 min test step, and in 8 sampled long shards 7 of 88 alone retries
# passed, while the gallery files (accent-glass-invariants, control-contrast) failed again at 470-615 s apiece.
# The verdict does not move: the base check replays every red on the base and re-runs alone on the head any red it
# would charge to the change (up to 25 a shard), so a contention flake the breaker left unretried still passes there.
# Retries with a pass among the first K run as before (their shard is contended). Undo: set it to 0.
retry_breaker="${CMUX_WEB_TEST_RETRY_BREAKER:-0}"
[[ "$retry_breaker" =~ ^[0-9]+$ ]] || retry_breaker=0
breaker_skipped=0
# CMUX_WEB_TEST_RETRY_SLOW_SECONDS=S (0 or unset: off): a red file whose first run took more than S seconds (a timeout
# at a limit over S, or a long failure) gets no alone retry and goes to react-apps-base-check with its first run, as a
# base red does. CMUX_WEB_TEST_ALONE_RETRY_BUDGET=B (unset: off): every alone retry, failed or timed out, starts within
# B seconds of the retries' start; a failed file's starts only when its first run's seconds fit what is left and is cut
# there (keeping its first failure), a timed-out file's only when its whole limit fits; the rest keep their first run.
# Shard 2 of job 137151085368 retried 15 files alone for 26 min (09:36-10:02Z): accent-glass-invariants-3/5/9 at
# 462-481 s apiece and agent-pane-reveal-in-place at 362 s each failed again, as on the base, and the base check then
# judged all 11 reds anyway. Its 5 alone passes took 20-116 s each. A 120 s timeout is not over S=120, so it keeps its
# retry: 3 of those 5 passes were 120 s timeouts. Undo: set both to 0 / empty.
retry_slow="${CMUX_WEB_TEST_RETRY_SLOW_SECONDS:-0}"
[[ "$retry_slow" =~ ^[0-9]+$ ]] || retry_slow=0
alone_budget="${CMUX_WEB_TEST_ALONE_RETRY_BUDGET:-}"
[[ "$alone_budget" =~ ^[0-9]+$ ]] || alone_budget=""
slow_skipped=0
alone_budget_skipped=0
# Each file's first-run wall seconds (the last line before the retries; a warming file's earlier tries come first).
cp "$results/durations" "$results/first-durations" 2> /dev/null || : > "$results/first-durations"
first_seconds() {
  awk -v f="$1" '$2 == f { s = $1 } END { print (s == "" ? 0 : s) }' "$results/first-durations"
}
# alone_left: seconds left of CMUX_WEB_TEST_ALONE_RETRY_BUDGET (a large number when none is set).
alone_left() {
  if [ -n "$alone_budget" ]; then echo $((alone_budget - (SECONDS - retry_started))); else echo 999999; fi
}
# keep_first FILE REASON: no alone retry for FILE; its first run is its verdict, for react-apps-base-check to judge.
keep_first() {
  echo "NO RETRY $result $file: $1; react-apps-base-check judges it"
  printf '%s\n' "$file" >> "$results/retry-skipped"
  printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
}
# CMUX_WEB_TEST_RETRY_POOL=W (0 or unset: off): before the alone retries, the red files due one run again W at a time
# on the otherwise idle runner (the first pass ran 12 files at once). Each pooled retry then settles its file
# (webviews_retry_pool.py): a pass is a retry pass; a FAIL naming exactly its first run's red tests stays red with no
# alone retry (react-apps-base-check re-runs alone on the head any red it would charge to the change); anything else (a
# timeout, no named test, a different set) still gets its alone retry below. In 14 pull request shard logs after #49329
# (2026-11-22 08:57-09:40Z) the alone retries were 4,070 s of 12,992 s of test step, 121 retries one at a time, 8
# passing; 108 of the 113 red again named exactly the tests of their first run. A dev server file pools only on its
# config's warm cache (cold servers at once stall in the optimizer, above); one without goes alone as before. The pool
# takes a file only while its whole limit, and the pool's longest makespan bound, fit before the retry deadline.
retry_pool="${CMUX_WEB_TEST_RETRY_POOL:-0}"
[[ "$retry_pool" =~ ^[0-9]+$ ]] || retry_pool=0
pooled=0
pool_kept=0
: > "$results/pool-decided"
if [ "$retry_pool" -gt 0 ] && [ "$retries" -ne 0 ] && grep -qv '^PASS ' "$first"; then
  pool="$results/pool"
  mkdir -p "$pool"
  : > "$pool/list"
  : > "$pool/summary"
  pool_fails=0 pool_sum=0 pool_max=0 pool_index=0
  while read -r result file log; do
    [ "$result" != PASS ] || continue
    if grep -qxF -- "$file" "$results/base-red"; then continue; fi
    if [ "$result" != TIMEOUT ] && [ "$pool_fails" -ge "$retries" ]; then continue; fi
    seed=""
    if tr '\0' '\n' < "$results/serial" | grep -qxF -- "$file"; then
      seed="$(sed -n "s/^$(vite_config "$file") //p" "$results/warmed")"
      [ -n "$seed" ] || continue
    fi
    limit="$(file_limit "$file" "$timeout_seconds")"
    sum=$((pool_sum + limit)) max=$((limit > pool_max ? limit : pool_max))
    if [ $((sum / retry_pool + max)) -gt "$(deadline_left)" ]; then continue; fi
    pool_sum=$sum pool_max=$max pool_index=$((pool_index + 1))
    if [ "$result" != TIMEOUT ]; then pool_fails=$((pool_fails + 1)); fi
    cache=""
    if [ -n "$seed" ]; then cache="$vite/pool-retry-$pool_index"; fi
    printf '%s\0%s\0%s\0' "$file" "$cache" "$seed" >> "$pool/list"
  done < "$first"
  if [ -s "$pool/list" ]; then
    echo "RETRY POOL: $pool_index red files again, $retry_pool at a time (CMUX_WEB_TEST_RETRY_POOL)"
    pool_started=$SECONDS
    xargs -0 -n 3 -P "$retry_pool" bash "$self" --one-cached "$pool" "$timeout_seconds" < "$pool/list" || true
    echo "retry pool: done in $((SECONDS - pool_started))s"
    while read -r pool_result file pool_log; do
      log="$(awk -v f="$file" '$2 == f { print $3; exit }' "$first")"
      first_result="$(awk -v f="$file" '$2 == f { print $1; exit }' "$first")"
      [ -n "$log" ] && [ -f "$log" ] || continue
      decision="$(python3 "$(dirname "$self")/webviews_retry_pool.py" decide "$log" "$pool_result" "$pool_log" 2> /dev/null)" || decision=alone
      pooled=$((pooled + 1))
      # The marker line is the one every parser reads as "only the run after it counts" (webviews_test_results.py,
      # test_reds.py); the line after it says this run had company.
      { echo "--- first run: $first_result ---"; cat "$log"; echo "--- retry, alone ---"
        echo "(this retry ran beside up to $((retry_pool - 1)) other retried files: CMUX_WEB_TEST_RETRY_POOL=$retry_pool)"
        cat "$pool_log"; } > "$log.pooled"
      case "$decision" in
        pass)
          mv "$log.pooled" "$log"
          printf 'PASS %s %s\n' "$file" "$log" >> "$results/pool-decided"
          echo "$file (first run: $first_result; passed beside other retries)" >> "$results/retry-passed"
          ;;
        red-again)
          mv "$log.pooled" "$log"
          pool_kept=$((pool_kept + 1))
          printf '%s %s %s\n' "$pool_result" "$file" "$log" >> "$results/pool-decided"
          echo "NO ALONE RETRY $pool_result $file: its pooled retry named the same red tests as its first run; react-apps-base-check judges it"
          ;;
        *)
          # Its alone retry below keeps the pooled run in its log, ahead of the alone run that counts.
          mv "$log.pooled" "$log"
          ;;
      esac
    done < "$pool/summary"
  fi
fi
while read -r result file log; do
  decided="$(awk -v f="$file" '$2 == f' "$results/pool-decided")"
  if [ -n "$decided" ]; then
    printf '%s\n' "$decided" >> "$results/summary"
    continue
  fi
  if [ "$result" = PASS ] || [ "$retries" -eq 0 ] || { [ "$result" != TIMEOUT ] && [ "$retried" -ge "$retries" ]; }; then
    if [ "$result" != PASS ] && [ "$retries" -gt 0 ]; then printf '%s\n' "$file" >> "$results/retry-skipped"; fi
    printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
    continue
  fi
  if grep -qxF -- "$file" "$results/base-red"; then
    echo "NO RETRY $result $file: every red of its first run is red on the base's push too; react-apps-base-check judges it"
    base_red_skipped=$((base_red_skipped + 1))
    printf '%s\n' "$file" >> "$results/retry-skipped"
    printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
    continue
  fi
  if [ "$retry_breaker" -gt 0 ] && [ $((retried + timeout_retried)) -ge "$retry_breaker" ] && [ ! -s "$results/retry-passed" ]; then
    echo "NO RETRY $result $file: the first $retry_breaker alone retries all failed again (CMUX_WEB_TEST_RETRY_BREAKER); react-apps-base-check judges it"
    breaker_skipped=$((breaker_skipped + 1))
    printf '%s\n' "$file" >> "$results/retry-skipped"
    printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
    continue
  fi
  took="$(first_seconds "$file")"
  if [ "$retry_slow" -gt 0 ] && [ "$took" -gt "$retry_slow" ]; then
    keep_first "its first run took ${took}s, over ${retry_slow}s (CMUX_WEB_TEST_RETRY_SLOW_SECONDS)"
    slow_skipped=$((slow_skipped + 1))
    continue
  fi
  iteration_started=$SECONDS
  normal_limit="$(file_limit "$file" "$timeout_seconds")"
  alone="$(alone_left)"
  if [ "$result" = TIMEOUT ]; then need="$normal_limit"; else need=$((took > 0 ? took : 1)); fi
  if [ "$alone" -lt "$need" ]; then
    keep_first "the alone retry budget (${alone}s of ${alone_budget}s left, CMUX_WEB_TEST_ALONE_RETRY_BUDGET) cannot fit its ${need}s"
    alone_budget_skipped=$((alone_budget_skipped + 1))
    continue
  fi
  if [ "$result" = TIMEOUT ]; then
    # The timed-out file's own retry: its own budget, its full limit, never cut short.
    timeout_remaining=999999
    if [ -n "$timeout_retry_budget" ]; then
      timeout_remaining=$((timeout_retry_budget - timeout_retry_spent - (SECONDS - iteration_started)))
    fi
    left="$(deadline_left)"
    if [ "$left" -lt "$normal_limit" ]; then
      echo "retry deadline (${left}s left) cannot fit $file's ${normal_limit}s limit: keeping TIMEOUT"
      printf '%s\n' "$file" >> "$results/retry-skipped"
      printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
    elif [ "$timeout_remaining" -lt "$normal_limit" ]; then
      echo "timeout retry budget (${timeout_remaining}s left) cannot fit $file's ${normal_limit}s limit: keeping TIMEOUT"
      printf '%s\n' "$file" >> "$results/retry-skipped"
      printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
    else
      echo "RETRY $file after its timeout (its own retry; timeout retry budget ${timeout_remaining}s, hard limit ${normal_limit}s)"
      timeout_retried=$((timeout_retried + 1))
      mv "$log" "$log.first"
      cache=""
      if tr '\0' '\n' < "$results/serial" | grep -qxF -- "$file"; then cache="$vite/timeout-retry-$timeout_retried"; fi
      bash "$self" --one "$file" "$results" "$timeout_seconds" "$cache" < /dev/null
      if [ -n "$cache" ]; then rm -rf "$cache" || true; fi
      if grep -qxF "PASS $file $log" "$results/summary"; then
        echo "$file (first run: TIMEOUT)" >> "$results/retry-passed"
      else
        # TIMEOUT again stays TIMEOUT; a FAIL alone keeps the retry's named failures, as for a failed file.
        { echo "--- first run: TIMEOUT ---"; cat "$log.first"; echo "--- retry, alone ---"; cat "$log"; } > "$log.both"
        mv "$log.both" "$log"
      fi
    fi
    timeout_retry_spent=$((timeout_retry_spent + SECONDS - iteration_started))
    continue
  fi
  # The failed files' shared budget is wall time since the retries began, less the timeout retries'.
  remaining=$((retry_budget - (SECONDS - retry_started - timeout_retry_spent)))
  left="$(deadline_left)"
  if [ "$left" -lt "$remaining" ]; then remaining="$left"; fi
  if [ "$alone" -lt "$remaining" ]; then remaining="$alone"; fi
  if [ "$remaining" -le 0 ]; then
    echo "retry budget exhausted: keeping $result $file"
    printf '%s\n' "$file" >> "$results/retry-skipped"
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
    printf '%s\n' "$file" >> "$results/retry-skipped"
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

if [ -n "${CMUX_WEB_TEST_DURATIONS_OUT:-}" ]; then
  mkdir -p "$(dirname "$CMUX_WEB_TEST_DURATIONS_OUT")"
  python3 "$shards_py" record "$results/durations" "$CMUX_WEB_TEST_DURATIONS_OUT"
fi

# Per-test results for webviews-tests-new-reds.sh, which compares them with the base's.
if [ -n "${CMUX_WEB_TEST_RESULTS:-}" ]; then
  CMUX_WEB_TEST_RETRY_SKIPPED="$results/retry-skipped" \
    python3 "$(dirname "$self")/webviews_test_results.py" "$results/summary" "$CMUX_WEB_TEST_RESULTS"
fi
# Explicit final per-test outcomes keep successful names available to the base flake scorer without
# dumping green raw logs. Only whole final attempts contribute; TAP_CI_ENABLED=0 disables the export.
if [ "${TAP_CI_ENABLED:-1}" != 0 ]; then
  python3 "$(dirname "$self")/webviews_test_results.py" --tap-markers "$results/summary"
fi

echo "### webviews tests: $count files, $failed failed or timed out ($((retried + timeout_retried)) retried alone, $(wc -l < "$results/retry-passed" | tr -d ' ') passed alone)"
if [ -s "$results/not-run" ]; then
  echo "not run by CMUX_WEB_TEST_STOP_AT (no verdict, so the run fails): $(grep -c . "$results/not-run")"
  sed 's/^/  NOT RUN /' "$results/not-run"
fi
if [ "$base_red_skipped" -gt 0 ]; then
  echo "red on the base's push too, so not retried (react-apps-base-check judges them): $base_red_skipped"
fi
if [ "$pooled" -gt 0 ]; then
  echo "retried beside other retries (CMUX_WEB_TEST_RETRY_POOL=$retry_pool): $pooled; red again on the same tests, so not retried alone: $pool_kept"
fi
if [ "$breaker_skipped" -gt 0 ]; then
  breaker_line="alone retries skipped: $breaker_skipped, since the first $retry_breaker alone retries all failed again (not contention; react-apps-base-check judges them; CMUX_WEB_TEST_RETRY_BREAKER=0 retries every red file)"
  echo "$breaker_line"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$breaker_line" >> "$GITHUB_STEP_SUMMARY" || true; fi
fi
if [ $((slow_skipped + alone_budget_skipped)) -gt 0 ]; then
  bound_line="alone retries skipped by the retry cost bound: $slow_skipped whose first run took over ${retry_slow}s (CMUX_WEB_TEST_RETRY_SLOW_SECONDS), $alone_budget_skipped past the ${alone_budget:-unset}s budget (CMUX_WEB_TEST_ALONE_RETRY_BUDGET); react-apps-base-check judges them"
  echo "$bound_line"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$bound_line" >> "$GITHUB_STEP_SUMMARY" || true; fi
fi
if [ -s "$results/retry-passed" ]; then
  echo "passed only when run alone (failed or timed out beside other files):"
  sed 's/^/  /' "$results/retry-passed"
fi
while read -r result file _; do
  [ "$result" = PASS ] || echo "$result $file (limit $(file_limit "$file" "$timeout_seconds")s)"
done < <(sort -k2 "$results/summary")
[ "$failed" -eq 0 ] && [ ! -s "$results/not-run" ]
