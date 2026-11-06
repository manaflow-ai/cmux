#!/usr/bin/env bash
# The checks scripts/sign-cmux-bundle.sh makes on the app it signed, made again
# on a signed app whichever signer produced it. verify-signed-nightly runs it,
# on a Mac, in a job without secrets: the browser host check runs the bundled
# host's `version`, as sign-cmux-bundle.sh does.
#
#   scripts/ci/check-signed-app.sh <app> <app-entitlements>
#
# The diff sidecar check (verify-diff-sidecar-artifact.sh) and codesign
# --verify --deep --strict of the app are steps of their own in that job.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

[[ $# -eq 2 ]] || { echo "usage: $0 <app> <app-entitlements>" >&2; exit 2; }
APP_PATH="$1" APP_ENTITLEMENTS="$2"
[[ -d "$APP_PATH/Contents" ]] || { echo "error: app bundle not found at $APP_PATH" >&2; exit 1; }
[[ -f "$APP_ENTITLEMENTS" ]] || { echo "error: app entitlements not found at $APP_ENTITLEMENTS" >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-signed-app-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The cmux CLI is one Mach-O: bin/cmux-tui and bin/acpmux must stay links to it.
for alias in cmux-tui acpmux; do
  alias_path="$APP_PATH/Contents/Resources/bin/$alias"
  if [[ -e "$alias_path" || -L "$alias_path" ]] && [[ "$(readlink "$alias_path" || true)" != cmux ]]; then
    echo "error: bin/$alias is not a symlink to cmux" >&2
    exit 1
  fi
done

# The browser host, when the bundle carries one: Developer ID, hardened runtime.
"$ROOT/scripts/cmux-next/check-bundled-browser-host.sh" "$APP_PATH" --hardened

SIGNED_ENTITLEMENTS="$work/signed.entitlements"
/usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>/dev/null > "$SIGNED_ENTITLEMENTS" || {
  echo "error: unable to read signed app entitlements" >&2
  exit 1
}
APP_ID="$(/usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" \
  /dev/stdin <<<"$(plutil -convert xml1 -o - "$APP_ENTITLEMENTS")" 2>/dev/null || true)"
if [[ -n "$APP_ID" ]] && ! grep -q "$APP_ID" "$SIGNED_ENTITLEMENTS"; then
  echo "error: signed app missing application-identifier $APP_ID" >&2
  exit 1
fi
# The WebAuthn browser entitlement, only when the channel requests it.
if plutil -convert xml1 -o - "$APP_ENTITLEMENTS" 2>/dev/null \
  | grep -q "com.apple.developer.web-browser.public-key-credential"; then
  grep -q "com.apple.developer.web-browser.public-key-credential" "$SIGNED_ENTITLEMENTS" || {
    echo "error: signed app missing web-browser entitlement" >&2
    exit 1
  }
fi
for entitlement in \
  com.apple.security.personal-information.addressbook \
  com.apple.security.personal-information.calendars \
  com.apple.security.personal-information.location \
  com.apple.security.personal-information.photos-library; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$SIGNED_ENTITLEMENTS" 2>/dev/null || true)"
  if [[ "$value" != "true" ]]; then
    echo "error: signed app missing enabled $entitlement" >&2
    exit 1
  fi
done
if grep -q "com.apple.developer.networking.networkextension" "$SIGNED_ENTITLEMENTS"; then
  echo "error: signed app carries a NetworkExtension entitlement; cmux-next ships no Cloud tunnel system extension" >&2
  exit 1
fi

# Helpers must NOT carry the main app's application-identifier.
for helper_dir in bin libexec; do
  for helper in "$APP_PATH/Contents/Resources/$helper_dir"/*; do
    [[ ! -L "$helper" ]] || continue
    [[ -f "$helper" && -x "$helper" ]] || continue
    /usr/bin/file -b "$helper" | grep -q 'Mach-O' || continue
    if /usr/bin/codesign -d --entitlements :- "$helper" 2>&1 | grep -q "application-identifier"; then
      echo "error: helper $(basename "$helper") unexpectedly carries application-identifier" >&2
      exit 1
    fi
  done
done
echo "==> entitlements, helpers and browser host: OK"
