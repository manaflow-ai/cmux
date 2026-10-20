#!/usr/bin/env bash
# Run independent check commands a few at a time instead of one after another.
#
#   scripts/ci/run-checks-concurrently.sh [--jobs N] <<'EOF'
#   bash scripts/cmux-next/tests/foo.test.sh
#   python3 tests/test_bar.py
#   EOF
#
# Reads one command per line on stdin; blank lines and `#` comments are skipped.
# Each command runs under `bash -c` from the current directory with stdin closed.
# Every command runs even after one fails. Output is printed per command, whole
# and in input order, in a collapsed group with its duration; a failed command's
# output is printed again at the end, and the exit status is 1 when any failed.
# --jobs defaults to twice the CPU count: most of these checks wait on child
# processes and fixtures, not the CPU.
set -euo pipefail

jobs=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) jobs="${2:-}"; shift 2 ;;
    *) echo "usage: run-checks-concurrently.sh [--jobs N] < commands" >&2; exit 2 ;;
  esac
done
if [ -z "$jobs" ]; then
  cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  jobs=$((cpus * 2))
fi
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "error: --jobs is a positive whole number" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
count=0
while IFS= read -r line || [ -n "$line" ]; do
  command="${line#"${line%%[![:space:]]*}"}"
  [ -n "$command" ] && [ "${command#\#}" = "$command" ] || continue
  count=$((count + 1))
  printf '%s\n' "$command" > "$work/$count.cmd"
done
[ "$count" -gt 0 ] || { echo "error: no commands on stdin" >&2; exit 2; }

run_one() {
  local work="$1" index="$2" start status
  start="$(date +%s)"
  status=0
  bash -c "$(cat "$work/$index.cmd")" > "$work/$index.log" 2>&1 < /dev/null || status=$?
  printf '%s %s\n' "$status" "$(( $(date +%s) - start ))" > "$work/$index.rc"
}
export -f run_one
# A killed xargs still leaves the logs it has to print; a missing result counts as failed.
seq 1 "$count" | xargs -P "$jobs" -I{} bash -c 'run_one "$1" "$2"' _ "$work" {} || true

failed=()
for index in $(seq 1 "$count"); do
  command="$(cat "$work/$index.cmd")"
  read -r status seconds < "$work/$index.rc" || { status=1; seconds=0; }
  verdict=ok
  [ "$status" = 0 ] || { verdict="failed (exit $status)"; failed+=("$index"); }
  echo "::group::$command: $verdict, ${seconds}s"
  cat "$work/$index.log"
  echo "::endgroup::"
done
echo "$count checks, $jobs at a time: $(( count - ${#failed[@]} )) passed, ${#failed[@]} failed"
[ "${#failed[@]}" -eq 0 ] && exit 0
for index in "${failed[@]}"; do
  command="$(cat "$work/$index.cmd")"
  echo "::error title=check failed::$command"
  echo "----- $command"
  cat "$work/$index.log"
done
exit 1
