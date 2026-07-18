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
# Test-only tool injection:
#   CMUX_CODESIGN_TOOL
#   CMUX_VERIFY_COMMAND_PALETTE_TOOL
#   CMUX_VERIFY_DIFF_SIDECAR_TOOL
#
# Signs in the Apple-documented inside-out order:
#   1. CLI helpers under Contents/Resources/bin/* with minimal hardened-runtime
#      entitlements. Hook transport helpers are entitlement-free because they
#      only perform local IPC and process supervision.
#   2. Each nested plugin under Contents/PlugIns/* with --deep.
#   3. Each nested framework under Contents/Frameworks/* with --deep
#      (covers Sparkle's XPCServices and Updater.app).
#   4. The main app bundle with the provided app-level entitlements,
#      WITHOUT --deep. --deep here would overwrite helper/plugin
#      signatures and re-introduce the app-id mismatch that amfi on
#      notarized macOS 26 Tahoe rejects with errno 163.

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
CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
VERIFY_COMMAND_PALETTE_TOOL="${CMUX_VERIFY_COMMAND_PALETTE_TOOL:-$SCRIPT_DIR/verify-command-palette-nucleo-ffi-artifact.sh}"
VERIFY_DIFF_SIDECAR_TOOL="${CMUX_VERIFY_DIFF_SIDECAR_TOOL:-$SCRIPT_DIR/verify-diff-sidecar-artifact.sh}"

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

if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then
  TS_FLAG=(--timestamp=none)
else
  TS_FLAG=(--timestamp)
fi

COMMON=(--force --options runtime "${TS_FLAG[@]}" --sign "$IDENTITY")

# 1. CLI helpers
for helper in "$APP_PATH/Contents/Resources/bin"/*; do
  [[ -f "$helper" && -x "$helper" ]] || continue
  echo "==> signing helper $(basename "$helper")"
  case "$(basename "$helper")" in
    cmux-codex-hook-client|cmux-agent-hook-supervisor)
      "$CODESIGN_TOOL" "${COMMON[@]}" "$helper"
      ;;
    *)
      "$CODESIGN_TOOL" "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$helper"
      ;;
  esac
done

# 2. Plugins
if [[ -d "$APP_PATH/Contents/PlugIns" ]]; then
  while IFS= read -r -d '' plugin; do
    echo "==> signing plugin $(basename "$plugin")"
    "$CODESIGN_TOOL" "${COMMON[@]}" --deep "$plugin"
  done < <(find "$APP_PATH/Contents/PlugIns" -mindepth 1 -maxdepth 1 -print0)
fi

# 3. Frameworks
if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
  "$SCRIPT_DIR/remove-sparkle-sandbox-xpc-services.sh" "$APP_PATH"
  while IFS= read -r -d '' framework; do
    echo "==> signing framework $(basename "$framework")"
    "$CODESIGN_TOOL" "${COMMON[@]}" --deep "$framework"
  done < <(find "$APP_PATH/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0)
fi

# 4. Main app bundle (no --deep).
echo "==> signing main bundle"
"$CODESIGN_TOOL" "${COMMON[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"

echo "==> verifying"
"$CODESIGN_TOOL" --verify --deep --strict --verbose=2 "$APP_PATH"
"$VERIFY_COMMAND_PALETTE_TOOL" "$APP_PATH"
"$VERIFY_DIFF_SIDECAR_TOOL" \
  "$APP_PATH/Contents/Resources/bin/cmux-diff-sidecar" \
  --require-signed

APP_ID="$(/usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" \
  /dev/stdin <<<"$(plutil -convert xml1 -o - "$APP_ENTITLEMENTS")" 2>/dev/null || true)"

if [[ -n "$APP_ID" ]]; then
  "$CODESIGN_TOOL" -d --entitlements :- "$APP_PATH" 2>&1 | grep -q "$APP_ID" || {
    echo "error: signed app missing application-identifier $APP_ID" >&2
    exit 1
  }
fi
"$CODESIGN_TOOL" -d --entitlements :- "$APP_PATH" 2>&1 \
  | grep -q "com.apple.developer.web-browser.public-key-credential" || {
    echo "error: signed app missing web-browser entitlement" >&2
    exit 1
  }

# Helpers must NOT carry the main app's application-identifier.
for helper in "$APP_PATH/Contents/Resources/bin"/*; do
  [[ -f "$helper" && -x "$helper" ]] || continue
  if "$CODESIGN_TOOL" -d --entitlements :- "$helper" 2>&1 \
       | grep -q "application-identifier"; then
    echo "error: helper $(basename "$helper") unexpectedly carries application-identifier" >&2
    exit 1
  fi
done

for hook_helper in \
  "$APP_PATH/Contents/Resources/bin/cmux-codex-hook-client" \
  "$APP_PATH/Contents/Resources/bin/cmux-agent-hook-supervisor"
do
  CMUX_CODESIGN_TOOL="$CODESIGN_TOOL" \
    "$SCRIPT_DIR/verify-hook-helper-signature.sh" "$hook_helper"
done

echo "==> signing OK: $APP_PATH"
