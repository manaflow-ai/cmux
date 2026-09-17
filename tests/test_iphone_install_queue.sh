#!/usr/bin/env bash
# Behavior tests for scripts/iphone-install-queue.sh: enqueue/list/drain/clear,
# unreachable-phone queueing, reconnect drain (install + signed launch +
# notification), and default device id resolution. Uses a fake xcrun/devicectl,
# a fake mobile-dev-launch.sh, and a fake cmux CLI so no simulator, device, or
# running app is touched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUEUE_SCRIPT="$REPO_ROOT/scripts/iphone-install-queue.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-iphone-queue-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export CMUX_IPHONE_QUEUE_DIR="$TMP_DIR/queue"
export CMUX_CONFIG_DIR="$TMP_DIR/config"
unset CMUX_IPHONE_DEVICE_ID CMUX_IPHONE_QUEUE_FORCE_UNREACHABLE CMUX_IPHONE_QUEUE_CHECKOUT 2>/dev/null || true

DEVICE_ID="11111111-2222-3333-4444-555555555555"
STATE_FILE="$TMP_DIR/device-state"   # "reachable" | "unreachable"
PROCESS_STATE_FILE="$TMP_DIR/process-state" # "running" | "stopped"
CALL_LOG="$TMP_DIR/calls.log"
echo "unreachable" > "$STATE_FILE"
echo "running" > "$PROCESS_STATE_FILE"
: > "$CALL_LOG"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# --- fakes -------------------------------------------------------------------
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/xcrun" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "xcrun \$*" >> "$CALL_LOG"
if [[ "\${1:-}" == "devicectl" && "\${2:-}" == "list" ]]; then
  # find --json-output <path>
  out=""
  args=("\$@")
  for ((i=0; i<\${#args[@]}; i++)); do
    if [[ "\${args[i]}" == "--json-output" ]]; then out="\${args[i+1]}"; fi
  done
  state="\$(cat "$STATE_FILE")"
  if [[ "\$state" == "reachable" ]]; then
    boot="booted"
  else
    boot="unavailable"
  fi
  cat > "\$out" <<JSON
{"result": {"devices": [{
  "identifier": "$DEVICE_ID",
  "hardwareProperties": {"platform": "iOS", "udid": "$DEVICE_ID", "reality": "physical"},
  "connectionProperties": {"pairingState": "paired", "transportType": "wired", "tunnelState": "connected"},
  "deviceProperties": {"name": "TestPhone", "bootState": "\$boot", "developerModeStatus": "enabled"}
}]}}
JSON
  exit 0
fi
if [[ "\${1:-}" == "devicectl" && "\${2:-}" == "device" && "\${3:-}" == "install" ]]; then
  exit 0
fi
if [[ "\${1:-}" == "devicectl" && "\${2:-}" == "device" && "\${3:-}" == "info" && "\${4:-}" == "apps" ]]; then
  out=""
  args=("\$@")
  for ((i=0; i<\${#args[@]}; i++)); do
    if [[ "\${args[i]}" == "--json-output" ]]; then out="\${args[i+1]}"; fi
  done
  cat > "\$out" <<JSON
{"result": {"apps": [{
  "bundleIdentifier": "dev.cmux.ios.tstq",
  "url": "file:///private/var/containers/Bundle/Application/CURRENT/cmux.app/"
}]}}
JSON
  exit 0
fi
if [[ "\${1:-}" == "devicectl" && "\${2:-}" == "device" && "\${3:-}" == "info" && "\${4:-}" == "processes" ]]; then
  out=""
  args=("\$@")
  for ((i=0; i<\${#args[@]}; i++)); do
    if [[ "\${args[i]}" == "--json-output" ]]; then out="\${args[i+1]}"; fi
  done
  if [[ "\$(cat "$PROCESS_STATE_FILE")" == "running" ]]; then
    processes='[{"executable":"file:///private/var/containers/Bundle/Application/CURRENT/cmux.app/cmux","processIdentifier":4242}]'
  else
    processes='[]'
  fi
  printf '{"result":{"runningProcesses":%s}}\n' "\$processes" > "\$out"
  exit 0
fi
if [[ "\${1:-}" == "devicectl" && "\${2:-}" == "device" && "\${3:-}" == "process" && "\${4:-}" == "terminate" ]]; then
  [[ " \$* " == *" --pid 4242 "* ]] || exit 1
  echo "stopped" > "$PROCESS_STATE_FILE"
  exit 0
fi
if [[ "\${1:-}" == "devicectl" && "\${2:-}" == "device" && "\${3:-}" == "process" && "\${4:-}" == "launch" ]]; then
  exit 0
fi
echo "fake xcrun: unhandled: \$*" >&2
exit 1
EOF
chmod +x "$FAKE_BIN/xcrun"

cat > "$FAKE_BIN/cmux" <<EOF
#!/usr/bin/env bash
echo "cmux \$*" >> "$CALL_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN/cmux"

export PATH="$FAKE_BIN:$PATH"

# Fake checkout with a mobile-dev-launch.sh that records its invocation.
FAKE_CHECKOUT="$TMP_DIR/checkout"
mkdir -p "$FAKE_CHECKOUT/scripts"
cat > "$FAKE_CHECKOUT/scripts/mobile-dev-launch.sh" <<EOF
#!/usr/bin/env bash
echo "mobile-dev-launch \$*" >> "$CALL_LOG"
exit 0
EOF
chmod +x "$FAKE_CHECKOUT/scripts/mobile-dev-launch.sh"

# Fake signed app.
APP="$TMP_DIR/cmux.app"
mkdir -p "$APP"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.cmux.ios.tstq</string>
</dict></plist>
PLIST
echo "binary" > "$APP/cmux"

# --- default-device resolution -----------------------------------------------
[[ -z "$("$QUEUE_SCRIPT" default-device | head -n1 | tr -d '[:space:]')" ]] \
  || fail "default-device should be empty with no config"
mkdir -p "$CMUX_CONFIG_DIR"
printf '%s\n' "$DEVICE_ID" > "$CMUX_CONFIG_DIR/iphone-device-id"
[[ "$("$QUEUE_SCRIPT" default-device | head -n1 | tr -d '[:space:]')" == "$DEVICE_ID" ]] \
  || fail "default-device should read the config file"
CMUX_IPHONE_DEVICE_ID="env-wins" "$QUEUE_SCRIPT" default-device | head -n1 | grep -q "env-wins" \
  || fail "CMUX_IPHONE_DEVICE_ID env should win over the config file"
ok "default-device resolution (env > config file)"

# --- enqueue -----------------------------------------------------------------
"$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" >/dev/null
ENTRY="$CMUX_IPHONE_QUEUE_DIR/pending/tstq"
[[ -d "$ENTRY/cmux.app" && -f "$ENTRY/meta.json" ]] || fail "enqueue should create pending entry"
grep -q '"device_id": "'"$DEVICE_ID"'"' "$ENTRY/meta.json" || fail "meta should carry the default device id"
"$QUEUE_SCRIPT" list | grep -q "pending  tstq" || fail "list should show the pending entry"
ok "enqueue creates a pending entry with metadata"

# Re-enqueue replaces rather than duplicating.
"$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" >/dev/null
[[ "$(ls "$CMUX_IPHONE_QUEUE_DIR/pending" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "re-enqueue of the same tag should replace the entry"
ok "re-enqueue replaces the existing entry"

# --- drain with the phone unreachable: entry must stay queued -----------------
"$QUEUE_SCRIPT" drain >/dev/null 2>&1 || fail "drain with unreachable phone should exit 0"
[[ -d "$ENTRY" ]] || fail "entry must stay queued while the phone is unreachable"
grep -q "devicectl device install" "$CALL_LOG" && fail "must not install while unreachable"
ok "drain keeps the build queued while the phone is unreachable"

# --- FORCE_UNREACHABLE test hook ----------------------------------------------
echo "reachable" > "$STATE_FILE"
CMUX_IPHONE_QUEUE_FORCE_UNREACHABLE=1 "$QUEUE_SCRIPT" drain >/dev/null 2>&1 \
  || fail "forced-unreachable drain should exit 0"
[[ -d "$ENTRY" ]] || fail "FORCE_UNREACHABLE must keep the entry queued"
ok "CMUX_IPHONE_QUEUE_FORCE_UNREACHABLE keeps the entry queued"

# --- drain on reconnect: install + signed launch + notify ---------------------
"$QUEUE_SCRIPT" drain >/dev/null 2>&1 || fail "drain with reachable phone should succeed"
[[ ! -d "$ENTRY" ]] || fail "entry should be removed after a successful install"
grep -q "xcrun devicectl device install app --device $DEVICE_ID" "$CALL_LOG" \
  || fail "drain should devicectl-install on the recorded device"
terminate_line="$(grep -n "devicectl device process terminate --device $DEVICE_ID --pid 4242" "$CALL_LOG" | head -n1 | cut -d: -f1 || true)"
install_line="$(grep -n "devicectl device install app --device $DEVICE_ID" "$CALL_LOG" | head -n1 | cut -d: -f1 || true)"
[[ -n "$terminate_line" && "$terminate_line" -lt "$install_line" ]] \
  || fail "drain must terminate the registered tagged app before replacing its bundle"
grep -q -- "mobile-dev-launch --tag tstq --device --device-id $DEVICE_ID --ensure-mac" "$CALL_LOG" \
  || fail "drain should signed-launch via mobile-dev-launch.sh with --ensure-mac"
grep -q "cmux notify --title" "$CALL_LOG" || fail "drain should send a cmux notification"
ok "reconnect drain terminates before install, signed-launches with --ensure-mac, and notifies"

# --- failed signed launch never falls back to plain launch --------------------
echo "unreachable" > "$STATE_FILE"
"$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" >/dev/null
echo "reachable" > "$STATE_FILE"
cat > "$FAKE_CHECKOUT/scripts/mobile-dev-launch.sh" <<EOF
#!/usr/bin/env bash
echo "mobile-dev-launch \$*" >> "$CALL_LOG"
exit 1
EOF
chmod +x "$FAKE_CHECKOUT/scripts/mobile-dev-launch.sh"
: > "$CALL_LOG"
if "$QUEUE_SCRIPT" drain >/dev/null 2>&1; then
  fail "drain should exit non-zero when the signed launch fails"
fi
[[ -d "$CMUX_IPHONE_QUEUE_DIR/failed/tstq" ]] || fail "failed entry should move to failed/"
grep -q "devicectl device process launch" "$CALL_LOG" \
  && fail "a failed signed launch must never fall back to a plain launch"
"$QUEUE_SCRIPT" list | grep -q "failed   tstq" || fail "list should show the failed entry"
ok "failed signed launch moves to failed/ without a plain-launch fallback"

# --- clear ---------------------------------------------------------------
"$QUEUE_SCRIPT" clear >/dev/null
"$QUEUE_SCRIPT" list | grep -q "queue is empty" || fail "clear should empty the queue"
ok "clear empties pending and failed entries"

# --- probe verb ----------------------------------------------------------
echo "reachable" > "$STATE_FILE"
"$QUEUE_SCRIPT" probe --device-id "$DEVICE_ID" || fail "probe should succeed while reachable"
echo "unreachable" > "$STATE_FILE"
if "$QUEUE_SCRIPT" probe --device-id "$DEVICE_ID"; then
  fail "probe should fail while unreachable"
fi
ok "probe reports device reachability"

echo "PASS: iphone-install-queue behavior tests"
