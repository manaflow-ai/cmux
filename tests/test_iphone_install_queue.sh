#!/usr/bin/env bash
# Behavior tests for scripts/iphone-install-queue.sh: enqueue/list/drain/clear,
# unreachable-phone queueing, reconnect drain (install + signed launch +
# verified notification), the needs-auth state for installs whose iPhone auth
# gate failed (kept + truthfully notified + retryable), the human-only
# unauthenticated-enqueue gate, and default device id resolution. Uses a fake
# xcrun/devicectl, a fake mobile-dev-launch.sh, and a fake cmux CLI so no
# simulator, device, or running app is touched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUEUE_SCRIPT="$REPO_ROOT/scripts/iphone-install-queue.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-iphone-queue-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export CMUX_IPHONE_QUEUE_DIR="$TMP_DIR/queue"
export CMUX_CONFIG_DIR="$TMP_DIR/config"
export CMUX_READINESS_RECEIPT_DIR="$TMP_DIR/receipts"
unset CMUX_IPHONE_DEVICE_ID CMUX_IPHONE_QUEUE_FORCE_UNREACHABLE CMUX_IPHONE_QUEUE_CHECKOUT CMUX_ALLOW_UNAUTHENTICATED_INSTALL 2>/dev/null || true

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

# Fake checkout with a mobile-dev-launch.sh that records its invocation and,
# like the real launcher, writes a readiness receipt only when its auth gate
# passes (the drain requires that receipt to count an install as verified).
FAKE_CHECKOUT="$TMP_DIR/checkout"
mkdir -p "$FAKE_CHECKOUT/scripts"
write_fake_mdl() {
  local exit_code="$1" write_receipt="$2"
  cat > "$FAKE_CHECKOUT/scripts/mobile-dev-launch.sh" <<EOF
#!/usr/bin/env bash
echo "mobile-dev-launch \$*" >> "$CALL_LOG"
if [[ " \$* " == *" --check-auth-contract "* ]]; then
  printf '%s\n' \
    'CMUX_DEV_AUTH_PROFILE=personal' \
    'CMUX_DEV_AUTH_ACCOUNT=person@manaflow.ai'
  exit 0
fi
if [[ "$write_receipt" == "1" ]]; then
  mkdir -p "$CMUX_READINESS_RECEIPT_DIR"
  echo '{"schema":"cmux-ios-dogfood-readiness-v1"}' \
    > "$CMUX_READINESS_RECEIPT_DIR/tstq-$DEVICE_ID.json"
fi
if [[ "$exit_code" != "0" ]]; then
  echo "error: iPhone auth gate FAILED: fake sign-in failure"
fi
exit "$exit_code"
EOF
  chmod +x "$FAKE_CHECKOUT/scripts/mobile-dev-launch.sh"
}
write_fake_mdl 0 1
export CMUX_IPHONE_QUEUE_MOBILE_LAUNCHER="$FAKE_CHECKOUT/scripts/mobile-dev-launch.sh"

AUTH_PROFILE="personal"
EXPECTED_ACCOUNT="person@manaflow.ai"
CREDENTIALS_FILE="$TMP_DIR/personal.env"
cat > "$CREDENTIALS_FILE" <<'ENV'
CMUX_DOGFOOD_STACK_EMAIL=person@manaflow.ai
CMUX_DOGFOOD_STACK_PASSWORD=person-pw
ENV
chmod 600 "$CREDENTIALS_FILE"
AUTH_ARGS=(
  --auth-profile "$AUTH_PROFILE"
  --expected-account "$EXPECTED_ACCOUNT"
  --credentials-file "$CREDENTIALS_FILE"
)

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
"$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" "${AUTH_ARGS[@]}" >/dev/null
ENTRY="$CMUX_IPHONE_QUEUE_DIR/pending/tstq"
[[ -d "$ENTRY/cmux.app" && -f "$ENTRY/meta.json" ]] || fail "enqueue should create pending entry"
grep -q '"device_id": "'"$DEVICE_ID"'"' "$ENTRY/meta.json" || fail "meta should carry the default device id"
grep -q '"auth_profile": "personal"' "$ENTRY/meta.json" || fail "meta should freeze the selected auth profile"
grep -q '"expected_account": "person@manaflow.ai"' "$ENTRY/meta.json" || fail "meta should freeze the expected account"
grep -q '"credentials_file": "'"$CREDENTIALS_FILE"'"' "$ENTRY/meta.json" || fail "meta should freeze the credential source"
"$QUEUE_SCRIPT" list | grep -q "pending  tstq" || fail "list should show the pending entry"
"$QUEUE_SCRIPT" list | grep -q "profile=personal account=person@manaflow.ai" \
  || fail "list should make the queued identity visible"
ok "enqueue creates a pending entry with immutable identity metadata"

# Re-enqueue replaces rather than duplicating.
"$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" "${AUTH_ARGS[@]}" >/dev/null
[[ "$(ls "$CMUX_IPHONE_QUEUE_DIR/pending" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "re-enqueue of the same tag should replace the entry"
ok "re-enqueue replaces the existing entry"

# A staged authenticated build must be signed-launched when the phone
# reconnects, rather than being left at the login screen after install.
"$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" \
  "${AUTH_ARGS[@]}" --no-launch >/dev/null
grep -q '"launch": false' "$ENTRY/meta.json" \
  || fail "staged enqueue should persist launch=false"
grep -q '"allow_unauthenticated": false' "$ENTRY/meta.json" \
  || fail "staged authenticated enqueue must not be marked unauthenticated"
echo "reachable" > "$STATE_FILE"
: > "$CALL_LOG"
"$QUEUE_SCRIPT" drain >/dev/null 2>&1 \
  || fail "staged authenticated entry should drain through the signed launcher"
grep -q -- "mobile-dev-launch --tag tstq --device --device-id $DEVICE_ID --ensure-mac" "$CALL_LOG" \
  || fail "staged authenticated drain should invoke mobile-dev-launch with --ensure-mac"
grep -q -- "--auth-profile personal --expected-account person@manaflow.ai" "$CALL_LOG" \
  || fail "staged authenticated drain should preserve the personal auth contract"
echo "unreachable" > "$STATE_FILE"
echo "running" > "$PROCESS_STATE_FILE"
"$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" \
  "${AUTH_ARGS[@]}" >/dev/null
ok "staged authenticated entries launch and verify after reconnect"

# --- physical-device profile is personal-only --------------------------------
AGENT_ENQUEUE_ERROR="$TMP_DIR/agent-enqueue.err"
: > "$CALL_LOG"
if "$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" \
    --auth-profile agent --expected-account "$EXPECTED_ACCOUNT" \
    --credentials-file "$CREDENTIALS_FILE" >/dev/null 2>"$AGENT_ENQUEUE_ERROR"; then
  fail "physical iPhone queue must reject the simulator-only agent profile"
fi
grep -q "physical iPhone authenticated installs require --auth-profile personal" \
  "$AGENT_ENQUEUE_ERROR" \
  || fail "agent-profile enqueue should fail with the personal-only contract"
grep -q -- "--check-auth-contract" "$CALL_LOG" \
  && fail "agent-profile rejection must happen before launcher credential validation"
grep -q '"auth_profile": "personal"' "$ENTRY/meta.json" \
  || fail "rejected agent enqueue must leave the existing personal entry intact"
ok "physical-device enqueue rejects agent profile before queueing"

# Entries from the pre-identity queue schema have no contract fields. They
# must remain pending with an actionable note instead of being discarded.
/usr/bin/python3 - "$ENTRY/meta.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    meta = json.load(fh)
for key in ("auth_profile", "expected_account", "credentials_file"):
    meta.pop(key, None)
with open(path, "w") as fh:
    json.dump(meta, fh, indent=2)
PY
echo "reachable" > "$STATE_FILE"
: > "$CALL_LOG"
"$QUEUE_SCRIPT" drain >/dev/null 2>&1 \
  || fail "legacy queue entries should remain pending without a contract"
[[ -d "$ENTRY" ]] || fail "legacy queue entry must not be moved or deleted"
grep -q "lacks the personal auth contract" "$ENTRY/upgrade-needed.txt" \
  || fail "legacy queue entry should explain how to re-enqueue safely"
grep -q "devicectl device install" "$CALL_LOG" \
  && fail "legacy queue entry must not mutate the physical phone"
"$QUEUE_SCRIPT" clear --tag tstq >/dev/null
echo "unreachable" > "$STATE_FILE"
"$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" "${AUTH_ARGS[@]}" >/dev/null
ENTRY="$CMUX_IPHONE_QUEUE_DIR/pending/tstq"
ok "legacy queue entries stay pending with an actionable auth-contract note"

# Older queue entries can already contain the simulator-only profile. Drain
# must quarantine those entries before probing or mutating the physical phone.
/usr/bin/python3 - "$ENTRY/meta.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    meta = json.load(fh)
meta["auth_profile"] = "agent"
with open(path, "w") as fh:
    json.dump(meta, fh, indent=2)
PY
echo "reachable" > "$STATE_FILE"
: > "$CALL_LOG"
if "$QUEUE_SCRIPT" drain >/dev/null 2>&1; then
  fail "drain must reject a legacy agent-profile entry"
fi
[[ -d "$CMUX_IPHONE_QUEUE_DIR/failed/tstq" ]] \
  || fail "legacy agent-profile entry should move to failed/"
grep -q "requires auth-profile personal" \
  "$CMUX_IPHONE_QUEUE_DIR/failed/tstq/error.txt" \
  || fail "legacy agent-profile failure should explain the personal-only contract"
grep -q "devicectl device install" "$CALL_LOG" \
  && fail "legacy agent-profile rejection must happen before device install"
"$QUEUE_SCRIPT" clear --tag tstq >/dev/null
echo "unreachable" > "$STATE_FILE"
"$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" "${AUTH_ARGS[@]}" >/dev/null
ENTRY="$CMUX_IPHONE_QUEUE_DIR/pending/tstq"
ok "drain quarantines legacy agent-profile entries before device mutation"

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
grep -q -- "--auth-profile personal --expected-account person@manaflow.ai --credentials-file $CREDENTIALS_FILE" "$CALL_LOG" \
  || fail "drain should preserve the queued auth contract"
grep -q "cmux notify --title iPhone install queue: installed tstq" "$CALL_LOG" \
  || fail "drain should send a cmux notification for the installed tag"
grep -q "VERIFIED signed in + paired" "$CALL_LOG" \
  || fail "the success notification must state the install was VERIFIED signed in"
ok "reconnect drain terminates before install, signed-launches with --ensure-mac, and notifies verified"

# --- gate pass without a fresh readiness receipt is NOT verified ---------------
echo "unreachable" > "$STATE_FILE"
"$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" "${AUTH_ARGS[@]}" >/dev/null
echo "reachable" > "$STATE_FILE"
write_fake_mdl 0 0   # exit 0 but no receipt: a launcher that lies
rm -f "$CMUX_READINESS_RECEIPT_DIR/tstq-$DEVICE_ID.json"
: > "$CALL_LOG"
if "$QUEUE_SCRIPT" drain >/dev/null 2>&1; then
  fail "drain should exit non-zero when no fresh readiness receipt backs the gate"
fi
[[ -d "$CMUX_IPHONE_QUEUE_DIR/needs-auth/tstq" ]] \
  || fail "receipt-less install should move to needs-auth/"
grep -q "no fresh readiness receipt" "$CMUX_IPHONE_QUEUE_DIR/needs-auth/tstq/error.txt" \
  || fail "needs-auth reason should mention the missing receipt"
"$QUEUE_SCRIPT" retry --tag tstq >/dev/null || fail "retry should re-queue the needs-auth entry"
ok "gate pass without a fresh receipt parks in needs-auth (launcher cannot lie with exit 0)"

# --- failed signed launch: kept in needs-auth, truthful notify, retryable ------
write_fake_mdl 1 0
: > "$CALL_LOG"
if "$QUEUE_SCRIPT" drain >/dev/null 2>&1; then
  fail "drain should exit non-zero when the signed launch fails"
fi
[[ -d "$CMUX_IPHONE_QUEUE_DIR/needs-auth/tstq" ]] \
  || fail "auth-failed entry should move to needs-auth/ (installed app must not be dropped)"
[[ -d "$CMUX_IPHONE_QUEUE_DIR/needs-auth/tstq/cmux.app" ]] \
  || fail "needs-auth entry should retain the staged app for retry"
grep -q "fake sign-in failure" "$CMUX_IPHONE_QUEUE_DIR/needs-auth/tstq/error.txt" \
  || fail "needs-auth reason should carry the launcher's error line"
grep -q "devicectl device process launch" "$CALL_LOG" \
  && fail "a failed signed launch must never fall back to a plain launch"
grep -q "cmux notify --title iPhone install queue: tstq installed but SIGN-IN FAILED" "$CALL_LOG" \
  || fail "the notification must report the TRUE state (installed but SIGN-IN FAILED)"
grep -q -- "Retry the queued contract: scripts/iphone-install-queue.sh retry --tag tstq" "$CALL_LOG" \
  || fail "the notification must include the immutable-contract retry"
"$QUEUE_SCRIPT" list | grep -q "needs-auth tstq" || fail "list should show the needs-auth entry"
"$QUEUE_SCRIPT" retry --tag tstq >/dev/null || fail "retry should re-queue the needs-auth entry"
[[ -d "$CMUX_IPHONE_QUEUE_DIR/pending/tstq" ]] || fail "retry should move the entry back to pending/"
write_fake_mdl 0 1
: > "$CALL_LOG"
"$QUEUE_SCRIPT" drain >/dev/null 2>&1 || fail "drain after retry with fixed auth should succeed"
[[ ! -d "$CMUX_IPHONE_QUEUE_DIR/pending/tstq" ]] || fail "retried entry should drain to completion"
ok "auth-failed install parks in needs-auth, notifies truthfully, and retry re-queues it"

# --- locked/offline phone mid-launch (launcher exit 75) keeps entry pending ----
"$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" "${AUTH_ARGS[@]}" >/dev/null
write_fake_mdl 75 0
: > "$CALL_LOG"
"$QUEUE_SCRIPT" drain >/dev/null 2>&1 || fail "deferred-delivery drain should exit 0 (entry simply stays queued)"
[[ -d "$CMUX_IPHONE_QUEUE_DIR/pending/tstq" ]] \
  || fail "launcher exit 75 (phone locked/offline) must keep the entry pending, not needs-auth/failed"
grep -q "cmux notify" "$CALL_LOG" && fail "a deferred delivery must not claim an install happened"
write_fake_mdl 0 1
"$QUEUE_SCRIPT" drain >/dev/null 2>&1 || fail "drain after unlock should succeed"
[[ ! -d "$CMUX_IPHONE_QUEUE_DIR/pending/tstq" ]] || fail "entry should drain once the launcher succeeds"
ok "launcher exit 75 keeps the entry pending for the LaunchAgent retry"

# --- unauthenticated enqueue is human-only -------------------------------------
if "$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" --checkout "$FAKE_CHECKOUT" --no-sign-in >/dev/null 2>&1; then
  fail "enqueue --no-sign-in without CMUX_ALLOW_UNAUTHENTICATED_INSTALL must be refused"
fi
CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1 "$QUEUE_SCRIPT" enqueue --tag tstq --app "$APP" \
  --checkout "$FAKE_CHECKOUT" --no-sign-in --allow-unauthenticated >/dev/null \
  || fail "enqueue --no-sign-in with the human allowance should be accepted"
python3 - "$CMUX_IPHONE_QUEUE_DIR/pending/tstq/meta.json" <<'PY' \
  || fail "explicit unauthenticated marker should be persisted"
import json, sys
with open(sys.argv[1]) as fh:
    meta = json.load(fh)
assert meta["allow_unauthenticated"] is True
PY
: > "$CALL_LOG"
"$QUEUE_SCRIPT" drain >/dev/null 2>&1 || fail "opt-out drain should exit 0"
grep -q "devicectl device process launch" "$CALL_LOG" \
  || fail "opt-out entry should plain-launch"
grep -q "auth NOT verified" "$CALL_LOG" \
  || fail "the opt-out notification must state auth was NOT verified"
ok "unauthenticated enqueue needs the human-only allowance and notifies unverified"

# The persisted-state physical-device auth gate must reject the simulator-only
# profile before loading credentials or touching the device.
VERIFY_PROFILE_ERROR="$TMP_DIR/verify-agent-profile.err"
: > "$CALL_LOG"
if "$REPO_ROOT/scripts/verify-iphone-auth.sh" --tag tstq --auth-profile agent \
    >/dev/null 2>"$VERIFY_PROFILE_ERROR"; then
  fail "physical iPhone auth verification must reject the agent profile"
fi
grep -q "physical iPhone auth verification requires --auth-profile personal" \
  "$VERIFY_PROFILE_ERROR" \
  || fail "verify-iphone-auth should report the personal-only contract"
grep -q "xcrun" "$CALL_LOG" \
  && fail "verify-iphone-auth profile rejection must happen before device probing"
ok "physical-device auth verification rejects agent profile before credentials/device access"

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
