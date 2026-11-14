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
#
# Across steps of one job (the cmux-next checks job):
#
#   scripts/ci/run-checks-concurrently.sh --start DIR [--jobs N] <<'EOF'
#   [step-a]
#   python3 tests/test_bar.py
#   [step-b]
#   bash scripts/cmux-next/tests/foo.test.sh
#   EOF
#   ...
#   scripts/ci/run-checks-concurrently.sh --wait DIR step-a
#
# --start reads the same lines, each under the last `[name]` line above it (a name may
# come back later, so the longest commands can start first), starts them all in the
# background and returns at once. --wait DIR NAME waits for that name's commands only,
# then prints and exits as the plain form does for them. The pool's results and logs
# stay in DIR until the job ends. A command whose result never came (the pool died)
# counts as failed.
#
# --deadline-at EPOCH (with --start or the plain form): a command still running at EPOCH stops
# (scripts/ci/timeout.sh: TERM to its process group, KILL 10 s later), fails by name and says
# "timed out at the pool deadline", so a job whose cap is near ends in a verdict, not a cancel
# with no name. A command that starts after EPOCH gets 1 s. --wait gives up 60 s after it too,
# and every minute it waits it prints which of its commands are still running and for how long
# (CHECK_POOL_HEARTBEAT seconds, 60 by default).
set -euo pipefail

jobs=""
mode=run
dir=""
name=""
deadline_at=""
usage() {
  echo "usage: run-checks-concurrently.sh [--jobs N] [--deadline-at EPOCH] < commands" >&2
  echo "       run-checks-concurrently.sh --start DIR [--jobs N] [--deadline-at EPOCH] < [name] lines and commands" >&2
  echo "       run-checks-concurrently.sh --wait DIR NAME" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) jobs="${2:-}"; shift 2 ;;
    --deadline-at) deadline_at="${2:-}"; shift 2 || usage ;;
    --start) mode=start; dir="${2:-}"; shift 2 ;;
    --wait) mode=wait; dir="${2:-}"; name="${3:-}"; shift 3 || usage ;;
    *) usage ;;
  esac
done
if [ "$mode" != run ]; then
  [ -n "$dir" ] || usage
fi
if [ -z "$jobs" ]; then
  cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  jobs=$((cpus * 2))
fi
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "error: --jobs is a positive whole number" >&2; exit 2; }
[ -z "$deadline_at" ] || [[ "$deadline_at" =~ ^[1-9][0-9]*$ ]] \
  || { echo "error: --deadline-at is a Unix time in seconds" >&2; exit 2; }
CHECK_POOL_TIMEOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/timeout.sh"
export CHECK_POOL_TIMEOUT

run_one() {
  local work="$1" index="$2" start status deadline="" limit
  start="$(date +%s)"
  echo "$start" > "$work/$index.started"
  status=0
  [ ! -s "$work/deadline" ] || read -r deadline < "$work/deadline"
  if [ -n "$deadline" ]; then
    limit=$(( deadline - start ))
    [ "$limit" -ge 1 ] || limit=1
    bash "$CHECK_POOL_TIMEOUT" --kill-after=10 "$limit" bash -c "$(cat "$work/$index.cmd")" \
      > "$work/$index.log" 2>&1 < /dev/null || status=$?
    # 124: the deadline's TERM ended it; 137: the KILL after it. A command's own 124 ends before the deadline.
    if { [ "$status" = 124 ] || [ "$status" = 137 ]; } && [ "$(date +%s)" -ge "$deadline" ]; then
      echo "check-pool: stopped at the pool deadline after ${limit}s: this command was still running" >> "$work/$index.log"
      : > "$work/$index.timedout"
    fi
  else
    bash -c "$(cat "$work/$index.cmd")" > "$work/$index.log" 2>&1 < /dev/null || status=$?
  fi
  printf '%s %s\n' "$status" "$(( $(date +%s) - start ))" > "$work/$index.rc.tmp"
  mv "$work/$index.rc.tmp" "$work/$index.rc"
}
export -f run_one

# Prints each listed command's output in order and exits 1 when any failed.
report() {
  local work="$1"; shift
  local failed=() index command status seconds verdict
  for index in "$@"; do
    command="$(cat "$work/$index.cmd")"
    read -r status seconds < "$work/$index.rc" 2>/dev/null || { status=1; seconds=0; }
    verdict=ok
    [ "$status" = 0 ] || { verdict="failed (exit $status)"; failed+=("$index"); }
    [ ! -e "$work/$index.timedout" ] || verdict="timed out at the pool deadline after ${seconds}s"
    echo "::group::$command: $verdict, ${seconds}s"
    cat "$work/$index.log" 2>/dev/null || echo "(no output: its result never came)"
    echo "::endgroup::"
  done
  echo "$# checks, $jobs at a time: $(( $# - ${#failed[@]} )) passed, ${#failed[@]} failed"
  [ "${#failed[@]}" -eq 0 ] && exit 0
  for index in "${failed[@]}"; do
    command="$(cat "$work/$index.cmd")"
    echo "::error title=check failed::$command"
    echo "----- $command"
    cat "$work/$index.log" 2>/dev/null || true
  done
  exit 1
}

if [ "$mode" = wait ]; then
  [ -n "$name" ] || usage
  [ -s "$dir/names/$name" ] || { echo "error: the start step listed no commands for $name ($dir)" >&2; exit 2; }
  read -r jobs < "$dir/jobs" || jobs="?"
  indices=()
  while IFS= read -r index; do indices+=("$index"); done < "$dir/names/$name"
  pool="$(cat "$dir/pool.pid")"
  waited="$(date +%s)"
  deadline=""
  [ ! -s "$dir/deadline" ] || read -r deadline < "$dir/deadline"
  heartbeat="${CHECK_POOL_HEARTBEAT:-60}"
  told="$waited"
  # Stops when every result is in, when the pool has exited (a missing result then counts as failed), or 60 s
  # past the pool's deadline. Every $heartbeat s it names the commands still running.
  for index in "${indices[@]}"; do
    while [ ! -e "$dir/$index.rc" ] && [ ! -e "$dir/pool.done" ] && kill -0 "$pool" 2>/dev/null; do
      now="$(date +%s)"
      if [ -n "$deadline" ] && [ "$now" -gt $(( deadline + 60 )) ]; then
        echo "$name: gave up waiting 60s past the pool deadline"
        break 2
      fi
      if [ $(( now - told )) -ge "$heartbeat" ]; then
        told="$now"
        for other in "${indices[@]}"; do
          [ ! -e "$dir/$other.rc" ] && [ -s "$dir/$other.started" ] || continue
          echo "$name: still running after $(( now - $(cat "$dir/$other.started") ))s: $(cat "$dir/$other.cmd")"
        done
      fi
      sleep 0.2
    done
  done
  echo "waited $(( $(date +%s) - waited ))s for $name's ${#indices[@]} commands"
  report "$dir" "${indices[@]}"
fi

if [ "$mode" = start ]; then
  [ ! -e "$dir" ] || { echo "error: $dir exists: one start per job" >&2; exit 2; }
  mkdir -p "$dir/names"
  work="$dir"
else
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
fi
count=0
current=""
while IFS= read -r line || [ -n "$line" ]; do
  command="${line#"${line%%[![:space:]]*}"}"
  command="${command%"${command##*[![:space:]]}"}"
  [ -n "$command" ] && [ "${command#\#}" = "$command" ] || continue
  if [ "$mode" = start ] && [[ "$command" =~ ^\[([A-Za-z0-9_.-]+)\]$ ]]; then
    current="${BASH_REMATCH[1]}"
    continue
  fi
  if [ "$mode" = start ] && [ -z "$current" ]; then
    echo "error: a command before any [name] line: $command" >&2
    exit 2
  fi
  count=$((count + 1))
  printf '%s\n' "$command" > "$work/$count.cmd"
  if [ "$mode" = start ]; then echo "$count" >> "$work/names/$current"; fi
done
[ "$count" -gt 0 ] || { echo "error: no commands on stdin" >&2; exit 2; }

[ -z "$deadline_at" ] || echo "$deadline_at" > "$work/deadline"
if [ "$mode" = start ]; then
  echo "$jobs" > "$work/jobs"
  # Detached from this step: the job's later steps read the results; the runner ends the pool with the job.
  (
    seq 1 "$count" | xargs -P "$jobs" -I{} bash -c 'run_one "$1" "$2"' _ "$work" {} || true
    touch "$work/pool.done"
  ) < /dev/null > "$work/pool.log" 2>&1 &
  echo "$!" > "$work/pool.pid"
  for names in "$work/names"/*; do
    echo "${names##*/}: $(wc -l < "$names") commands"
  done
  echo "$count commands started, $jobs at a time${deadline_at:+, deadline in $(( deadline_at - $(date +%s) ))s}"
  exit 0
fi

# A killed xargs still leaves the logs it has to print; a missing result counts as failed.
seq 1 "$count" | xargs -P "$jobs" -I{} bash -c 'run_one "$1" "$2"' _ "$work" {} || true
report "$work" $(seq 1 "$count")
