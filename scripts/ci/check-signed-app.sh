#!/usr/bin/env bash
# The checks scripts/sign-cmux-bundle.sh makes on the app it signed, made again
# on a signed app whichever signer produced it, plus the Computer Use helper's
# own ticket on a copy taken out of the app. verify-signed-nightly runs it, on
# a Mac, in a job without secrets: the browser host check runs the bundled
# host's `version`, as sign-cmux-bundle.sh does.
#
#   scripts/ci/check-signed-app.sh <app> <app-entitlements> [--require-helper-ticket]
#
# The diff sidecar check (verify-diff-sidecar-artifact.sh) and codesign
# --verify --deep --strict of the app are steps of their own in that job.
#
# The helper: cmux copies it out of the app before it runs it, so its own
# stapled ticket must keep that copy valid with no network. The copy is made
# with ditto, as notarize-computer-use-helper.sh validates it; stapler validate
# checks the stapled ticket against the copy's CDHash locally, and codesign
# and spctl assess the copy with it. A helper with no ticket of its own (the
# Mac signer staples it after this copy of the app was taken; the DMG ticket
# covers it) is a notice, or a failure with --require-helper-ticket.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

[[ $# -ge 2 && $# -le 3 ]] || { echo "usage: $0 <app> <app-entitlements> [--require-helper-ticket]" >&2; exit 2; }
APP_PATH="$1" APP_ENTITLEMENTS="$2" REQUIRE_TICKET=false
if [[ $# -eq 3 ]]; then
  [[ "$3" == --require-helper-ticket ]] || { echo "error: unknown option $3" >&2; exit 2; }
  REQUIRE_TICKET=true
fi
[[ -d "$APP_PATH/Contents" ]] || { echo "error: app bundle not found at $APP_PATH" >&2; exit 1; }
[[ -f "$APP_ENTITLEMENTS" ]] || { echo "error: app entitlements not found at $APP_ENTITLEMENTS" >&2; exit 1; }
COMPUTER_USE_HELPER="$APP_PATH/Contents/Library/cmux Computer Use.app"
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

if [[ ! -d "$COMPUTER_USE_HELPER" ]]; then
  [[ "$REQUIRE_TICKET" == false ]] || { echo "error: no Computer Use helper in this app" >&2; exit 1; }
  echo "==> no Computer Use helper in this app"
  exit 0
fi
/usr/bin/codesign --verify --strict --verbose=2 "$COMPUTER_USE_HELPER"
if /usr/bin/codesign -d --entitlements :- "$COMPUTER_USE_HELPER" 2>&1 | grep -q "application-identifier"; then
  echo "error: nested Computer Use helper unexpectedly carries application-identifier" >&2
  exit 1
fi
if [[ ! -f "$COMPUTER_USE_HELPER/Contents/CodeResources" ]]; then
  if [[ "$REQUIRE_TICKET" == true ]]; then
    echo "error: the Computer Use helper has no stapled ticket of its own" >&2
    exit 1
  fi
  echo "::notice title=Computer Use helper::no stapled ticket of its own in this copy of the app; the DMG ticket covers it"
  exit 0
fi
# shellcheck source=lib/notarization-ticket.sh
source "$SCRIPT_DIR/lib/notarization-ticket.sh"
# shellcheck source=lib/gatekeeper-assessment.sh
source "$SCRIPT_DIR/lib/gatekeeper-assessment.sh"
copy="$work/standalone/cmux Computer Use.app"
mkdir -p "$work/standalone"
/usr/bin/ditto "$COMPUTER_USE_HELPER" "$copy"
xcrun stapler validate "$copy"
verify_stapled_ticket_covers_slices "$copy"
/usr/bin/codesign --verify --strict --verbose=2 "$copy"
# Uncached, with the propagation retries notarize-computer-use-helper.sh uses.
assess_with_gatekeeper "$copy"
echo "==> Computer Use helper: a copy out of the app keeps its own stapled ticket"
