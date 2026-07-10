#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'verify-ipa-release-identity: %s\n' "$*" >&2
  exit 1
}

if [[ "$#" -ne 3 ]]; then
  die "usage: $0 <ipa> <expected-bundle-id> <expected-team-id>"
fi

IPA_PATH="$1"
EXPECTED_BUNDLE_ID="$2"
EXPECTED_TEAM_ID="$3"
EXPECTED_APP_ID="${EXPECTED_TEAM_ID}.${EXPECTED_BUNDLE_ID}"

[[ -f "$IPA_PATH" ]] || die "IPA does not exist: $IPA_PATH"
command -v python3 >/dev/null || die "python3 is required"
command -v unzip >/dev/null || die "unzip is required"
command -v codesign >/dev/null || die "codesign is required"
command -v security >/dev/null || die "security is required"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

( cd "$WORKDIR" && unzip -q "$IPA_PATH" ) || die "could not unzip IPA: $IPA_PATH"
APP_COUNT="$(find "$WORKDIR/Payload" -maxdepth 1 -name '*.app' -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
[[ "$APP_COUNT" == "1" ]] || die "IPA must contain exactly one Payload/*.app (found ${APP_COUNT:-0})"
APP_PATH="$(find "$WORKDIR/Payload" -maxdepth 1 -name '*.app' -type d | head -n 1)"

read_plist_value() {
  python3 - "$1" "$2" <<'PY'
import plistlib
import sys

path, dotted_key = sys.argv[1:]
with open(path, "rb") as handle:
    value = plistlib.load(handle)
for component in dotted_key.split("."):
    if not isinstance(value, dict) or component not in value:
        raise SystemExit(1)
    value = value[component]
if not isinstance(value, str):
    raise SystemExit(1)
print(value)
PY
}

INFO_BUNDLE_ID="$(read_plist_value "$APP_PATH/Info.plist" CFBundleIdentifier 2>/dev/null || true)"
[[ "$INFO_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] ||
  die "Info.plist bundle id is '${INFO_BUNDLE_ID:-<absent>}', expected '$EXPECTED_BUNDLE_ID'"

codesign --verify --strict --verbose=2 "$APP_PATH" >&2 || die "app signature verification failed"

SIGNED_ENTITLEMENTS="$WORKDIR/signed-entitlements.plist"
codesign -d --entitlements :- --xml "$APP_PATH" > "$SIGNED_ENTITLEMENTS" 2>/dev/null ||
  die "could not read signed app entitlements"
SIGNED_APP_ID="$(read_plist_value "$SIGNED_ENTITLEMENTS" application-identifier 2>/dev/null || true)"
[[ "$SIGNED_APP_ID" == "$EXPECTED_APP_ID" ]] ||
  die "signed application-identifier is '${SIGNED_APP_ID:-<absent>}', expected '$EXPECTED_APP_ID'"

PROFILE_PATH="$APP_PATH/embedded.mobileprovision"
[[ -f "$PROFILE_PATH" ]] || die "embedded.mobileprovision is missing"
PROFILE_PLIST="$WORKDIR/profile.plist"
security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST" || die "could not decode embedded.mobileprovision"
PROFILE_APP_ID="$(read_plist_value "$PROFILE_PLIST" Entitlements.application-identifier 2>/dev/null || true)"
[[ "$PROFILE_APP_ID" == "$EXPECTED_APP_ID" ]] ||
  die "profile application-identifier is '${PROFILE_APP_ID:-<absent>}', expected '$EXPECTED_APP_ID'"

printf 'verified final IPA identity: %s (%s)\n' "$EXPECTED_BUNDLE_ID" "$EXPECTED_APP_ID"
