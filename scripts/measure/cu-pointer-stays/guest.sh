#!/bin/bash
# cu-pointer-stays inside the guest's login session (cu-pointer-stays.sh starts it as a LaunchAgent,
# so it runs in the console user's Aqua session, where the agent cursor and the video can draw).
# cps.py does the run; this writes its exit code to $D/status for the host to collect.
set -u
D=/Users/lume/cps
mkdir -p "$D/out"
/usr/bin/python3 -I "$D/cps.py" "$D" >"$D/out/cps.stdout" 2>"$D/out/cps.stderr"
echo $? >"$D/status"
