#!/usr/bin/env bash
# Orphaned cmux-tui and acpmux processes on this host (STATUS 1370, #29349 follow-up): every cmux-tui or
# acpmux process whose parent is 1 (launchd or init) and that has run for more than 1 hour. Read-only: it
# signals nothing, kills nothing and writes no file. macOS and Linux.
# Run alone on one worker (the process table is machine-wide):
#   cmux-ci run --class exclusive --measurement --script scripts/measure/orphan-process-scan.sh --ref SHA
#     --target-worker WORKER
# Output, one line each:
#   ORPHAN-SCAN-HOST host=... os=... ptmx_max=...
#   ORPHAN pid=... ppid=1 etime=... lstart="... UTC" cpu=... time=... owner_alive=yes|no|reused|-
#     socket=PATH|- socket_state=present|missing|unreadable|- group=... kind=... user=... cmd="first 250 chars"
#   ORPHAN-SCAN-SUMMARY count=N terminal_hosts=N daemons=N acpmux=N unknown=N spinning=N via_cmux=N unreadable=N
#   ORPHAN-SCAN-BUILDS path="..." processes=N orphans=N fix29349=yes|no|- replaced_after_start=N
# count (and its kinds and spinning) is the BEFORE scan's rule: started as cmux-tui* or acpmux*. via_cmux
# (the multicall bin/cmux in a daemon role) and unreadable (another user's "(cmux)") are listed apart.
# spinning is %cpu >= 50: a recent average on macOS, the average over the process's life on Linux.
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
# (same columns) whose ppid is 1, whose etime is more than MIN_AGE_SECONDS and whose command mentions cmux or
# acpmux. classify decides which of them count.
orphan_candidates() {
  local pid ppid etime pcpu cputime user args
  while read -r pid ppid etime pcpu cputime user args; do
    [[ "$ppid" == 1 ]] || continue
    [[ "$args" == *cmux* || "$args" == *acpmux* ]] || continue
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

# invoked_name PID ARGS: the name the process was started as. `ps -o comm=` is the path the process was
# started through on macOS (bin/cmux-tui and bin/acpmux are symlinks to bin/cmux and keep their names) and
# the basename of that path on Linux; another user's process on macOS gives only the kernel's short name.
invoked_name() {
  local name
  name="$(ps -p "$1" -o comm= 2>/dev/null | sed 's/^ *//;s/ *$//' || true)"
  [[ -n "$name" ]] || name="${2%% *}"
  echo "$name"
}

# classify NAME ARGS: "<group> <kind>", or "skip". group is counted (started as cmux-tui* or acpmux*, the
# rule of the BEFORE scan), via_cmux (the multicall bin/cmux in a daemon role: acp, __terminal-host or
# --headless) or unreadable (ps shows another user's process only as "(cmux)", which may also be the app or
# the CLI). kind is acpmux (the name, or a first argument acp), terminal_host, daemon, or unknown when the
# command line cannot be read.
classify() {
  local name="${1##*/}" args="$2" kind
  local acp_re='(^|/)(cmux|cmux-tui[^ /]*|acpmux[^ /]*) acp( |$)' role_re='(^|/)cmux (acp|__terminal-host|--headless)( |$)'
  name="${name#(}"; name="${name%)}"
  if [[ "$args" == "("*")" ]]; then
    case "$name" in
      cmux-tui*|acpmux*) echo "counted unknown" ;;
      cmux) echo "unreadable unknown" ;;
      *) echo skip ;;
    esac
    return 0
  fi
  if [[ "$name" == acpmux* || "$args" =~ $acp_re ]]; then
    kind=acpmux
  elif [[ " $args " == *" __terminal-host "* ]]; then
    kind=terminal_host
  else
    kind=daemon
  fi
  case "$name" in
    cmux-tui*|acpmux*) echo "counted $kind" ;;
    cmux)
      if [[ "$args" =~ $role_re ]]; then echo "via_cmux $kind"; else echo skip; fi ;;
    *) echo skip ;;
  esac
}

# owner_alive ARGS ETIME_SECONDS: for --owner <...>@<pid>, yes (that pid runs and started before this
# process), reused (that pid runs but started later, so it is another process), no (no such pid), else -.
# --owner names the daemon that spawned the host; after a daemon restart another daemon may have adopted it,
# so "no" does not prove that nothing serves the host.
owner_alive() {
  local owner pid owner_etime
  owner="$(arg_value --owner "$1")"
  pid="${owner##*@}"
  if [[ -z "$owner" || "$owner" != *@* || ! "$pid" =~ ^[0-9]+$ ]]; then
    echo -
    return 0
  fi
  owner_etime="$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || true)" # ps: also another user's pid
  if [[ -z "$owner_etime" ]]; then
    echo no
  elif (( $(etime_seconds "$owner_etime") >= $2 )); then
    echo yes
  else
    echo reused
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
  host="$(scutil --get ComputerName 2>/dev/null || hostname 2>/dev/null || uname -n)"
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

# image PID NAME: the file the process runs: /proc/PID/exe resolved on Linux, else NAME (a path on macOS).
image() {
  local resolved=""
  [[ -L "$PROC/$1/exe" ]] && resolved="$(readlink "$PROC/$1/exe" 2>/dev/null || true)"
  echo "${resolved:-$2}"
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

  local count=0 terminal_hosts=0 daemons=0 acpmux=0 unknown=0 spinning=0 via_cmux=0 unreadable=0
  local pid ppid etime pcpu cputime user args name group kind socket cmd
  while read -r pid ppid etime pcpu cputime user args; do
    [[ -n "$pid" ]] || continue
    name="$(invoked_name "$pid" "$args")"
    read -r group kind <<<"$(classify "$name" "$args")"
    case "$group" in
      counted)
        count=$((count + 1))
        case "$kind" in
          terminal_host) terminal_hosts=$((terminal_hosts + 1)) ;;
          acpmux) acpmux=$((acpmux + 1)) ;;
          daemon) daemons=$((daemons + 1)) ;;
          *) unknown=$((unknown + 1)) ;;
        esac
        if awk -v c="$pcpu" -v t="$SPIN_PERCENT" 'BEGIN { exit !(c + 0 >= t) }'; then spinning=$((spinning + 1)); fi
        ;;
      via_cmux) via_cmux=$((via_cmux + 1)) ;;
      unreadable) unreadable=$((unreadable + 1)) ;;
      *) continue ;;
    esac
    socket="$(arg_value --socket "$args")"
    cmd="${args:0:250}"
    printf 'ORPHAN pid=%s ppid=%s etime=%s lstart="%s UTC" cpu=%s time=%s owner_alive=%s socket=%s socket_state=%s group=%s kind=%s user=%s cmd="%s"\n' \
      "$pid" "$ppid" "$etime" "$(TZ=UTC ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//')" "$pcpu" "$cputime" \
      "$(owner_alive "$args" "$(etime_seconds "$etime")")" "${socket:--}" "$(socket_state "$socket")" "$group" "$kind" "$user" "${cmd//\"/\'}"
  done < <(printf '%s\n' "$table" | orphan_candidates)
  echo "ORPHAN-SCAN-SUMMARY count=$count terminal_hosts=$terminal_hosts daemons=$daemons acpmux=$acpmux unknown=$unknown spinning=$spinning via_cmux=$via_cmux unreadable=$unreadable"

  # Every running cmux-tui, acpmux or multicall cmux process, orphaned or not: which builds run on this host.
  local builds
  builds="$(
    printf '%s\n' "$table" | while read -r pid ppid etime pcpu cputime user args; do
      [[ "$args" == *cmux* || "$args" == *acpmux* ]] || continue
      name="$(invoked_name "$pid" "$args")"
      read -r group kind <<<"$(classify "$name" "$args")"
      [[ "$group" == counted || "$group" == via_cmux ]] || continue
      local orphan=0 file started=$((now - $(etime_seconds "$etime"))) replaced=0 mtime
      [[ "$ppid" == 1 ]] && (( $(etime_seconds "$etime") > MIN_AGE_SECONDS )) && orphan=1
      file="$(image "$pid" "$name")"
      local read_from="$file"
      [[ -e "$PROC/$pid/exe" ]] && read_from="$PROC/$pid/exe"
      if [[ "$read_from" == "$file" && "$file" == /* ]]; then
        if [[ "$(uname -s)" == Darwin ]]; then
          mtime="$(stat -L -f %m "$file" 2>/dev/null || echo 0)"
        else
          mtime="$(stat -L -c %Y "$file" 2>/dev/null || echo 0)"
        fi
        [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime > started )) && replaced=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$file" "$orphan" "$replaced" "$read_from"
    done
  )"
  if [[ -z "$builds" ]]; then
    echo "ORPHAN-SCAN-BUILDS none"
    return 0
  fi
  local path processes orphans replaced first_read file o r read_from
  while IFS= read -r path; do
    processes=0 orphans=0 replaced=0 first_read=""
    while IFS=$'\t' read -r file o r read_from; do
      [[ "$file" == "$path" ]] || continue
      processes=$((processes + 1)); orphans=$((orphans + o)); replaced=$((replaced + r))
      [[ -n "$first_read" ]] || first_read="$read_from"
    done <<<"$builds"
    printf 'ORPHAN-SCAN-BUILDS path="%s" processes=%s orphans=%s fix29349=%s replaced_after_start=%s\n' \
      "$path" "$processes" "$orphans" "$(has_fix "$first_read")" "$replaced"
  done < <(printf '%s\n' "$builds" | cut -f1 | sort -u)
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
  exit 0
fi
