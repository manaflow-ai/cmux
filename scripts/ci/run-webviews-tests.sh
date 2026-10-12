#!/usr/bin/env bash
# Runs every webviews test file in its own `bun test` process, run from webviews/.
#
# One `bun test` process for the whole suite stalled in a different file each run
# (ui-menu, markdown-viewer-shell, chips/linkChips) until the job timeout, and each
# of those files passes alone: state leaks from file to file (timers, handles,
# jsdom globals). A process per file keeps that leak inside one file, and a
# wall-clock timeout per file names a stuck file instead of hanging the job.
#
# CMUX_WEB_TEST_FILE_TIMEOUT: seconds one file may run (default 120).
# CMUX_WEB_TEST_JOBS: files run at once (default: CMUX_CI_CPU_BUDGET, the cores a fleet
# worker granted the step, else the CPU count).
#
# Files that start a Vite dev server run after the rest: the agent pane and gallery configs
# (vite.config.acpmux-pane.mjs, vite.config.gallery-dev.ts), and files that spawn `vp dev`
# themselves (editor-page, ui-a11y, settings-scroll). On one node_modules/.vite two at once lose
# each other's optimized files, and three starting cold at once (agent-history,
# agent-pane-peer-chat, chat-find) stall in the optimizer's first bundle, even with a cache each;
# editor-page timed out the same way beside ui-a11y and text-field-focus. So one file per Vite
# config runs first, alone, and warms that config's cache (CMUX_VITE_CACHE_DIR, which the dev
# configs read); the rest then run CMUX_WEB_TEST_DEV_JOBS at once (default half of the jobs), each
# on its own copy of its config's warm cache. A config whose warming file fails keeps its other
# files one at a time on a cold cache each.
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

if [ "${1:-}" = --one-cached ]; then
  # xargs -n 3 appends FILE CACHE SEED after the fixed arguments.
  exec bash "$0" --one "$4" "$2" "$3" "$5" "${6:-}"
fi
if [ "${1:-}" = --one ]; then
  # Worker: run one file, write its log and status into the results directory. A dev server
  # file gets a Vite cache of its own (CMUX_VITE_CACHE_DIR), a copy of a warm one when given.
  file="$2" results="$3" timeout_seconds="$4" cache="${5:-}" seed="${6:-}"
  log="$results/$(printf '%s' "$file" | tr '/' '_').log"
  status=0
  if [ -n "$cache" ]; then
    rm -rf "$cache"
    mkdir -p "$(dirname "$cache")"
    if [ -n "$seed" ] && [ -d "$seed" ]; then cp -R "$seed" "$cache"; else mkdir -p "$cache"; fi
    CMUX_VITE_CACHE_DIR="$cache" run_with_timeout "$timeout_seconds" bun test "./$file" > "$log" 2>&1 < /dev/null ||
      status=$?
    # A warming file's cache (no seed) is the one the rest copy; any other one only costs disk.
    if [ -n "$seed" ]; then rm -rf "$cache"; fi
  else
    run_with_timeout "$timeout_seconds" bun test "./$file" > "$log" 2>&1 < /dev/null || status=$?
  fi
  case "$status" in
    0) result=PASS ;;
    124 | 137) result=TIMEOUT ;;
    *) result=FAIL ;;
  esac
  printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
  echo "$result $file"
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
count="$(tr -cd '\0' < "$results/files" | wc -c | tr -d ' ')"
if [ "$count" -eq 0 ]; then
  echo "error: no webviews test files found under $PWD" >&2
  exit 1
fi
# Two dev servers at once (composer-mention, composer-send-stop) optimize dependencies into the
# same node_modules/.vite, and each loses files the other wrote. `"dev",` is the argument a file
# passes when it spawns `vp dev` itself. `--null`, not `-Z`: BSD grep reads -Z as decompress.
dev_servers='vite\.config\.(acpmux-pane\.mjs|gallery-dev\.ts)|"dev",'
xargs -0 grep -lE --null -- "$dev_servers" < "$results/files" > "$results/serial" || true
serial="$(tr -cd '\0' < "$results/serial" | wc -c | tr -d ' ')"
xargs -0 grep -LE --null -- "$dev_servers" < "$results/files" > "$results/parallel" || true
# A quarter of the jobs: each dev server file runs a Vite server and a browser, and at jobs / 2 the
# 8-core runner was CPU bound (no faster per file) and frame-budget plays (instructions-notice)
# and attach timing (agent-pane-seen) failed.
dev_jobs="${CMUX_WEB_TEST_DEV_JOBS:-$((jobs > 3 ? jobs / 4 : 1))}"
echo "running $count webviews test files, $jobs at a time ($serial dev server files after, $dev_jobs at a time), ${timeout_seconds}s each"
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
# One file per config warms its cache, alone; the others wait for it.
vite="$results/vite"
warmed=" "
: > "$results/dev-rest"
while IFS= read -r -d '' file; do
  config="$(vite_config "$file")"
  case "$warmed" in
    *" $config "*) printf '%s\0%s\0' "$config" "$file" >> "$results/dev-rest" ;;
    *)
      warmed="$warmed$config "
      printf '%s %s\n' "$config" "$file" >> "$results/warmers"
      bash "$self" --one "$file" "$results" "$timeout_seconds" "$vite/seed-$config"
      ;;
  esac
done < "$results/serial"
# The rest copy their config's warm cache and run at once; a config whose warming file did not
# pass has no trustworthy cache, so its files run one at a time, each on a cold cache of its own.
: > "$results/dev-warm"
: > "$results/dev-cold"
index=0
while IFS= read -r -d '' config && IFS= read -r -d '' file; do
  index=$((index + 1))
  warmer="$(sed -n "s/^$config //p" "$results/warmers")"
  if grep -qxF "PASS $warmer $results/$(printf '%s' "$warmer" | tr '/' '_').log" "$results/summary"; then
    printf '%s\0%s\0%s\0' "$file" "$vite/$index" "$vite/seed-$config" >> "$results/dev-warm"
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

failed=0
while read -r result file log; do
  # A passing file's workflow annotations (prScope.ts warns about base-branch findings) still reach the run.
  if [ "$result" = PASS ]; then
    grep -E '^::(warning|notice)( |::)' "$log" || true
    continue
  fi
  failed=$((failed + 1))
  echo "::group::$result $file"
  cat "$log"
  echo "::endgroup::"
done < <(sort -k2 "$results/summary")

echo "### webviews tests: $count files, $failed failed or timed out"
while read -r result file _; do
  [ "$result" = PASS ] || echo "$result $file (limit ${timeout_seconds}s)"
done < <(sort -k2 "$results/summary")
[ "$failed" -eq 0 ]
