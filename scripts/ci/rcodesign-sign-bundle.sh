#!/usr/bin/env bash
# PROTOTYPE (no workflow runs it): sign a cmux .app bundle on Linux with
# rcodesign (apple-codesign, pure Rust), in the inside-out order of
# scripts/sign-cmux-bundle.sh, so that macOS can keep only the Xcode build.
# No variable may start with RCODESIGN_: rcodesign reads those as its own
# configuration and stops ("configuration file error ... UnknownField").
#
# usage: scripts/ci/rcodesign-sign-bundle.sh <app> <app-entitlements> <helper-entitlements>
#
# Signing material comes from files, never from argv or the log:
#   CMUX_SIGN_P12_FILE           PKCS#12 with the Developer ID Application key and certificate
#   CMUX_SIGN_P12_PASSWORD_FILE  file with its password
# Other env:
#   CMUX_RCODESIGN                  rcodesign binary (default: rcodesign on PATH)
#   CMUX_SIGN_TIMESTAMP_URL      default Apple's time-stamp server; `none` for a local test
#   CMUX_SIGN_FOR_NOTARIZATION=1 add --for-notarization (requires a Developer ID certificate)
#
# Steps, as scripts/sign-cmux-bundle.sh CMUX_SIGN_MODE=all:
#   1. Mach-O helpers under Contents/Resources/{bin,libexec}: hardened runtime and
#      the helper entitlements; libexec/cmux-server-helper: no entitlements,
#      identifier cmux-server-helper. Symlinks and scripts are left to the seal.
#   2. The nested cmux Computer Use app (helper entitlements).
#   3. Each Contents/PlugIns/* (recursive, like codesign --deep).
#   4. Contents/Frameworks/*: Sparkle's sandbox XPC services removed first,
#      then each framework recursively. A bundle with the Chromium engine is
#      refused: scripts/cmux-next/sign-cef.sh has no rcodesign port yet.
#   5. The main bundle, shallow, with the entitlements reconciled against the
#      embedded provisioning profile (scripts/reconcile-entitlements-with-profile.py).
# Not ported (they run before signing and use no Apple tool):
# scripts/cmux-next/bundle-server-helper.sh --stamp and
# scripts/sign-cmux-tui-ssh-payloads.sh.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed '$d' >&2
  exit 2
fi
APP="$1" APP_ENTITLEMENTS="$2" HELPER_ENTITLEMENTS="$3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RCODESIGN="${CMUX_RCODESIGN:-rcodesign}"
: "${CMUX_SIGN_P12_FILE:?set CMUX_SIGN_P12_FILE to the PKCS#12 path}"
: "${CMUX_SIGN_P12_PASSWORD_FILE:?set CMUX_SIGN_P12_PASSWORD_FILE to the password file path}"
[[ -d "$APP/Contents" ]] || { echo "error: no app bundle at $APP" >&2; exit 1; }
[[ -f "$APP_ENTITLEMENTS" && -f "$HELPER_ENTITLEMENTS" ]] || { echo "error: entitlements file missing" >&2; exit 1; }
if [[ -d "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" ]]; then
  echo "error: the Chromium engine needs scripts/cmux-next/sign-cef.sh, which has no rcodesign port" >&2
  exit 1
fi

COMMON=(--p12-file "$CMUX_SIGN_P12_FILE" --p12-password-file "$CMUX_SIGN_P12_PASSWORD_FILE"
  --code-signature-flags runtime)
if [[ -n "${CMUX_SIGN_TIMESTAMP_URL:-}" ]]; then
  COMMON+=(--timestamp-url "$CMUX_SIGN_TIMESTAMP_URL")
fi
if [[ "${CMUX_SIGN_FOR_NOTARIZATION:-0}" == "1" ]]; then
  COMMON+=(--for-notarization)
fi

is_macho() { # Mach-O thin (feedfacf / cffaedfe) or universal (cafebabe)
  local magic
  magic="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
  [[ "$magic" == cffaedfe || "$magic" == feedfacf || "$magic" == cafebabe ]]
}

sign() { echo "==> rcodesign sign $*" | sed "s#$APP#<app>#g"; "$RCODESIGN" sign "${COMMON[@]}" "$@" >/dev/null; }

# 1. Helpers.
for dir in bin libexec; do
  for helper in "$APP/Contents/Resources/$dir"/*; do
    [[ -L "$helper" || ! -f "$helper" || ! -x "$helper" ]] && continue
    is_macho "$helper" || continue
    if [[ "$dir/$(basename "$helper")" == libexec/cmux-server-helper ]]; then
      sign --binary-identifier cmux-server-helper "$helper"
    else
      sign --entitlements-xml-file "$HELPER_ENTITLEMENTS" "$helper"
    fi
  done
done

# 2. Computer Use helper app.
computer_use="$APP/Contents/Library/cmux Computer Use.app"
[[ -d "$computer_use" ]] && sign --entitlements-xml-file "$HELPER_ENTITLEMENTS" "$computer_use"

# 3. Plugins.
if [[ -d "$APP/Contents/PlugIns" ]]; then
  while IFS= read -r -d '' plugin; do sign "$plugin"; done \
    < <(find "$APP/Contents/PlugIns" -mindepth 1 -maxdepth 1 -print0)
fi

# 4. Frameworks.
if [[ -d "$APP/Contents/Frameworks" ]]; then
  "$ROOT/scripts/remove-sparkle-sandbox-xpc-services.sh" "$APP"
  while IFS= read -r -d '' framework; do sign "$framework"; done \
    < <(find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0)
fi

# 5. Main bundle, shallow, with the effective entitlements.
effective="$(mktemp)" profile_xml="$(mktemp)"; trap 'rm -f "$effective" "$profile_xml"' EXIT
profile_args=(--no-profile)
if [[ -f "$APP/Contents/embedded.provisionprofile" ]]; then
  # The profile is CMS signed data; openssl replaces macOS `security cms -D`.
  openssl cms -verify -noverify -inform DER -in "$APP/Contents/embedded.provisionprofile" -out "$profile_xml" 2>/dev/null
  profile_args=(--profile "$profile_xml")
fi
python3 "$ROOT/scripts/reconcile-entitlements-with-profile.py" \
  --entitlements "$APP_ENTITLEMENTS" "${profile_args[@]}" --output "$effective" >/dev/null
sign --shallow --entitlements-xml-file "$effective" "$APP"
echo "==> rcodesign: signed $APP"
