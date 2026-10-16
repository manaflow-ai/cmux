#!/usr/bin/env bash
# passkeys-gate.sh: the passkey/WebAuthn GUI gate (plans/cmux-next/passkeys.md section 7.3).
# Runs in an nx-remote --app-from-fleet job on the GUI host, against the fleet build of the
# exact head:
#   nx-remote --detach --needs gui --priority gate --gate-head SHA --app-from-fleet cmux --tag TAG --ref SHA \
#     --timeout 2400 -- bash scripts/cmux-next/passkeys-gate.sh
# then `nx-remote wait <job>` (exit 75: still running, wait again; never resubmit).
#
# Steps (each prints its rows; the job exits 1 when a judged row fails):
#   1. matrix   passkeys-matrix-e2e.py: every test RP scenario (tests/passkeys/rp) in a CEF tab
#               with a DevTools virtual authenticator (ctap2 + u2f; internal, usb, nfc, ble,
#               hybrid; resident keys; uv on/off; PRF, largeBlob, credProps; conditional;
#               excludeCredentials; attestation; several credentials; abort/timeout;
#               cross-origin and sandboxed iframes), and the authenticator-free ones in WebKit.
#   2. roaming  passkeys-roaming-e2e.py: webauthn.io register + sign in through virtual USB
#               (CTAP2.1 and U2F), NFC, BLE and hybrid authenticators (Chromium UI off).
#   3. parity   passkeys-parity-e2e.py: getClientCapabilities / isUVPAA / conditional mediation
#               in CEF and WebKit against Google Chrome on the same Mac, on the test RP,
#               webauthn.io, passkeys.dev and github.com/login, and the GitHub "partial passkey
#               support" text (with a virtual platform authenticator in CEF; a signed build
#               runs it again without one: PASSKEYS_GATE_SIGNED=1).
# Real Touch ID, iCloud Keychain, 1Password, a phone and a YubiKey PIN need a person: see the
# physical checklist in passkeys.md section 8.
set -u
: "${NX_APP:?run under nx-remote --app-from-fleet}" "${NX_APP_SOCKET:?}"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${NX_ARTIFACTS:-/tmp}/passkeys-gate
mkdir -p "$OUT"
open -g -n --env ACPMUX_AGENT_LAUNCH=deny "$NX_APP" || exit 2
if [[ -n "${NX_AGENT_GUARD_CHECK:-}" ]]; then "$NX_AGENT_GUARD_CHECK" --app "$NX_APP" || exit 2; fi

status=0
step() {
  local name=$1; shift
  echo "== passkeys-gate: $name"
  "$@" 2>&1 | tee "$OUT/$name.log"
  local code=${PIPESTATUS[0]}
  echo "== passkeys-gate: $name exit $code"
  [[ $code -eq 0 ]] || status=1
}
step matrix python3 -I "$HERE/passkeys-matrix-e2e.py" --socket "$NX_APP_SOCKET" --out "$OUT"
step roaming python3 -I "$HERE/passkeys-roaming-e2e.py" --socket "$NX_APP_SOCKET" --out "$OUT"
step parity-virtual python3 -I "$HERE/passkeys-parity-e2e.py" --socket "$NX_APP_SOCKET" --app "$NX_APP" \
  --virtual-platform --engines cef --out "$OUT/virtual"
step parity python3 -I "$HERE/passkeys-parity-e2e.py" --socket "$NX_APP_SOCKET" --app "$NX_APP" --out "$OUT/real"
if [[ -n "${NX_APP_STOP:-}" ]]; then "$NX_APP_STOP" || true; fi
echo "passkeys-gate: $([[ $status -eq 0 ]] && echo PASS || echo FAIL) (logs in $OUT)"
exit $status
