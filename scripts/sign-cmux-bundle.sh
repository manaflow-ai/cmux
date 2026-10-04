#!/usr/bin/env bash
# Inside-out codesign a cmux .app bundle for Developer ID + notarization.
#
# Usage:
#   scripts/sign-cmux-bundle.sh <app-path> <app-entitlements> <signing-identity>
#
# Example:
#   scripts/sign-cmux-bundle.sh \
#     "build-universal/Build/Products/Release/cmux NIGHTLY.app" \
#     cmux.nightly.entitlements \
#     "Developer ID Application: Manaflow, Inc. (7WLXT3NR37)"
#
# Optional env:
#   CMUX_HELPER_ENTITLEMENTS  (default: cmux-helper.entitlements)
#   CMUX_TIMESTAMP             set to "none" for un-timestamped local sigs
#   CMUX_SIGN_MODE             "all" (default), "all-except-computer-use", or
#                              "main-only". The split Computer Use notarization
#                              flow uses all-except-computer-use while Apple's
#                              service processes the helper, then main-only after
#                              stapling so the submitted helper CDHash survives.
#
# Signs in the Apple-documented inside-out order:
#   1. Helpers under Contents/Resources/bin/* and libexec/* with minimal
#      hardened-runtime entitlements (no application-identifier).
#      The macOS cmux-tui SSH payloads under Resources/bin/cmux-tui-ssh/ are
#      signed the same way (scripts/sign-cmux-tui-ssh-payloads.sh).
#   2. The nested cmux Computer Use app with the Developer ID identity.
#   3. Each nested plugin under Contents/PlugIns/* with --deep.
#   4. The embedded Chromium engine (CEF framework, its libraries, the shim
#      and the five helper apps with their own entitlements) through
#      scripts/cmux-next/sign-cef.sh, then every other nested framework under
#      Contents/Frameworks/* with --deep (covers Sparkle's XPCServices and
#      Updater.app, and Iroh).
#   5. The main app bundle with the effective app-level entitlements,
#      WITHOUT --deep. --deep here would overwrite helper/plugin
#      signatures and re-introduce the app-id mismatch that amfi on
#      notarized macOS 26 Tahoe rejects with errno 163.
#
# cmux-next ships no Cloud tunnel system extension (the userspace
# `cmux-tui wg hub` replaced it). Signing fails when the bundle carries
# Contents/Library/SystemExtensions or the entitlements request the tunnel.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <app-path> <app-entitlements> <signing-identity>" >&2
  exit 2
fi

APP_PATH="$1"
APP_ENTITLEMENTS="$2"
IDENTITY="$3"
HELPER_ENTITLEMENTS="${CMUX_HELPER_ENTITLEMENTS:-cmux-helper.entitlements}"
SIGN_MODE="${CMUX_SIGN_MODE:-all}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi
if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
  echo "error: app entitlements not found at $APP_ENTITLEMENTS" >&2
  exit 1
fi
if [[ ! -f "$HELPER_ENTITLEMENTS" ]]; then
  echo "error: helper entitlements not found at $HELPER_ENTITLEMENTS" >&2
  exit 1
fi
case "$SIGN_MODE" in
  all|all-except-computer-use|main-only) ;;
  *)
    echo "error: unsupported CMUX_SIGN_MODE: $SIGN_MODE" >&2
    exit 2
    ;;
esac

if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then
  TS_FLAG=(--timestamp=none)
else
  TS_FLAG=(--timestamp)
fi

COMMON=(--force --options runtime "${TS_FLAG[@]}" --sign "$IDENTITY")
COMPUTER_USE_HELPER="$APP_PATH/Contents/Library/cmux Computer Use.app"
SYSTEM_EXTENSIONS_DIR="$APP_PATH/Contents/Library/SystemExtensions"
CEF_FRAMEWORK_NAME="Chromium Embedded Framework.framework"

# Effective app entitlements: the desired file reconciled against the embedded
# provisioning profile. Deterministic, so every CMUX_SIGN_MODE pass agrees.
EFFECTIVE_APP_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/cmux-effective-entitlements.XXXXXX")"
RECONCILE_SUMMARY="$(mktemp "${TMPDIR:-/tmp}/cmux-entitlements-summary.XXXXXX")"
trap 'rm -f "$EFFECTIVE_APP_ENTITLEMENTS" "$RECONCILE_SUMMARY"' EXIT
APP_PROFILE="$APP_PATH/Contents/embedded.provisionprofile"
if [[ -f "$APP_PROFILE" ]]; then
  python3 "$SCRIPT_DIR/reconcile-entitlements-with-profile.py" \
    --entitlements "$APP_ENTITLEMENTS" --profile "$APP_PROFILE" \
    --output "$EFFECTIVE_APP_ENTITLEMENTS" --json > "$RECONCILE_SUMMARY"
else
  python3 "$SCRIPT_DIR/reconcile-entitlements-with-profile.py" \
    --entitlements "$APP_ENTITLEMENTS" --no-profile \
    --output "$EFFECTIVE_APP_ENTITLEMENTS" --json > "$RECONCILE_SUMMARY"
fi
TUNNEL_REQUESTED="$(python3 -c 'import json,sys; print("1" if json.load(open(sys.argv[1]))["tunnel_requested"] else "0")' "$RECONCILE_SUMMARY")"

if [[ "$TUNNEL_REQUESTED" == "1" ]]; then
  echo "error: $(basename "$APP_ENTITLEMENTS") requests the Cloud tunnel system extension, which cmux-next does not ship; remove the NetworkExtension and system-extension entitlements" >&2
  exit 1
fi
if [[ -d "$SYSTEM_EXTENSIONS_DIR" ]]; then
  echo "error: $SYSTEM_EXTENSIONS_DIR exists; cmux-next ships no system extension" >&2
  exit 1
fi

if [[ "$SIGN_MODE" == "all" || "$SIGN_MODE" == "all-except-computer-use" ]]; then
  # 0. The cmux server helper's LaunchDaemon plist follows the FINAL bundle id
  # (nightly and RC rename the bundle after the build); stable drops the helper.
  "$SCRIPT_DIR/cmux-next/bundle-server-helper.sh" --stamp "$APP_PATH"
  # 1. CLI and private helpers
  for helper_dir in bin libexec; do
    for helper in "$APP_PATH/Contents/Resources/$helper_dir"/*; do
      # bin/cmux-tui and bin/acpmux are relative symlinks to bin/cmux, which is
      # signed as itself; the bundle seal records the links.
      if [[ -L "$helper" ]]; then
        echo "==> leaving symlink $(basename "$helper") -> $(readlink "$helper") to the bundle seal"
        continue
      fi
      [[ -f "$helper" && -x "$helper" ]] || continue
      # Scripts are sealed by the bundle signature. Code-signing them directly
      # stores the signature in an extended attribute, which Sparkle's
      # BinaryDelta refuses to diff, so it would block delta updates.
      if ! /usr/bin/file -b "$helper" | grep -q 'Mach-O'; then
        echo "==> leaving non-Mach-O helper $(basename "$helper") to the bundle seal"
        continue
      fi
      if [[ "$(basename "$helper")" == "cmux-server-helper" ]]; then
        # A root LaunchDaemon gets no entitlements (no JIT, no library validation opt-out).
        echo "==> signing root helper cmux-server-helper (no entitlements)"
        /usr/bin/codesign "${COMMON[@]}" --identifier cmux-server-helper "$helper"
        continue
      fi
      echo "==> signing helper $(basename "$helper")"
      /usr/bin/codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$helper"
    done
  done
  # cmux-tui builds for SSH hosts. Notarization requires the macOS ones to be
  # Developer ID signed; the script re-pins them in the bundled manifest.
  "$SCRIPT_DIR/sign-cmux-tui-ssh-payloads.sh" "$APP_PATH" "$HELPER_ENTITLEMENTS" "$IDENTITY"

  # 2. Computer Use helper app. An early notarization submission owns this
  # signature in all-except-computer-use mode; changing it would invalidate the
  # ticket that finish is waiting to staple.
  if [[ "$SIGN_MODE" == "all" && -d "$COMPUTER_USE_HELPER" ]]; then
    echo "==> signing nested helper $(basename "$COMPUTER_USE_HELPER")"
    /usr/bin/codesign \
      "${COMMON[@]}" \
      --entitlements "$HELPER_ENTITLEMENTS" \
      "$COMPUTER_USE_HELPER"
  fi

  # 3. Plugins
  if [[ -d "$APP_PATH/Contents/PlugIns" ]]; then
    while IFS= read -r -d '' plugin; do
      echo "==> signing plugin $(basename "$plugin")"
      /usr/bin/codesign "${COMMON[@]}" --deep "$plugin"
    done < <(find "$APP_PATH/Contents/PlugIns" -mindepth 1 -maxdepth 1 -print0)
  fi

  # 4. Frameworks. The Chromium engine first, with its own per-helper
  # entitlements; --deep would re-sign its helpers without them.
  if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
    "$SCRIPT_DIR/remove-sparkle-sandbox-xpc-services.sh" "$APP_PATH"
    if [[ -d "$APP_PATH/Contents/Frameworks/$CEF_FRAMEWORK_NAME" ]]; then
      echo "==> signing the Chromium engine (CEF framework, shim, helpers)"
      "$SCRIPT_DIR/cmux-next/sign-cef.sh" "$APP_PATH" "$IDENTITY"
    fi
    while IFS= read -r -d '' framework; do
      case "$(basename "$framework")" in
        "$CEF_FRAMEWORK_NAME"|libcmux_cef_shim.dylib|*" Helper.app"|*" Helper ("*").app") continue ;;
      esac
      echo "==> signing framework $(basename "$framework")"
      /usr/bin/codesign "${COMMON[@]}" --deep "$framework"
    done < <(find "$APP_PATH/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0)
  fi
fi

# 5. Main app bundle (no --deep), with the effective entitlements.
echo "==> signing main bundle ($SIGN_MODE)"
/usr/bin/codesign "${COMMON[@]}" --entitlements "$EFFECTIVE_APP_ENTITLEMENTS" "$APP_PATH"

echo "==> verifying"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
# The cmux CLI is one Mach-O: bin/cmux-tui and bin/acpmux must stay links to it.
for alias in cmux-tui acpmux; do
  alias_path="$APP_PATH/Contents/Resources/bin/$alias"
  if [[ -e "$alias_path" || -L "$alias_path" ]] && [[ "$(readlink "$alias_path" || true)" != cmux ]]; then
    echo "error: bin/$alias is not a symlink to cmux" >&2
    exit 1
  fi
done
if [[ -d "$COMPUTER_USE_HELPER" ]]; then
  /usr/bin/codesign --verify --strict --verbose=2 "$COMPUTER_USE_HELPER"
fi
# The sidecar must carry exactly the slices the app does: universal for stable
# and the transitional nightly, one architecture for thinned nightlies.
"$SCRIPT_DIR/verify-diff-sidecar-artifact.sh" \
  "$APP_PATH/Contents/Resources/bin/cmux-diff-sidecar" \
  --archs "$(lipo -archs "$APP_PATH/Contents/MacOS/cmux")" \
  --require-signed

APP_ID="$(/usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" \
  /dev/stdin <<<"$(plutil -convert xml1 -o - "$APP_ENTITLEMENTS")" 2>/dev/null || true)"

if [[ -n "$APP_ID" ]]; then
  /usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>&1 | grep -q "$APP_ID" || {
    echo "error: signed app missing application-identifier $APP_ID" >&2
    exit 1
  }
fi
# The WebAuthn browser entitlement is an Apple-approved capability request.
# Stable and nightly request it; the RC App ID's request is still pending, so
# cmux.rc.entitlements omits it. Assert it only when the channel asks for it,
# so a channel that requests it can never ship without it.
if plutil -convert xml1 -o - "$APP_ENTITLEMENTS" 2>/dev/null \
  | grep -q "com.apple.developer.web-browser.public-key-credential"; then
  /usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>&1 \
    | grep -q "com.apple.developer.web-browser.public-key-credential" || {
      echo "error: signed app missing web-browser entitlement" >&2
      exit 1
    }
else
  echo "note: $(basename "$APP_ENTITLEMENTS") does not request the web-browser entitlement; skipping that check"
fi

# These capabilities identify cmux as the responsible app for child-process
# requests to macOS personal-information services. Keep this check next to the
# signing step so a release cannot silently regress to the old denial behavior.
SIGNED_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/cmux-signed-entitlements.XXXXXX")"
trap 'rm -f "$SIGNED_ENTITLEMENTS" "$EFFECTIVE_APP_ENTITLEMENTS" "$RECONCILE_SUMMARY"' EXIT
/usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>/dev/null > "$SIGNED_ENTITLEMENTS" || {
  echo "error: unable to read signed app entitlements" >&2
  exit 1
}

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

# No NetworkExtension entitlement may reach the signed app: without a
# provisioning profile that grants it and a bundled extension, it would not
# launch.
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
    if /usr/bin/codesign -d --entitlements :- "$helper" 2>&1 \
         | grep -q "application-identifier"; then
      echo "error: helper $(basename "$helper") unexpectedly carries application-identifier" >&2
      exit 1
    fi
  done
done

if [[ -d "$COMPUTER_USE_HELPER" ]] \
   && /usr/bin/codesign -d --entitlements :- "$COMPUTER_USE_HELPER" 2>&1 \
        | grep -q "application-identifier"; then
  echo "error: nested Computer Use helper unexpectedly carries application-identifier" >&2
  exit 1
fi

echo "==> signing OK: $APP_PATH"
