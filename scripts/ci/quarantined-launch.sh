#!/usr/bin/env bash
# Launch the app in a DMG as a quarantined browser download would be launched:
# the DMG is quarantined, mounted, the app copied out, then started with `open`
# (LaunchServices runs Gatekeeper's first-launch assessment). Exits 0 only when
# the app is running 5 s after it started, within a minute of `open`.
#
#   quarantined-launch.sh DMG TITLE
#
# Run it only in a job without secrets, on a fresh runner (it runs the app).
# Needs APP_NAME. Writes launch.txt and syspolicyd.txt in the current
# directory and a "TITLE" section in the step summary.
set -euo pipefail

dmg_in="$1"
title="$2"
: "${APP_NAME:?}"

dl="$HOME/Downloads/$(basename "$dmg_in")"
mkdir -p "$HOME/Downloads" "$HOME/Applications"
cp "$dmg_in" "$dl"
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$dl"
xattr -p com.apple.quarantine "$dl"
hdiutil attach -nobrowse -readonly -mountpoint /Volumes/parity "$dl"
ditto "/Volumes/parity/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"
hdiutil detach /Volumes/parity
target="$HOME/Applications/$APP_NAME.app"
if ! xattr -p com.apple.quarantine "$target" >/dev/null 2>&1; then
  echo "the copy carries no quarantine; setting the DMG's"
  xattr -w com.apple.quarantine "$(xattr -p com.apple.quarantine "$dl")" "$target"
fi
echo "app quarantine: $(xattr -p com.apple.quarantine "$target")" | tee launch.txt
spctl -a -vv -t exec "$target" 2>&1 | tee -a launch.txt
# `open` can stay in the foreground after the app starts, so it runs
# in the background; both pids are recorded and only they are stopped.
open "$target" > open.log 2>&1 &
open_pid=$!
echo "open pid: $open_pid" | tee -a launch.txt
app_pid=""
for _ in $(seq 1 60); do
  app_pid="$(pgrep -f "^$target/Contents/MacOS/cmux( |\$)" | head -n 1 || true)"
  [[ -n "$app_pid" ]] && break
  sleep 1
done
echo "app pid: ${app_pid:-none}" | tee -a launch.txt
if [[ -n "$app_pid" ]]; then ps -o pid=,ppid=,etime=,command= -p "$app_pid" | tee -a launch.txt; fi
sleep 5
if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then running=true; else running=false; fi
echo "running 5 s after launch: $running" | tee -a launch.txt
# LaunchServices marks the quarantine as assessed once Gatekeeper lets the app run.
echo "app quarantine after launch: $(xattr -p com.apple.quarantine "$target")" | tee -a launch.txt
log show --last 3m --style compact --predicate 'process == "syspolicyd" AND eventMessage CONTAINS[c] "cmux"' 2>/dev/null | tail -40 > syspolicyd.txt || true
{ echo "### $title"; echo '```'; cat launch.txt; echo '--- syspolicyd'; cat syspolicyd.txt; echo '```'; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
kill "$open_pid" 2>/dev/null || true
[[ "$running" == true ]]
