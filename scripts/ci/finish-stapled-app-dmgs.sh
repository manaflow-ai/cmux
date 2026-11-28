#!/usr/bin/env bash
# Finish the DMGs around stapled apps that notarize-nightly-dmg.sh submitted
# without a wait (CMUX_STAPLED_DMG_HANDOFF_FILE). All submissions are waited on
# at once, so several variants share one bounded wait instead of one each.
# For each: require Accepted from both `notarytool wait` and `notarytool log`,
# require the DMG bytes the handoff recorded, staple the DMG, validate it and the app inside it
# (its own ticket, Gatekeeper, metadata, licenses, launch smokes unless
# CMUX_DEFER_LAUNCH_SMOKES), then move it to the release path and copy it to
# the immutable path.
#
# Usage: finish-stapled-app-dmgs.sh <handoff-file>...
set -euo pipefail
[ "$#" -ge 1 ] || { echo "usage: finish-stapled-app-dmgs.sh <handoff-file>..." >&2; exit 2; }
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
HDIUTIL_TOOL="${CMUX_HDIUTIL_TOOL:-hdiutil}"
SPCTL_TOOL="${CMUX_SPCTL_TOOL:-spctl}"
SMOKE_TOOL="${CMUX_SMOKE_TOOL:-$ROOT_DIR/scripts/smoke-launch-macos-app.sh}"
VERIFY_METADATA_TOOL="${CMUX_VERIFY_METADATA_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh}"
VERIFY_LICENSES_TOOL="${CMUX_VERIFY_LICENSES_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-licenses.sh}"
DEFER_LAUNCH_SMOKES="${CMUX_DEFER_LAUNCH_SMOKES:-false}"
WAIT_TIMEOUT="${CMUX_STAPLED_DMG_WAIT_TIMEOUT:-25m}"
for tool in ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_P8_BASE64; do
  [ -n "${!tool:-}" ] || { echo "Missing notarization secret $tool" >&2; exit 1; }
done
# shellcheck source=lib/notary-auth.sh
source "$ROOT_DIR/scripts/ci/lib/notary-auth.sh"
TMP_DIR="$(mktemp -d)"
MOUNT_DIR=""
pids=()
cleanup() {
  local pid
  for pid in ${pids[@]+"${pids[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  if [ -n "$MOUNT_DIR" ]; then
    "$HDIUTIL_TOOL" detach "$MOUNT_DIR" || "$HDIUTIL_TOOL" detach -force "$MOUNT_DIR" || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
mkdir -m 700 "$TMP_DIR/notary"
notary_auth_init "$TMP_DIR/notary"

value() { awk -F= -v key="$2" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$1"; }
status_of() {
  python3 - "$1" <<'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
decoder = json.JSONDecoder()
found = ""
for match in re.finditer(r"\{", raw):
    try:
        value, _ = decoder.raw_decode(raw[match.start():])
    except json.JSONDecodeError:
        continue
    if isinstance(value, dict) and value.get("status"):
        found = value["status"]
print(found)
PY
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'
}
handoffs=("$@")
for i in "${!handoffs[@]}"; do
  handoff="${handoffs[$i]}"
  [ -f "$handoff" ] || { echo "Handoff record not found: $handoff" >&2; exit 1; }
  id="$(value "$handoff" submission_id)"
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Handoff $handoff names no valid submission id" >&2; exit 1; }
  [ -f "$(value "$handoff" stapled_dmg)" ] || { echo "Handoff $handoff: stapled-app DMG missing" >&2; exit 1; }
  if [ "$(sha256_of "$(value "$handoff" stapled_dmg)")" != "$(value "$handoff" dmg_sha256)" ]; then
    echo "Handoff $handoff: the stapled-app DMG is not the submitted one" >&2
    exit 1
  fi
  "$XCRUN_TOOL" notarytool wait "$id" "${NOTARY_AUTH_ARGS[@]}" \
    --timeout "$WAIT_TIMEOUT" --output-format json > "$TMP_DIR/wait-$i.out" 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid" || true
done
pids=()
failed=false
for i in "${!handoffs[@]}"; do
  id="$(value "${handoffs[$i]}" submission_id)"
  status="$(status_of "$TMP_DIR/wait-$i.out")"
  log_status=""
  if [ "$status" = Accepted ]; then
    python3 "$ROOT_DIR/scripts/ci/run_with_timeout.py" --timeout-seconds 300 -- \
      "$XCRUN_TOOL" notarytool log "$id" "${NOTARY_AUTH_ARGS[@]}" > "$TMP_DIR/log-$i.out" 2>&1 || true
    log_status="$(status_of "$TMP_DIR/log-$i.out")"
  fi
  if [ "$status" != Accepted ] || [ "$log_status" != Accepted ]; then
    cat "$TMP_DIR/wait-$i.out" >&2
    [ ! -f "$TMP_DIR/log-$i.out" ] || cat "$TMP_DIR/log-$i.out" >&2
    echo "The DMG around the stapled app (submission $id) is not proven Accepted within $WAIT_TIMEOUT (wait: ${status:-unknown}, log: ${log_status:-unknown}); nothing is published" >&2
    failed=true
  fi
done
[ "$failed" = false ] || exit 1
# Apple is done; the app below must not find the key.
notary_auth_forget "$TMP_DIR/notary"

for handoff in "${handoffs[@]}"; do
  dmg="$(value "$handoff" stapled_dmg)"
  release="$(value "$handoff" release_dmg)"
  immutable="$(value "$handoff" immutable_dmg)"
  channel="$(value "$handoff" channel)"
  if [ "$(sha256_of "$dmg")" != "$(value "$handoff" dmg_sha256)" ]; then
    echo "The stapled-app DMG changed after its submission: $dmg" >&2
    exit 1
  fi
  "$XCRUN_TOOL" stapler staple "$dmg"
  "$XCRUN_TOOL" stapler validate "$dmg"
  MOUNT_DIR="$(mktemp -d "$TMP_DIR/mount.XXXXXX")"
  "$HDIUTIL_TOOL" attach "$dmg" -nobrowse -readonly -mountpoint "$MOUNT_DIR"
  app="$(find "$MOUNT_DIR" -maxdepth 1 -name '*.app' -type d -print -quit)"
  [ -n "$app" ] || { echo "No app found in $dmg" >&2; exit 1; }
  # The shipped app has its own ticket, not only the DMG's.
  "$XCRUN_TOOL" stapler validate "$app"
  "$SPCTL_TOOL" -a -vv --type execute "$app"
  if [ "$DEFER_LAUNCH_SMOKES" != true ]; then
    CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$app"
    CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$app"
  fi
  "$VERIFY_METADATA_TOOL" "$app" "$channel"
  "$VERIFY_LICENSES_TOOL" "$app"
  "$HDIUTIL_TOOL" detach "$MOUNT_DIR" || "$HDIUTIL_TOOL" detach -force "$MOUNT_DIR"
  rmdir "$MOUNT_DIR" 2>/dev/null || true
  MOUNT_DIR=""
  /bin/mv -f "$dmg" "$release"
  cp "$release" "$immutable"
  echo "Finished the DMG around the stapled app: $release"
done
