#!/usr/bin/env bash
# Probe: can xctrace record headless on this worker? (frame-owner-s4 S4 profile, scratch, never merge)
set -uo pipefail
xc=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1)
export DEVELOPER_DIR="$xc/Contents/Developer"
echo "DEVELOPER_DIR=$DEVELOPER_DIR"
xcrun xctrace version || echo "XCTRACE: no version"
xcrun xctrace list templates 2>&1 | grep -iE "metal|time profiler|system trace|animation|game" | head -12
out=$(mktemp -d)/probe.trace
timeout 60 xcrun xctrace record --template 'Time Profiler' --all-processes --time-limit 5s --output "$out" --no-prompt > /tmp/xct-probe.log 2>&1; echo "TIMEPROFILER exit=$?"; tail -3 /tmp/xct-probe.log
out2=$(mktemp -d)/probe2.trace
timeout 90 xcrun xctrace record --template 'Metal System Trace' --all-processes --time-limit 5s --output "$out2" --no-prompt > /tmp/xct-probe2.log 2>&1; echo "METAL exit=$?"; tail -3 /tmp/xct-probe2.log
ls -la "$out" "$out2" 2>&1 | head -4
