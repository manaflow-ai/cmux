#!/bin/bash
# Stop the running instances of one app bundle before a reload replaces it.
#
# cmux_stop_app_instances BUNDLE_ID TAGGED_EXECUTABLE [RAW_EXECUTABLE]
#   BUNDLE_ID          the bundle id the instances run under.
#   TAGGED_EXECUTABLE  the executable of the bundle the script publishes.
#   RAW_EXECUTABLE     the executable of the xcodebuild product the tagged
#                      bundle is copied from (it carries the same bundle id).
cmux_stop_app_instances() {
  local bundle_id="$1" tagged_executable="$2"
  /usr/bin/osascript -e "tell application id \"${bundle_id}\" to quit" >/dev/null 2>&1 || true
  sleep 0.3
  pkill -f "$tagged_executable" || true
  for _ in {1..20}; do
    if ! pgrep -f "$tagged_executable" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  pkill -KILL -f "$tagged_executable" >/dev/null 2>&1 || true
}
