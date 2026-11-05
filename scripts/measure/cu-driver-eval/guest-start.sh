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
CU_DRIVER_EVAL_ROOT="$tree" CU_DRIVER_EVAL_REV="$rev" CU_DRIVER_EVAL_DISPLAY=1920x1080 \\
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
# A non-root SSH session may not bootstrap into the gui domain ("125: Domain does not support
# specified action"); root may, directly or from inside the user's bootstrap namespace.
# The image logs lume in at boot, but SSH answers before that session is up, and bootstrapping into
# it then fails the same way: wait for the session (its Dock), then try for up to two minutes.
uid=$(id -u)
session=no
for _ in $(seq 1 24); do
  pgrep -u "$uid" -x Dock >/dev/null && sudo -n launchctl print "gui/$uid" >/dev/null 2>&1 && { session=yes; break; }
  sleep 5
done
echo "guest-start.sh: login session ready: $session" >&2
sudo -n launchctl bootout "gui/$uid/com.cmux.cu-eval" 2>/dev/null || true
for attempt in $(seq 1 24); do
  sudo -n launchctl bootstrap "gui/$uid" "$tree/agent.plist" 2>/dev/null && exit 0
  sudo -n launchctl asuser "$uid" launchctl bootstrap "gui/$uid" "$tree/agent.plist" 2>/dev/null && exit 0
  # An attempt that loaded the agent but still reported an error counts.
  sudo -n launchctl print "gui/$uid/com.cmux.cu-eval" >/dev/null 2>&1 && exit 0
  sleep 5
done
echo "guest-start.sh: launchctl bootstrap gui/$uid failed $attempt times; the session as it stands:" >&2
{ stat -f 'console owner %Su' /dev/console; who; pgrep -lu "$uid" | head -30; sudo -n launchctl print "gui/$uid" 2>&1 | head -15; } >&2 || true
sudo -n launchctl bootstrap "gui/$uid" "$tree/agent.plist" # once more, with its error shown
