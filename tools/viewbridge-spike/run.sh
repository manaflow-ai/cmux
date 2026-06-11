#!/bin/bash
# Orchestrate one VB spike run: install the launchd broker, launch the service
# child, launch the host, stream ViewBridge os_log, then tear everything down.
set -uo pipefail
cd "$(dirname "$0")"
DIR="$(pwd)"
OUT="$DIR/build"
UID_NUM="$(id -u)"
PLIST="$HOME/Library/LaunchAgents/com.cmux.vbridge.broker.plist"
LABEL="com.cmux.vbridge.broker"

cleanup() {
  echo "[run] cleanup"
  [ -n "${HOST_PID:-}" ] && kill "$HOST_PID" 2>/dev/null
  [ -n "${SVC_PID:-}" ] && kill "$SVC_PID" 2>/dev/null
  [ -n "${LOG_PID:-}" ] && kill "$LOG_PID" 2>/dev/null
  launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null
  rm -f "$PLIST"
  pkill -f "$OUT/vbservice" 2>/dev/null
  pkill -f "$OUT/vbhost" 2>/dev/null
  pkill -f "$OUT/broker" 2>/dev/null
}
trap cleanup EXIT

# 1. install + bootstrap broker LaunchAgent (mach name routing requires launchd)
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$OUT/broker</string></array>
  <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
  <key>StandardErrorPath</key><string>/tmp/vbridge-broker.err</string>
  <key>StandardOutPath</key><string>/tmp/vbridge-broker.out</string>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
echo "[run] broker bootstrapped"

# 2. stream ViewBridge + our-process os_log to a file
log stream --style compact --level debug \
  --predicate 'subsystem == "com.apple.ViewBridge" OR processImagePath CONTAINS "vbservice" OR processImagePath CONTAINS "vbhost" OR processImagePath CONTAINS "broker"' \
  > /tmp/vbridge-oslog.txt 2>&1 &
LOG_PID=$!

# 3. launch service child. Default = plain CLI rung. Set VBSERVICE_BIN to the
#    bundled binary (build/VBService.app/Contents/MacOS/vbservice) for rung 2.
SVC_BIN="${VBSERVICE_BIN:-$OUT/vbservice}"
echo "[run] service binary: $SVC_BIN"
"$SVC_BIN" > /tmp/vbridge-service.log 2>&1 &
SVC_PID=$!
echo "[run] service pid $SVC_PID"

# give the service a moment to register its endpoint with the broker
for _ in $(seq 1 20); do
  grep -q "stored service endpoint" /tmp/vbridge-broker.err 2>/dev/null && break
  sleep 0.25
done

# 4. launch host (auto-exits after ~7s)
"$OUT/vbhost" > /tmp/vbridge-host.log 2>&1 &
HOST_PID=$!
echo "[run] host pid $HOST_PID"

# wait for host to finish its bounded run
wait "$HOST_PID" 2>/dev/null
echo "[run] host exited"
sleep 1
echo "=================== SERVICE LOG ==================="; cat /tmp/vbridge-service.log
echo "=================== HOST LOG ======================"; cat /tmp/vbridge-host.log
echo "=================== BROKER ERR ===================="; cat /tmp/vbridge-broker.err 2>/dev/null
echo "=================== VIEWBRIDGE OSLOG (tail) ======="; tail -n 80 /tmp/vbridge-oslog.txt 2>/dev/null
