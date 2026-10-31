#!/usr/bin/env bash
# Orphaned cmux-tui and acpmux processes on this host (STATUS 1370, #29349 follow-up): every cmux-tui or
# acpmux process whose parent is 1 (launchd or init) and that has run for more than 1 hour. Read-only: it
# signals nothing, kills nothing and writes no file. macOS and Linux.
# Run alone on one worker (the process table is machine-wide):
#   cmux-ci run --class exclusive --measurement --script scripts/measure/orphan-process-scan.sh --ref SHA
#     --target-worker WORKER
# Output, one line each:
#   ORPHAN-SCAN-HOST host=... os=... ptmx_max=...
#   ORPHAN pid=... ppid=1 etime=... lstart="... UTC" cpu=... time=... owner_alive=yes|no|- socket=PATH|-
#     socket_state=present|missing|unreadable|- user=... cmd="first 250 chars"
#   ORPHAN-SCAN-SUMMARY count=N terminal_hosts=N daemons=N acpmux=N spinning=N (%cpu >= 50)
#   ORPHAN-SCAN-BUILDS path="..." processes=N orphans=N fix29349=yes|no|- replaced_after_start=N
# fix29349 is whether the executable has #29349's lost-socket watch (its thread name "owner-lost-paths").
# On Linux it reads the running image (/proc/PID/exe). On macOS it reads the file at the path, so a file
# that changed after a process started (replaced_after_start > 0) may not be what that process runs.
# Exit 0 even when there are orphans: it is a report.
# Test: bash scripts/measure/tests/orphan-process-scan.test.sh
set -euo pipefail

FIX_29349_MARKER="owner-lost-paths"
MIN_AGE_SECONDS=3600
SPIN_PERCENT=50
PROC="${ORPHAN_SCAN_PROC:-/proc}" # the test points this at an empty folder

# etime_seconds ETIME: seconds from ps etime, [[dd-]hh:]mm:ss.
etime_seconds() {
  local value="$1" days=0 rest h=0 m=0 s=0
  if [[ "$value" == *-* ]]; then
    days="${value%%-*}"
    rest="${value#*-}"
  else
    rest="$value"
  fi
  IFS=: read -r -a parts <<<"$rest"
  case "${#parts[@]}" in
    3) h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}" ;;
    2) m="${parts[0]}"; s="${parts[1]}" ;;
    1) s="${parts[0]}" ;;
    *) echo 0; return ;;
  esac
  echo $(( 10#$days * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#${s%%.*} ))
}

# orphan_candidates: reads `ps -A -o pid=,ppid=,etime=,pcpu=,time=,user=,args=` on stdin and prints the rows
# (same columns) whose ppid is 1, whose etime is more than MIN_AGE_SECONDS and whose command names
# cmux-tui or acpmux. A process of another user shows as "(cmux-tui)" on macOS; that still matches.
orphan_candidates() {
  local pid ppid etime pcpu cputime user args
  while read -r pid ppid etime pcpu cputime user args; do
    [[ "$ppid" == 1 ]] || continue
    [[ "$args" == *cmux-tui* || "$args" == *acpmux* ]] || continue
    (( $(etime_seconds "$etime") > MIN_AGE_SECONDS )) || continue
    printf '%s %s %s %s %s %s %s\n' "$pid" "$ppid" "$etime" "$pcpu" "$cputime" "$user" "$args"
  done
}

# arg_value FLAG ARGS: the value after "FLAG " or "FLAG=" in ARGS, else empty.
arg_value() {
  local flag="$1" args=" $2 " rest
  if [[ "$args" == *" $flag="* ]]; then
    rest="${args#*" $flag="}"
  elif [[ "$args" == *" $flag "* ]]; then
    rest="${args#*" $flag "}"
  else
    return 0
  fi
  echo "${rest%% *}"
}

# process_kind EXE ARGS: terminal_host, acpmux or daemon.
process_kind() {
  local exe="$1" args="$2"
  if [[ "${exe##*/}" == acpmux* || ( "${exe##*/}" != cmux-tui* && "$args" == *acpmux* && "$args" != *cmux-tui* ) ]]; then
    echo acpmux
  elif [[ " $args " == *" __terminal-host "* ]]; then
    echo terminal_host
  else
    echo daemon
  fi
}

# owner_alive ARGS: yes or no for a process named by --owner <...>@<pid>, else -.
owner_alive() {
  local owner pid
  owner="$(arg_value --owner "$1")"
  pid="${owner##*@}"
  if [[ -z "$owner" || "$owner" != *@* || ! "$pid" =~ ^[0-9]+$ ]]; then
    echo -
  elif kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then # ps: a live pid of another user
    echo yes
  else
    echo no
  fi
}

# socket_state PATH: present, missing, unreadable (a folder on the way cannot be searched by this user) or -.
socket_state() {
  local path="$1" dir
  if [[ -z "$path" ]]; then
    echo -
  elif [[ -S "$path" ]]; then
    echo present
  else
    dir="$(dirname "$path")"
    while [[ "$dir" != / && ! -e "$dir" ]]; do dir="$(dirname "$dir")"; done
    if [[ -e "$dir" && ! -x "$dir" ]]; then echo unreadable; else echo missing; fi
  fi
}

host_line() {
  local host os ptmx
  host="$(scutil --get ComputerName 2>/dev/null || hostname)"
  if [[ "$(uname -s)" == Darwin ]]; then
    os="macOS-$(sw_vers -productVersion 2>/dev/null || echo -)"
    ptmx="$(sysctl -n kern.tty.ptmx_max 2>/dev/null || echo -)"
  else
    # shellcheck disable=SC1091
    os="$( (. /etc/os-release 2>/dev/null && echo "${ID:-linux}-${VERSION_ID:-}") || uname -sr)"
    ptmx="$(cat /proc/sys/kernel/pty/max 2>/dev/null || echo -)"
  fi
  echo "ORPHAN-SCAN-HOST host=${host// /_} os=${os// /_} ptmx_max=${ptmx:--}"
}

# executable PID: the path of the process's executable, or empty.
executable() {
  if [[ -L "$PROC/$1/exe" ]]; then
    readlink "$PROC/$1/exe" 2>/dev/null || true
  else
    ps -p "$1" -o comm= 2>/dev/null | sed 's/^ *//' || true
  fi
}

# has_fix IMAGE: yes or no when IMAGE can be read, else -.
has_fix() {
  if [[ "$1" == /* && -r "$1" && -f "$1" ]]; then
    if LC_ALL=C grep -a -q -F "$FIX_29349_MARKER" "$1" 2>/dev/null; then echo yes; else echo no; fi
  else
    echo -
  fi
}

main() {
  host_line
  local now table
  now="$(date +%s)"
  table="$(ps -A -o pid=,ppid=,etime=,pcpu=,time=,user=,args= 2>/dev/null || true)"

  local count=0 terminal_hosts=0 daemons=0 acpmux=0 spinning=0
  local pid ppid etime pcpu cputime user args exe kind socket
  while read -r pid ppid etime pcpu cputime user args; do
    [[ -n "$pid" ]] || continue
    exe="$(executable "$pid")"
    [[ -n "$exe" ]] || exe="${args%% *}"
    case "${exe##*/}" in cmux-tui*|acpmux*|"(cmux-tui"*|"(acpmux"*) ;; *) continue ;; esac
    kind="$(process_kind "$exe" "$args")"
    case "$kind" in
      terminal_host) terminal_hosts=$((terminal_hosts + 1)) ;;
      acpmux) acpmux=$((acpmux + 1)) ;;
      *) daemons=$((daemons + 1)) ;;
    esac
    count=$((count + 1))
    if awk -v c="$pcpu" -v t="$SPIN_PERCENT" 'BEGIN { exit !(c + 0 >= t) }'; then spinning=$((spinning + 1)); fi
    socket="$(arg_value --socket "$args")"
    local cmd="${args:0:250}"
    printf 'ORPHAN pid=%s ppid=%s etime=%s lstart="%s UTC" cpu=%s time=%s owner_alive=%s socket=%s socket_state=%s kind=%s user=%s cmd="%s"\n' \
      "$pid" "$ppid" "$etime" "$(TZ=UTC ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//')" "$pcpu" "$cputime" \
      "$(owner_alive "$args")" "${socket:--}" "$(socket_state "$socket")" "$kind" "$user" "${cmd//\"/\'}"
  done < <(printf '%s\n' "$table" | orphan_candidates)
  echo "ORPHAN-SCAN-SUMMARY count=$count terminal_hosts=$terminal_hosts daemons=$daemons acpmux=$acpmux spinning=$spinning"

  # Every running cmux-tui executable, orphaned or not: which builds run on this host.
  local builds
  builds="$(
    printf '%s\n' "$table" | while read -r pid ppid etime pcpu cputime user args; do
      [[ "$args" == *cmux-tui* ]] || continue
      exe="$(executable "$pid")"
      [[ "${exe##*/}" == cmux-tui* ]] || continue
      local orphan=0 image="$exe" started=$((now - $(etime_seconds "$etime"))) replaced=0 mtime
      [[ "$ppid" == 1 ]] && (( $(etime_seconds "$etime") > MIN_AGE_SECONDS )) && orphan=1
      [[ -e "$PROC/$pid/exe" ]] && image="$PROC/$pid/exe"
      if [[ "$image" == "$exe" && "$exe" == /* ]]; then
        if [[ "$(uname -s)" == Darwin ]]; then
          mtime="$(stat -f %m "$exe" 2>/dev/null || echo 0)"
        else
          mtime="$(stat -c %Y "$exe" 2>/dev/null || echo 0)"
        fi
        [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime > started )) && replaced=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$exe" "$orphan" "$replaced" "$image"
    done
  )"
  if [[ -z "$builds" ]]; then
    echo "ORPHAN-SCAN-BUILDS none"
    return 0
  fi
  local path processes orphans replaced first_image
  while IFS= read -r path; do
    processes=0 orphans=0 replaced=0 first_image=""
    while IFS=$'\t' read -r exe o r image; do
      [[ "$exe" == "$path" ]] || continue
      processes=$((processes + 1)); orphans=$((orphans + o)); replaced=$((replaced + r))
      [[ -n "$first_image" ]] || first_image="$image"
    done <<<"$builds"
    printf 'ORPHAN-SCAN-BUILDS path="%s" processes=%s orphans=%s fix29349=%s replaced_after_start=%s\n' \
      "$path" "$processes" "$orphans" "$(has_fix "$first_image")" "$replaced"
  done < <(printf '%s\n' "$builds" | cut -f1 | sort -u)
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
  exit 0
fi
