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

# The heartbeat also hides a build that has stopped. In nightly run 43673773157
# (2026-11-15) the build service deadlocked: xcodebuild and SWBBuildService sat
# at 0% CPU with every llbuild lane waiting, and the log stayed silent for over
# 2 hours, while a normal build step takes 2 to 6 minutes. The heartbeat kept
# the step looking alive until the job's 300-minute timeout, and the nightly
# feed stalled behind it. A silent compile still uses CPU. So the build is
# stalled only when, for CMUX_XCODEBUILD_STALL_SECONDS, it writes no output,
# starts or ends no process, and its process tree uses less than
# CMUX_XCODEBUILD_STALL_CPU_SECONDS of CPU. A stalled build is ended with
# status 124 so that the caller can retry it. A stall window of 0 turns the
# check off.
stall_seconds="${CMUX_XCODEBUILD_STALL_SECONDS:-900}"
stall_cpu_seconds="${CMUX_XCODEBUILD_STALL_CPU_SECONDS:-5}"
if ! [[ "$stall_seconds" =~ ^[0-9]+$ && "$stall_cpu_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "CMUX_XCODEBUILD_STALL_SECONDS must be whole seconds and CMUX_XCODEBUILD_STALL_CPU_SECONDS a number" >&2
  exit 2
fi
stalled_status=124
# Before ending a stalled build, the wrapper samples its build service's stacks
# into this directory: run 43673773157's deadlock was diagnosed only from a
# `sample` someone took by hand on the runner. The error names the file.
stall_dir="${CMUX_XCODEBUILD_STALL_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xcodebuild-stall}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

# The package graph xcodebuild resolves first clones from github.com with
# Xcode's own git, through the self-hosted mini's loopback egress proxy. A dead
# or half-dead proxy fails that resolve (cmux runs 45830236598, 45836332236,
# 2026-11-26), so the proxy is probed before the build and a resolve that
# failed on it runs the build once more, direct (github-egress-direct.sh).
# shellcheck source=scripts/ci/github-egress-direct.sh
source "$script_dir/github-egress-direct.sh"
github_egress_probe

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

# One line per live process in the build's tree: "pid cpu_seconds", sorted by
# pid. ps prints CPU time as [DD-][HH:]MM:SS[.ss] on both macOS and Linux.
build_tree_snapshot() {
  local pids
  pids="$(collect_process_tree "$child_pid" | sort -n | paste -sd, -)"
  [[ -n "$pids" ]] || return 0
  ps -o pid=,time= -p "$pids" 2>/dev/null | awk '
    { t = $2; d = 0
      if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
      n = split(t, p, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + p[i]
      printf "%d %.2f\n", $1, s + d * 86400 }' | sort -n
}

# The build service this build started (SWBBuildService, XCBBuildService on
# older Xcodes): looked up only in the build's own process tree, never by name
# across the host, where another job's build service may be running.
build_service_pid() {
  local pid
  for pid in $(collect_process_tree "$child_pid"); do
    if ps -o args= -p "$pid" 2>/dev/null | grep -Eq '(^|/)(SWB|XCB)BuildService( |$)'; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

# Samples the stalled build's build service (or xcodebuild, when it started
# none) for 5 seconds with macOS `sample`, writes the build's process tree
# beside it, prints the sample's top of stack, and prints the sample's path.
sample_stalled_build() {
  local stamp target what sample_file sampler
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  if target="$(build_service_pid)"; then what=build-service; else target="$child_pid"; what=xcodebuild; fi
  mkdir -p "$stall_dir" 2>/dev/null || true
  sample_file="$stall_dir/xcodebuild-stall-$stamp-$what-$target.sample.txt"
  ps -o pid=,ppid=,time=,stat=,command= -p "$(collect_process_tree "$child_pid" | paste -sd, -)" \
    >"$stall_dir/xcodebuild-stall-$stamp.ps.txt" 2>/dev/null || true
  if ! command -v sample >/dev/null 2>&1; then
    echo "stall sample: no sample command on this host (not macOS); none taken" >&2
    return 0
  fi
  sampler=()
  [[ -x "$script_dir/timeout.sh" ]] && sampler=("$script_dir/timeout.sh" --kill-after=5 60)
  if ! ${sampler[@]+"${sampler[@]}"} sample "$target" 5 -file "$sample_file" >/dev/null 2>&1 || [[ ! -s "$sample_file" ]]; then
    echo "stall sample: sample $target failed; see the process tree in $stall_dir" >&2
    return 0
  fi
  {
    echo "--- top of stack of the stalled $what (pid $target), from $sample_file ---"
    awk '/^Sort by top of stack/ { show = 1; print; next } show && NF == 0 { exit } show && n++ < 15 { print }' \
      "$sample_file" 2>/dev/null || true
  } >&2
  printf '%s\n' "$sample_file"
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
  # The idle window starts again whenever the log grows, the set of processes
  # changes, or the tree has used stall_cpu_seconds of CPU since the window began.
  idle_since="$(date '+%s')"
  idle_size=""
  idle_pids=""
  idle_cpu=0
  while kill -0 "$child_pid" 2>/dev/null; do
    sleep "$heartbeat_seconds" &
    heartbeat_sleep_pid=$!
    wait "$heartbeat_sleep_pid"
    heartbeat_sleep_pid=""
    kill -0 "$child_pid" 2>/dev/null || break
    now_epoch="$(date '+%s')"
    elapsed=$((now_epoch - started_epoch))
    echo "xcodebuild heartbeat: pid=$child_pid elapsed=${elapsed}s"
    [[ "$stall_seconds" -gt 0 ]] || continue
    size="$(wc -c <"$output_log" 2>/dev/null | tr -d ' ')"
    snapshot="$(build_tree_snapshot)"
    pids="$(awk '{ print $1 }' <<<"$snapshot" | paste -sd, -)"
    cpu="$(awk '{ s += $2 } END { printf "%.2f", s + 0 }' <<<"$snapshot")"
    if [[ "$size" != "$idle_size" || "$pids" != "$idle_pids" ]] \
      || awk -v c="$cpu" -v b="$idle_cpu" -v m="$stall_cpu_seconds" 'BEGIN { exit !(c - b >= m) }'; then
      idle_since="$now_epoch"
      idle_size="$size"
      idle_pids="$pids"
      idle_cpu="$cpu"
      continue
    fi
    idle=$((now_epoch - idle_since))
    [[ "$idle" -ge "$stall_seconds" ]] || continue
    echo "--- stalled build process tree ---"
    ps -o pid=,ppid=,time=,stat=,command= -p "$pids" 2>/dev/null | cut -c1-300 || true
    sample_file="$(sample_stalled_build)"
    echo "::error::xcodebuild stalled: no output, no process started or ended, and under ${stall_cpu_seconds}s of CPU for ${idle}s (after ${elapsed}s); ending it with status $stalled_status so the build can be retried; build service stacks: ${sample_file:-none taken (see $stall_dir)}"
    printf '%s\n' "$sample_file" >"$output_dir/stalled"
    terminate_child
    break
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
build_stalled=0
if [[ -f "$output_dir/stalled" && "$interrupted_signal" -eq 0 ]]; then
  build_stalled=1
  status="$stalled_status"
fi
# tee ends when the last writer closes the FIFO. A leftover build service that
# inherited the descriptor must not hang the step, so give it ten seconds.
tee_deadline=$(( $(date '+%s') + 10 ))
while kill -0 "$tee_pid" 2>/dev/null && [[ "$(date '+%s')" -lt "$tee_deadline" ]]; do
  sleep 0.1
done
kill "$tee_pid" 2>/dev/null || true
wait "$tee_pid" 2>/dev/null || true
trap - INT TERM

# The first attempt already wrote its -resultBundlePath, and xcodebuild
# refuses an existing bundle ("Existing file at -resultBundlePath", status
# 64), so a rerun would fail on that instead of building. The bundle belongs
# to this build; clear it so the rerun can write it again.
clear_result_bundle() {
  local prev_arg="" arg
  for arg in "$@"; do
    if [[ "$prev_arg" == "-resultBundlePath" && -n "$arg" ]]; then
      rm -rf "$arg"
    fi
    prev_arg="$arg"
  done
}

if [[ "$status" -ne 0 && "$build_stalled" -eq 0 && "$interrupted_signal" -eq 0 ]] \
  && grep -qE 'Could not resolve package dependencies|Failed to resolve dependencies' "$output_log" 2>/dev/null \
  && github_egress_retry_direct "$output_log"; then
  echo "xcodebuild: the package resolve failed on the github.com proxy (status=$status); running it once more, direct"
  rm -rf "$output_dir"
  clear_result_bundle "$@"
  exec "$script_dir/$(basename "$0")" -- "$@"
fi

# Xcode's build service can crash mid-build and xcodebuild then ends with
# "error: unexpected service error: The Xcode build system has crashed. Build
# again to continue." (status 65). Xcode 27.2's build service did that in two
# of three nightly-next Release builds on 2026-11-27 (runs 46029967132,
# 46033303025), each part way through compiling code that builds clean. The
# message says to build again, so the build runs once more with the same
# arguments and DerivedData (a new xcodebuild starts a new build service).
# Only that exact message counts, and only once:
# CMUX_XCODEBUILD_SERVICE_CRASH_RETRIED marks the rerun, which reports its own
# failure as usual.
#
# The rerun builds without the compilation cache when the build had it on.
# From 22:12Z on 2026-11-27 every nightly-next build on ultra1-glaeda crashed
# the build service ("bad_optional_access was thrown in -fno-exceptions mode",
# then a dependency file rename failed) on both attempts, clean DerivedData
# included (runs 46074261734, 46076637784, 46079235693), with no settings or
# build change in the 47 commits since the last good build. A clean
# DerivedData still keeps the host's CAS (nightly_build_state.prepare_host
# links it across clean builds), so the cache is the one input every crashed
# attempt shared; a same-arguments rerun read it again and crashed again.
build_service_crash_message='The Xcode build system has crashed. Build again to continue.'
if [[ "$status" -ne 0 && "$build_stalled" -eq 0 && "$interrupted_signal" -eq 0 ]] \
  && [[ "${CMUX_XCODEBUILD_SERVICE_CRASH_RETRIED:-0}" != 1 ]] \
  && grep -qF "$build_service_crash_message" "$output_log" 2>/dev/null; then
  rerun=()
  cache_dropped=0
  for arg in "$@"; do
    if [[ "$arg" == COMPILATION_CACHE_ENABLE_CACHING=YES ]]; then
      arg=COMPILATION_CACHE_ENABLE_CACHING=NO
      cache_dropped=1
    fi
    rerun+=("$arg")
  done
  if (( cache_dropped )); then
    echo "::warning::xcodebuild: the Xcode build service crashed (status=$status: \"$build_service_crash_message\"); building once more, without the compilation cache"
  else
    echo "::warning::xcodebuild: the Xcode build service crashed (status=$status: \"$build_service_crash_message\"); building once more, same arguments"
  fi
  rm -rf "$output_dir"
  clear_result_bundle "$@"
  CMUX_XCODEBUILD_SERVICE_CRASH_RETRIED=1 exec "$script_dir/$(basename "$0")" -- "${rerun[@]}"
fi
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

if [[ "$build_stalled" -eq 1 ]]; then
  echo "xcodebuild termination: stalled; the wrapper ended it after ${stall_seconds}s without progress (status=$status)"
elif [[ "$status" -ge 128 ]]; then
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
