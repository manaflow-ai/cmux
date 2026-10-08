#!/usr/bin/env bash
# Resume a timed-out nightly DMG submission without rebuilding or re-submitting.
# The state file and signed DMG must come from the same recovery artifact.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: resume-nightly-notarization.sh <state-file> <signed-app> <signed-dmg> <immutable-dmg>

Required environment: ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64.
Optional publication environment: CMUX_PUBLISH_REPO, CMUX_PUBLISH_RELEASE_ID,
CMUX_PUBLISH_ALIAS, and GH_TOKEN. Publication is attempted only after Apple
returns Accepted and every local stapling and validation check passes.
EOF
}

if [ "$#" -ne 4 ]; then
  usage
  exit 2
fi

STATE_FILE="$1"
APP_PATH="$2"
DMG_RELEASE="$3"
DMG_IMMUTABLE="$4"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
HDIUTIL_TOOL="${CMUX_HDIUTIL_TOOL:-/usr/bin/hdiutil}"
SPCTL_TOOL="${CMUX_SPCTL_TOOL:-spctl}"
SYSPOLICY_TOOL="${CMUX_SYSPOLICY_TOOL:-syspolicy_check}"
SMOKE_TOOL="${CMUX_SMOKE_TOOL:-$ROOT_DIR/scripts/smoke-launch-macos-app.sh}"
VERIFY_METADATA_TOOL="${CMUX_VERIFY_METADATA_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh}"
VERIFY_LICENSES_TOOL="${CMUX_VERIFY_LICENSES_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-licenses.sh}"
NOTARY_WAIT_TIMEOUT="${CMUX_NOTARY_WAIT_TIMEOUT:-60m}"
EVIDENCE_FILE="${CMUX_NOTARY_EVIDENCE_FILE:-${DMG_RELEASE}.notarization.log}"
NOTARY_OUTPUT_FILE="${CMUX_NOTARY_OUTPUT_FILE:-${DMG_RELEASE}.resume-notarization.log}"

if [ ! -f "$STATE_FILE" ] || [ ! -r "$STATE_FILE" ]; then
  echo "Notarization state file not found: $STATE_FILE" >&2
  exit 1
fi
if [ ! -d "$APP_PATH/Contents" ]; then
  echo "Signed app not found: $APP_PATH" >&2
  exit 1
fi
if [ ! -f "$DMG_RELEASE" ]; then
  echo "Signed DMG not found: $DMG_RELEASE" >&2
  exit 1
fi
if [ ! -s "$EVIDENCE_FILE" ]; then
  echo "Original notarization evidence not found or empty: $EVIDENCE_FILE" >&2
  exit 1
fi

if [ -z "${ASC_API_KEY_ID:-}" ] || [ -z "${ASC_API_ISSUER_ID:-}" ] || [ -z "${ASC_API_KEY_P8_BASE64:-}" ]; then
  echo "Missing notarization secrets (ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64)" >&2
  exit 1
fi

state_value() {
  local key="$1"
  python3 - "$STATE_FILE" "$key" <<'PY'
import pathlib
import sys

path, wanted = sys.argv[1:]
values = {}
for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
    if not line:
        continue
    key, separator, value = line.partition("=")
    if not separator or not key or key in values:
        raise SystemExit(f"invalid or duplicate notarization state line: {line!r}")
    values[key] = value
print(values.get(wanted, ""))
PY
}

SUBMISSION_ID="$(state_value submission_id)"
RECORDED_DMG="$(state_value dmg_path)"
RECORDED_SHA256="$(state_value dmg_sha256)"
RECORDED_IMMUTABLE="$(state_value immutable_path)"
RECORDED_CHANNEL="$(state_value channel)"
CHANNEL="${CMUX_CHANNEL:-${RECORDED_CHANNEL:-nightly}}"
if [ -z "$SUBMISSION_ID" ] || [ -z "$RECORDED_DMG" ] || [ -z "$RECORDED_SHA256" ] || [ -z "$RECORDED_IMMUTABLE" ] || [ -z "$RECORDED_CHANNEL" ]; then
  echo "Incomplete notarization state: $STATE_FILE" >&2
  exit 1
fi
if [[ ! "$SUBMISSION_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid Apple submission id in state: $SUBMISSION_ID" >&2
  exit 1
fi
if [[ ! "$RECORDED_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Invalid DMG SHA-256 in state: $RECORDED_SHA256" >&2
  exit 1
fi
if [ "$(basename "$RECORDED_DMG")" != "$(basename "$DMG_RELEASE")" ]; then
  echo "Recovery DMG name does not match the submitted DMG" >&2
  echo "  submitted: $(basename "$RECORDED_DMG")" >&2
  echo "  recovered: $(basename "$DMG_RELEASE")" >&2
  exit 1
fi
if [ "$(basename "$RECORDED_IMMUTABLE")" != "$(basename "$DMG_IMMUTABLE")" ]; then
  echo "Immutable DMG name does not match the notarization state" >&2
  exit 1
fi
case "$CHANNEL" in
  nightly|rc) ;;
  *) echo "Unsupported recovery channel: $CHANNEL" >&2; exit 1 ;;
esac
if [ "$CHANNEL" != "$RECORDED_CHANNEL" ]; then
  echo "Recovery channel does not match the notarization state" >&2
  exit 1
fi
ACTUAL_SHA256="$(shasum -a 256 "$DMG_RELEASE" | awk '{print $1}')"
ACTUAL_SHA256_LOWER="$(printf '%s' "$ACTUAL_SHA256" | tr '[:upper:]' '[:lower:]')"
RECORDED_SHA256_LOWER="$(printf '%s' "$RECORDED_SHA256" | tr '[:upper:]' '[:lower:]')"
if [ "$ACTUAL_SHA256_LOWER" != "$RECORDED_SHA256_LOWER" ]; then
  echo "Recovery DMG SHA-256 does not match the notarized submission" >&2
  echo "  state:   $RECORDED_SHA256" >&2
  echo "  current: $ACTUAL_SHA256" >&2
  exit 1
fi

for sidecar in "$NOTARY_OUTPUT_FILE" "$DMG_IMMUTABLE"; do
  sidecar_parent="$(dirname "$sidecar")"
  if [ ! -d "$sidecar_parent" ] || [ ! -w "$sidecar_parent" ]; then
    echo "Output parent must be an existing writable directory: $sidecar_parent" >&2
    exit 1
  fi
done

TMP_DIR="$(mktemp -d)"
MOUNT_DIR=""
cleanup() {
  if [ -n "$MOUNT_DIR" ]; then
    "$HDIUTIL_TOOL" detach "$MOUNT_DIR" || "$HDIUTIL_TOOL" detach -force "$MOUNT_DIR" || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# shellcheck source=lib/notary-auth.sh
source "$ROOT_DIR/scripts/ci/lib/notary-auth.sh"
NOTARY_DIR="$TMP_DIR/notary"
mkdir -m 700 "$NOTARY_DIR"
notary_auth_init "$NOTARY_DIR"

extract_notary_value() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PY'
import json
import re
import sys

path, key = sys.argv[1:]
raw = open(path, encoding="utf-8").read()
decoder = json.JSONDecoder()
values = []
for match in re.finditer(r"\{", raw):
    try:
        value, _ = decoder.raw_decode(raw[match.start():])
    except json.JSONDecodeError:
        continue
    if isinstance(value, dict) and value.get(key) not in (None, ""):
        values.append(value[key])
if values:
    print(values[-1])
PY
}

WAIT_OUTPUT="$TMP_DIR/notary-wait-output"
LOG_OUTPUT="$TMP_DIR/notary-log-output"
set +e
"$XCRUN_TOOL" notarytool wait "$SUBMISSION_ID" "${NOTARY_AUTH_ARGS[@]}" \
  --timeout "$NOTARY_WAIT_TIMEOUT" --output-format json \
  >"$WAIT_OUTPUT" 2>&1
WAIT_EXIT=$?
"$XCRUN_TOOL" notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH_ARGS[@]}" \
  >"$LOG_OUTPUT" 2>&1
LOG_EXIT=$?
set -e
WAIT_STATUS="$(extract_notary_value "$WAIT_OUTPUT" status || true)"
LOG_STATUS="$(extract_notary_value "$LOG_OUTPUT" status || true)"

umask 077
{
  printf '%s\n' '--- original timed-out notarytool evidence ---'
  cat "$EVIDENCE_FILE"
  printf '\n--- notarytool wait for submission %s ---\n' "$SUBMISSION_ID"
  cat "$WAIT_OUTPUT"
  printf '\n--- notarytool log for submission %s ---\n' "$SUBMISSION_ID"
  cat "$LOG_OUTPUT"
} > "$NOTARY_OUTPUT_FILE"

if [ "$WAIT_EXIT" -ne 0 ] || [ "$WAIT_STATUS" != "Accepted" ] || [ "$LOG_EXIT" -ne 0 ] || [ "$LOG_STATUS" != "Accepted" ]; then
  cat "$NOTARY_OUTPUT_FILE" >&2
  echo "Notarization submission $SUBMISSION_ID is not proven Accepted (wait: ${WAIT_STATUS:-unknown}, log: ${LOG_STATUS:-unknown}); refusing to staple or publish" >&2
  exit 1
fi

"$CODESIGN_TOOL" --verify --verbose=2 "$DMG_RELEASE"
"$XCRUN_TOOL" stapler staple "$APP_PATH"
"$XCRUN_TOOL" stapler validate "$APP_PATH"
"$SPCTL_TOOL" -a -vv --type execute "$APP_PATH"
CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$APP_PATH"
CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$APP_PATH"
"$VERIFY_METADATA_TOOL" "$APP_PATH" "$CHANNEL"
"$VERIFY_LICENSES_TOOL" "$APP_PATH"
"$SYSPOLICY_TOOL" distribution "$APP_PATH"

"$XCRUN_TOOL" stapler staple "$DMG_RELEASE"
"$XCRUN_TOOL" stapler validate "$DMG_RELEASE"
MOUNT_DIR="$(mktemp -d "$TMP_DIR/mount.XXXXXX")"
"$HDIUTIL_TOOL" attach "$DMG_RELEASE" -nobrowse -readonly -mountpoint "$MOUNT_DIR"
MOUNTED_APP="$(find "$MOUNT_DIR" -maxdepth 1 -name '*.app' -type d -print -quit)"
if [ -z "$MOUNTED_APP" ]; then
  echo "No app found in mounted recovered DMG" >&2
  exit 1
fi
"$SPCTL_TOOL" -a -vv --type execute "$MOUNTED_APP"
CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$MOUNTED_APP"
CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$MOUNTED_APP"
"$VERIFY_METADATA_TOOL" "$MOUNTED_APP" "$CHANNEL"
"$VERIFY_LICENSES_TOOL" "$MOUNTED_APP"
"$HDIUTIL_TOOL" detach "$MOUNT_DIR" || "$HDIUTIL_TOOL" detach -force "$MOUNT_DIR"
MOUNT_DIR=""

immutable_tmp="$DMG_IMMUTABLE.tmp.$$"
cp "$DMG_RELEASE" "$immutable_tmp"
cmp -s "$DMG_RELEASE" "$immutable_tmp"
mv -f "$immutable_tmp" "$DMG_IMMUTABLE"

if [ -n "${CMUX_PUBLISH_REPO:-}" ] || [ -n "${CMUX_PUBLISH_RELEASE_ID:-}" ] || [ -n "${CMUX_PUBLISH_ALIAS:-}" ]; then
  if [ -z "${CMUX_PUBLISH_REPO:-}" ] || [ -z "${CMUX_PUBLISH_RELEASE_ID:-}" ] || [ -z "${CMUX_PUBLISH_ALIAS:-}" ] || [ -z "${GH_TOKEN:-}" ]; then
    echo "Publication requires CMUX_PUBLISH_REPO, CMUX_PUBLISH_RELEASE_ID, CMUX_PUBLISH_ALIAS, and GH_TOKEN" >&2
    exit 1
  fi
  python3 "$ROOT_DIR/scripts/ci/publish-release-assets.py" \
    --repo "$CMUX_PUBLISH_REPO" \
    --release-id "$CMUX_PUBLISH_RELEASE_ID" \
    --immutable "$DMG_IMMUTABLE" \
    --alias "$CMUX_PUBLISH_ALIAS"
fi

echo "Resumed notarization accepted and verified: $SUBMISSION_ID"
