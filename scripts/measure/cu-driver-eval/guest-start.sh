#!/usr/bin/env bash
# Starts the input A/B inside a cu-driver-bench VM (scripts/measure/cu-driver-bench.sh suite=input-ab),
# in the console user's login session: a LaunchAgent, since a process started over SSH has no window
# server session and its windows would never show. Run over SSH as that user, from the copy of the
# tree in ~/cu-eval:
#   guest-start.sh REV REPS DRIVERS
# The A/B writes ~/cu-eval/eval.log, then its exit status to ~/cu-eval/eval.status.
set -euo pipefail
rev=$1 reps=$2 drivers=$3
tree="$HOME/cu-eval"
rm -f "$tree/eval.status" "$tree/eval.log"
cat >"$tree/run.sh" <<EOF
#!/bin/bash
cd "$tree"
CU_DRIVER_EVAL_ROOT="$tree" CU_DRIVER_EVAL_REV="$rev" \\
  CU_DRIVER_EVAL_GRANT="bash $tree/scripts/measure/cu-driver-eval/tcc-grant.sh" \\
  bash scripts/measure/cu-driver-eval.sh "reps=$reps" "drivers=$drivers" electron=1 >"$tree/eval.log" 2>&1
echo \$? >"$tree/eval.status"
EOF
cat >"$tree/agent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.cmux.cu-eval</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$tree/run.sh</string></array>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
# bash runs the A/B, so bash is the responsible process TCC asks about; grant it before it starts.
bash "$tree/scripts/measure/cu-driver-eval/tcc-grant.sh" /bin/bash
launchctl bootout "gui/$(id -u)/com.cmux.cu-eval" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$tree/agent.plist"
