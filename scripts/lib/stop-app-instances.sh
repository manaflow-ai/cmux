#!/bin/bash
# Stop the running instances of one app bundle before a reload replaces it,
# without ever starting one.
#
# cmux_stop_app_instances BUNDLE_ID TAGGED_EXECUTABLE [RAW_EXECUTABLE]
#   BUNDLE_ID          the bundle id the instances run under.
#   TAGGED_EXECUTABLE  the executable of the bundle the script publishes, or a
#                      suffix of it ("cmux DEV <tag>.app/Contents/MacOS/cmux DEV")
#                      to match that bundle in every folder.
#   RAW_EXECUTABLE     the executable of the xcodebuild product the tagged bundle
#                      is copied from. It carries the same bundle id until the
#                      next build, so a process running from it is this app's
#                      when its Info.plist still names BUNDLE_ID (a DerivedData
#                      shared between tags may have rebuilt it for another tag).
#
# No Apple Event: `tell application id ... to quit` LAUNCHES a scriptable app
# that is not running (AppleScript asks it for its terminology), and
# LaunchServices picks whichever bundle it registered for the id, often the raw
# xcodebuild product, which lacks the tagged LSEnvironment and the agent's
# environment. That stray took the tag's debug socket in normal mode and could
# activate over the user's app. Running instances get SIGTERM, which the app
# treats as "Quit, keep sessions": it saves its windows and the agent panes'
# wake states (agent-pane-wake-states.json) before it exits. The quit is
# complete when the process exits, so the stop waits for every exit (all
# instances in parallel) up to a deadline. Instances still running then get a
# second SIGTERM, the app's own force exit (QuitSignal.swift), and a short
# grace. The stop never sends SIGKILL by default: a SIGKILL during the quit
# loses the app's quit cleanup (the wake states the next launch restores). An
# instance that survives both signals is left running and the stop returns 1
# with a message, so a caller under `set -e` never replaces a running app's
# bundle.
#
# CMUX_STOP_APP_QUIT_TIMEOUT_SECONDS (default 30) is the clean-quit deadline. A
# clean quit with a Chromium tab open takes 6.5-10 s.
# CMUX_STOP_APP_FORCE_EXIT_TIMEOUT_SECONDS (default 5) is the grace after the
# second SIGTERM.
# CMUX_STOP_APP_FORCE_KILL=1 opts back into SIGKILL for instances that survive
# both signals (the stop then returns 0 once they are gone).
cmux_stop_app_instances() {
  local bundle_id="$1" tagged_executable="$2" raw_executable="${3:-}"
  local timeout force_timeout
  timeout="$(cmux_stop_app_seconds CMUX_STOP_APP_QUIT_TIMEOUT_SECONDS 30)"
  force_timeout="$(cmux_stop_app_seconds CMUX_STOP_APP_FORCE_EXIT_TIMEOUT_SECONDS 5)"
  # Bash 3.2 with set -u treats "${a[@]}" of an empty array as unset, so every
  # expansion below is guarded by a count check.
  local -a pids=() survivors=() stuck=()
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" && "$pid" != "$$" ]] && pids+=("$pid")
  done < <(cmux_app_instance_pids "$bundle_id" "$tagged_executable" "$raw_executable" | sort -un)
  [[ ${#pids[@]} -gt 0 ]] || return 0
  kill -TERM "${pids[@]}" 2>/dev/null || true
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && survivors+=("$pid")
  done < <(cmux_wait_for_pids_exit "$timeout" "${pids[@]}" || true)
  [[ ${#survivors[@]} -gt 0 ]] || return 0
  echo "cmux_stop_app_instances: clean quit of ${bundle_id} timed out after ${timeout}s; sending a second SIGTERM (the app's force exit) to PID(s) ${survivors[*]}" >&2
  kill -TERM "${survivors[@]}" 2>/dev/null || true
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && stuck+=("$pid")
  done < <(cmux_wait_for_pids_exit "$force_timeout" "${survivors[@]}" || true)
  [[ ${#stuck[@]} -gt 0 ]] || return 0
  if [[ "${CMUX_STOP_APP_FORCE_KILL:-0}" == 1 ]]; then
    echo "cmux_stop_app_instances: ${bundle_id} PID(s) ${stuck[*]} still running ${force_timeout}s after the second SIGTERM; sending SIGKILL (CMUX_STOP_APP_FORCE_KILL=1)" >&2
    kill -KILL "${stuck[@]}" 2>/dev/null || true
    cmux_wait_for_pids_exit 2 "${stuck[@]}" >/dev/null && return 0
    echo "cmux_stop_app_instances: ${bundle_id} PID(s) ${stuck[*]} survived SIGKILL" >&2
    return 1
  fi
  echo "cmux_stop_app_instances: ${bundle_id} PID(s) ${stuck[*]} still running ${timeout}s after SIGTERM and ${force_timeout}s after a second SIGTERM; left running, not replaced (no SIGKILL: it would lose the app's quit cleanup). Quit the app, then rerun; CMUX_STOP_APP_FORCE_KILL=1 kills it instead." >&2
  return 1
}

# Prints the seconds in environment variable NAME, or DEFAULT when it is unset
# or empty, or DEFAULT with a warning when it is not a number.
cmux_stop_app_seconds() {
  local name="$1" default="$2" value
  value="${!name:-}"
  if [[ -z "$value" ]]; then
    value="$default"
  elif ! [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "cmux_stop_app_instances: ${name}='${value}' is not a number of seconds; using ${default}" >&2
    value="$default"
  fi
  printf '%s\n' "$value"
}

# PIDs of the running instances: every process LaunchServices lists under the
# bundle id (wherever it runs from), plus processes still starting from either
# executable (not yet checked in with LaunchServices). Read-only.
cmux_app_instance_pids() {
  local bundle_id="$1" tagged_executable="$2" raw_executable="${3:-}" asn raw_bundle_id
  for asn in $(/usr/bin/lsappinfo find "bundleid=${bundle_id}" 2>/dev/null \
      | grep -oE 'ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+'); do
    /usr/bin/lsappinfo info -only pid "$asn" 2>/dev/null | grep -oE '"?pid"? ?= ?[0-9]+' | grep -oE '[0-9]+$'
  done
  pgrep -f -- "$(cmux_regex_escape "$tagged_executable")( |\$)" 2>/dev/null || true
  if [[ -n "$raw_executable" ]]; then
    raw_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "${raw_executable%/MacOS/*}/Info.plist" 2>/dev/null || true)"
    if [[ "$raw_bundle_id" == "$bundle_id" ]]; then
      pgrep -f -- "^$(cmux_regex_escape "$raw_executable")( |\$)" 2>/dev/null || true
    fi
  fi
}

cmux_regex_escape() {
  printf '%s' "$1" | sed 's/[][\.*^$(){}?+|]/\\&/g'
}

# Waits until every PID has exited or TIMEOUT seconds pass, on kqueue exit
# events rather than polling. Returns 0 when all exited; otherwise prints the
# PIDs still running, one per line, and returns 1.
cmux_wait_for_pids_exit() {
  local timeout="$1"; shift
  /usr/bin/python3 - "$timeout" "$@" <<'PY'
import select, sys, time
timeout = float(sys.argv[1])
kq = select.kqueue()
pending = set()
for arg in sys.argv[2:]:
    pid = int(arg)
    try:
        kq.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                  select.KQ_NOTE_EXIT)], 0, 0)
        pending.add(pid)
    except ProcessLookupError:
        pass
deadline = time.monotonic() + timeout
while pending:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        for pid in sorted(pending):
            print(pid)
        sys.exit(1)
    for event in kq.control(None, len(pending), remaining):
        pending.discard(event.ident)
PY
}
