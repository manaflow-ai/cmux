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
set -euo pipefail

if [ "${1:-}" = --one ]; then
  # Worker: run one file, write its log and status into the results directory.
  file="$2" results="$3" timeout_seconds="$4"
  log="$results/$(printf '%s' "$file" | tr '/' '_').log"
  status=0
  timeout -k 10 "$timeout_seconds" bun test "./$file" > "$log" 2>&1 < /dev/null || status=$?
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
