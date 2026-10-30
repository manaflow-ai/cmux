#!/usr/bin/env bash
# Run xcodebuild and preserve the failure evidence that a self-hosted runner can
# otherwise hide when the compiler is terminated under resource pressure.
set -u -o pipefail

if [[ "${1:-}" != "--" || "$#" -lt 2 ]]; then
  echo "usage: $0 -- <xcodebuild command and arguments...>" >&2
  exit 2
fi
shift

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
started_epoch="$(date '+%s')"
echo "xcodebuild diagnostic wrapper start: $started_at"
printf 'xcodebuild command:'
printf ' %q' "$@"
printf '\n'

# Blacksmith terminates a job whose command stream is idle while a compiler is
# still working. xcodebuild can legitimately spend several minutes in one
# Swift-driver operation without emitting a line, so keep the runner informed
# with a bounded heartbeat. The interval is overrideable for deterministic
# tests, but never disabled in the nightly workflow.
heartbeat_seconds="${CMUX_XCODEBUILD_HEARTBEAT_SECONDS:-30}"
if ! [[ "$heartbeat_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || ! awk -v interval="$heartbeat_seconds" 'BEGIN { exit !((interval + 0) > 0) }'; then
  echo "CMUX_XCODEBUILD_HEARTBEAT_SECONDS must be a positive number" >&2
  exit 2
fi

set +e
collect_process_tree() {
  local pid="$1"
  local descendant
  printf '%s\n' "$pid"
  for descendant in $(pgrep -P "$pid" 2>/dev/null); do
    collect_process_tree "$descendant"
  done
}

terminate_child() {
  local process_tree
  local pid
  process_tree="$(collect_process_tree "$child_pid")"
  for pid in $process_tree; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  local deadline=$(( $(date '+%s') + 5 ))
  while :; do
    local alive=0
    for pid in $process_tree; do
      if kill -0 "$pid" 2>/dev/null; then
        alive=1
        break
      fi
    done
    [[ "$alive" -eq 0 ]] && break
    if [[ "$(date '+%s')" -ge "$deadline" ]]; then
      for pid in $process_tree; do
        kill -KILL "$pid" 2>/dev/null || true
      done
      break
    fi
    sleep 0.1
  done
}

# Keep a copy of the build output so a failure can repeat its compiler errors
# at the end of the log and as annotations. xcodebuild prints an error once,
# thousands of lines before "** BUILD FAILED **", and `gh run view
# --log-failed` cuts long logs, so without this an exit 65 looks silent. A FIFO
# (not process substitution) lets bash 3.2 wait for tee to drain.
output_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xcodebuild-output.XXXXXX")"
output_log="${CMUX_XCODEBUILD_OUTPUT_LOG:-$output_dir/xcodebuild.log}"
output_fifo="$output_dir/xcodebuild.fifo"
mkfifo "$output_fifo"
tee "$output_log" <"$output_fifo" &
tee_pid=$!

"$@" >"$output_fifo" 2>&1 &
child_pid=$!
interrupted_signal=0
handle_signal() {
  interrupted_signal="$1"
  terminate_child
}
trap 'handle_signal 2' INT
trap 'handle_signal 15' TERM
(
  heartbeat_sleep_pid=""
  heartbeat_cleanup() {
    if [[ -n "$heartbeat_sleep_pid" ]]; then
      kill "$heartbeat_sleep_pid" 2>/dev/null || true
    fi
    exit 143
  }
  trap heartbeat_cleanup INT TERM
  while kill -0 "$child_pid" 2>/dev/null; do
    sleep "$heartbeat_seconds" &
    heartbeat_sleep_pid=$!
    wait "$heartbeat_sleep_pid"
    heartbeat_sleep_pid=""
    kill -0 "$child_pid" 2>/dev/null || break
    now_epoch="$(date '+%s')"
    elapsed=$((now_epoch - started_epoch))
    echo "xcodebuild heartbeat: pid=$child_pid elapsed=${elapsed}s"
  done
) &
heartbeat_pid=$!
wait "$child_pid"
status=$?
if [[ "$interrupted_signal" -ne 0 ]]; then
  status=$((128 + interrupted_signal))
fi
kill "$heartbeat_pid" 2>/dev/null || true
wait "$heartbeat_pid" 2>/dev/null || true
# tee ends when the last writer closes the FIFO. A leftover build service that
# inherited the descriptor must not hang the step, so give it ten seconds.
tee_deadline=$(( $(date '+%s') + 10 ))
while kill -0 "$tee_pid" 2>/dev/null && [[ "$(date '+%s')" -lt "$tee_deadline" ]]; do
  sleep 0.1
done
kill "$tee_pid" 2>/dev/null || true
wait "$tee_pid" 2>/dev/null || true
trap - INT TERM
set -e

# A compiler crash (swift-frontend or clang signal) prints a "Stack dump:" block
# and no "error:" line. Prints the pass, the declaration and the top of each
# crash's stack, with an annotation at the declaration's file and line.
report_compiler_crashes() {
  local log="$1"
  grep -q '^Stack dump:' "$log" 2>/dev/null || return 0
  echo "--- compiler crash (the frontend died on a signal; this is the real failure) ---"
  awk '
    /^Stack dump:/ { crash++; show=1; depth=0; print "crash " crash ":"; next }
    show && /^[0-9]+\.[[:space:]]/ { print substr($0, 1, 400); next }
    show && /^ for / { print substr($0, 1, 400); next }
    show && /^[0-9]+ +[^ ]/ { if (depth++ < 12) print substr($0, 1, 400); next }
    show && /^(Failed frontend command|Command .* failed)/ { show=0 }
  ' "$log" 2>/dev/null | head -n 80 || true
  grep -E '^ for .* \(at /[^:]+:[0-9]+:[0-9]+\)' "$log" 2>/dev/null | awk '!seen[$0]++' | head -n 5 \
    | while IFS= read -r line; do
      if [[ "$line" =~ ^\ for\ (.*)\ \(at\ (/[^:]+):([0-9]+):([0-9]+)\)$ ]]; then
        echo "::error file=${BASH_REMATCH[2]},line=${BASH_REMATCH[3]},col=${BASH_REMATCH[4]}::compiler crash while optimizing ${BASH_REMATCH[1]} (see the stack dump in the log)"
      fi
    done || true
}

# A run script phase that exits nonzero prints no "error:" line unless the
# script wrote one; xcodebuild only names the phase among the failed commands
# (nightly-next's Embed CEF red, 2026-10-24, showed nothing else). The phases
# come from xcodebuild's own "The following build commands failed:" list, never
# from whichever header came last, so a failure is never pinned on another
# task. Each listed phase's output is the last block under its exact header,
# up to the next task header or failure line, without the environment dump
# xcodebuild puts first; its last 30 lines print for the first 5 failed
# phases, and every failed phase gets an annotation.
report_failed_script_phases() {
  local log="$1"
  grep -q '^[[:blank:]]PhaseScriptExecution ' "$log" 2>/dev/null || return 0
  awk '
    function close_block() { cur = 0 }
    NR == FNR {
      if ($0 ~ /^The following build commands failed:/) { listing = 1; next }
      if (listing && $0 ~ /^\([0-9]+ failures?\)/) { listing = 0; next }
      if (listing && $0 ~ /^\tPhaseScriptExecution /) {
        header = substr($0, 2)
        if (!(header in index_of)) { index_of[header] = ++failed; headers[failed] = header }
      }
      next
    }
    ($0 in index_of) { cur = index_of[$0]; seen[cur] = 1; count[cur] = 0; next }
    /^Command PhaseScriptExecution failed/ { close_block(); next }
    /^[A-Za-z].* \(in target .* from project .*\)$/ { close_block(); next }
    !cur { next }
    /^$/ || /^    (export |cd |\/bin\/sh -c )/ { next }
    { ring[cur, count[cur] % 30] = $0; count[cur]++ }
    END {
      for (i = 1; i <= failed; i++) {
        name = headers[i]
        sub(/^PhaseScriptExecution /, "", name); sub(/ \/.*$/, "", name); gsub(/\\ /, " ", name)
        if (i <= 5) {
          print "--- failed run script phase: " substr(headers[i], 1, 300) " ---"
          if (!seen[i]) print "(its output block is not in the log)"
          n = count[i]; first = n > 30 ? n - 30 : 0
          for (k = first; k < n; k++) print substr(ring[i, k % 30], 1, 400)
        }
        print "::error::run script phase failed: " name
      }
    }
  ' "$log" "$log" 2>/dev/null || true
}

# Prints each distinct compiler/build error once, as a GitHub annotation (file
# and line when the error has them) and as plain text.
report_build_errors() {
  local log="$1"
  local errors
  errors="$(grep -E '(^|: )(fatal )?error: ' "$log" 2>/dev/null \
    | grep -vE '^[[:space:]]*[|`]' \
    | awk '!seen[$0]++' \
    | head -n 50 || true)"
  echo "--- first 50 xcodebuild error lines (from $log) ---"
  if [[ -z "$errors" ]]; then
    echo "no 'error:' line in the xcodebuild output; see the failed commands below and the resource diagnostics"
    report_compiler_crashes "$log"
    report_failed_script_phases "$log"
  else
    printf '%s\n' "$errors"
    printf '%s\n' "$errors" | while IFS= read -r line; do
      if [[ "$line" =~ ^(/[^:]+):([0-9]+):([0-9]+):\ (fatal\ )?error:\ (.*)$ ]]; then
        echo "::error file=${BASH_REMATCH[1]},line=${BASH_REMATCH[2]},col=${BASH_REMATCH[3]}::${BASH_REMATCH[5]}"
      else
        echo "::error::${line}"
      fi
    done
  fi
  awk '/The following build commands failed:/ {show=1} show {print} /^\([0-9]+ failures?\)/ {show=0}' "$log" 2>/dev/null \
    | head -n 40 || true
  if grep -q 'Crash reproducer created' "$log" 2>/dev/null; then
    echo "note: a 'Crash reproducer created' line usually marks a compile xcodebuild cancelled after another task failed, not a compiler crash"
  fi
}

finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "xcodebuild diagnostic wrapper finish: $finished_at"
echo "xcodebuild exit status: $status"

if [[ "$status" -eq 0 ]]; then
  rm -rf "$output_dir"
  exit 0
fi

if [[ "$status" -ge 128 ]]; then
  signal_number=$((status - 128))
  echo "xcodebuild termination: signal=$signal_number (shell status=$status)"
else
  echo "xcodebuild termination: exited normally (status=$status)"
fi
echo "::error::xcodebuild failed with status=$status; build errors and resource diagnostics follow"
report_build_errors "$output_log"

print_diagnostic() {
  local label="$1"
  shift
  echo "--- $label ---"
  if "$@"; then
    return 0
  fi
  echo "$label unavailable (command failed or is not supported on this runner)"
}

print_diagnostic "host" uname -a
print_diagnostic "memory and CPU" bash -c '
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.memsize 2>/dev/null || true
    sysctl -n hw.ncpu 2>/dev/null || true
    sysctl vm.swapusage 2>/dev/null || true
  fi
  if command -v vm_stat >/dev/null 2>&1; then
    vm_stat 2>/dev/null || true
  fi
  if command -v memory_pressure >/dev/null 2>&1; then
    memory_pressure -Q 2>/dev/null || true
  fi
'
print_diagnostic "disk" df -h .
print_diagnostic "top processes by resident memory" bash -c '
  ps -axo pid,ppid,%cpu,%mem,rss,vsz,state,command 2>/dev/null \
    | sort -nrk5 \
    | head -25
'
print_diagnostic "compiler processes" bash -c '
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -fal "xcodebuild|swiftc|clang|sourcekit" || true
  else
    ps -axo pid,ppid,%cpu,%mem,rss,vsz,state,command 2>/dev/null \
      | grep -E "xcodebuild|swiftc|clang|sourcekit" \
      | grep -v grep \
      || true
  fi
'

# Repeat the errors last, so the end of the log names the failure.
report_build_errors "$output_log" | grep -v '^::error' || true
exit "$status"
