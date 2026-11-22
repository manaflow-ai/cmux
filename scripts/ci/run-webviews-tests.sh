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
# CMUX_WEB_TEST_JOBS: files run at once (default: the CPU count).
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

if [ "${1:-}" = --one ]; then
  # Worker: run one file, write its log and status into the results directory.
  file="$2" results="$3" timeout_seconds="$4"
  log="$results/$(printf '%s' "$file" | tr '/' '_').log"
  status=0
  run_with_timeout "$timeout_seconds" bun test "./$file" > "$log" 2>&1 < /dev/null || status=$?
  case "$status" in
    0) result=PASS ;;
    124 | 137) result=TIMEOUT ;;
    *) result=FAIL ;;
  esac
  printf '%s %s %s\n' "$result" "$file" "$log" >> "$results/summary"
  echo "$result $file"
  exit 0
fi

timeout_seconds="${CMUX_WEB_TEST_FILE_TIMEOUT:-120}"
jobs="${CMUX_WEB_TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
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
echo "running $count webviews test files, $jobs at a time, ${timeout_seconds}s each"
: > "$results/summary"
xargs -0 -P "$jobs" -I{} bash "$0" --one {} "$results" "$timeout_seconds" < "$results/files"

failed=0
while read -r result file log; do
  [ "$result" = PASS ] && continue
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
