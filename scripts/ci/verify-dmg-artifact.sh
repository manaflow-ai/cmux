#!/usr/bin/env bash
# Verify a signed DMG and the app it contains without launching bundle code.
# Runtime launch coverage belongs to the daemon/app integration workflows; this
# check is safe for nightly and release publication because it only validates
# the exact bytes, tickets, Gatekeeper policy, metadata and licenses.
set -euo pipefail

# Keep the digest receipt separate from the verification log, matching the
# former smoke-dmg caller contract.
if { true >&3; } 2>/dev/null; then
  exec 4>&3
else
  exec 4>&1
fi
exec 1>&2

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <dmg> <channel> [--expect-sha256 HEX] [--require-stapled-app | --stapled-app-fallback ID]" >&2
  exit 2
fi

DMG="$1"
CHANNEL="$2"
shift 2
EXPECTED=""
REQUIRE_STAPLED_APP=true
STAPLED_APP_FALLBACK_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --expect-sha256)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "--expect-sha256 needs a value" >&2; exit 2; }
      EXPECTED="$2"; shift 2 ;;
    --require-stapled-app) REQUIRE_STAPLED_APP=true; shift ;;
    --stapled-app-fallback)
      [ "$#" -ge 2 ] && [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "--stapled-app-fallback needs the pending submission id" >&2; exit 2; }
      STAPLED_APP_FALLBACK_ID="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HDIUTIL_TOOL="${CMUX_HDIUTIL_TOOL:-hdiutil}"
SPCTL_TOOL="${CMUX_SPCTL_TOOL:-spctl}"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
VERIFY_METADATA_TOOL="${CMUX_VERIFY_METADATA_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh}"
VERIFY_LICENSES_TOOL="${CMUX_VERIFY_LICENSES_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-licenses.sh}"
# shellcheck source=lib/signing-runtime-guard.sh
source "$ROOT_DIR/scripts/ci/lib/signing-runtime-guard.sh"
cmux_signing_runtime_guard

[ -f "$DMG" ] || { echo "DMG not found: $DMG" >&2; exit 1; }
actual="$(shasum -a 256 "$DMG" | awk '{print $1}')"
expected_lower="$(printf '%s' "$EXPECTED" | tr '[:upper:]' '[:lower:]')"
if [ -n "$EXPECTED" ] && [ "$actual" != "$expected_lower" ]; then
  echo "$DMG SHA-256 $actual does not match the expected $EXPECTED" >&2
  exit 1
fi

"$XCRUN_TOOL" stapler validate "$DMG"
MOUNT_DIR="$(mktemp -d)"
detach() {
  "$HDIUTIL_TOOL" detach "$MOUNT_DIR" >/dev/null 2>&1 \
    || "$HDIUTIL_TOOL" detach -force "$MOUNT_DIR" >/dev/null 2>&1 || true
  rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap detach EXIT
"$HDIUTIL_TOOL" attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_DIR"
APP="$(find "$MOUNT_DIR" -maxdepth 1 -name '*.app' -type d -print -quit)"
[ -n "$APP" ] || { echo "No app found in $DMG" >&2; exit 1; }
if [ -n "$STAPLED_APP_FALLBACK_ID" ]; then
  if ! "$XCRUN_TOOL" stapler validate "$APP"; then
    echo "::warning title=App without its own ticket::the fallback ships the first DMG; stapled-app submission $STAPLED_APP_FALLBACK_ID is not accepted"
  fi
elif [ "$REQUIRE_STAPLED_APP" = true ]; then
  "$XCRUN_TOOL" stapler validate "$APP"
fi
"$SPCTL_TOOL" -a -vv --type execute "$APP"
"$VERIFY_METADATA_TOOL" "$APP" "$CHANNEL"
"$VERIFY_LICENSES_TOOL" "$APP"
detach
trap - EXIT

after="$(shasum -a 256 "$DMG" | awk '{print $1}')"
[ "$after" = "$actual" ] || { echo "$DMG changed during verification" >&2; exit 1; }
printf 'verified %s %s\n' "$actual" "$(basename "$DMG")" >&4
