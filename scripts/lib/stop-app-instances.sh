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
# activate over the user's app. Running instances get SIGTERM (cmux treats it as
# a requested quit), then SIGKILL after a bounded wait.
cmux_stop_app_instances() {
  local bundle_id="$1" tagged_executable="$2" raw_executable="${3:-}"
  local -a pids=()
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" && "$pid" != "$$" ]] && pids+=("$pid")
  done < <(cmux_app_instance_pids "$bundle_id" "$tagged_executable" "$raw_executable" | sort -un)
  [[ ${#pids[@]} -gt 0 ]] || return 0
  kill -TERM "${pids[@]}" 2>/dev/null || true
  cmux_wait_for_pids_exit 2 "${pids[@]}" && return 0
  kill -KILL "${pids[@]}" 2>/dev/null || true
  cmux_wait_for_pids_exit 2 "${pids[@]}" || true
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
# events rather than polling. Returns 0 when all exited.
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
        sys.exit(1)
    for event in kq.control(None, len(pending), remaining):
        pending.discard(event.ident)
PY
}
