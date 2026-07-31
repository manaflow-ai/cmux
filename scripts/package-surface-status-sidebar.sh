#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$ROOT/Apps/SurfaceStatus/SurfaceStatus.xcodeproj"
SCHEME="SurfaceStatus"
DERIVED="${CMUX_SURFACE_STATUS_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/cmux-surface-status-release}"
OUTPUT="${CMUX_SURFACE_STATUS_OUTPUT_DIR:-$ROOT/dist/surface-status}"
CONFIGURATION="Release"
APP_NAME="CMUX Surface Status Sidebar.app"
DMG_NAME="CMUX-Surface-Status.dmg"
NOTARY_PROFILE=""
SKIP_NOTARIZE=0

usage() {
  cat <<'EOF'
Build and package the CMUX Surface Status companion app.

Usage:
  scripts/package-surface-status-sidebar.sh [options]

Options:
  --output DIR             Output directory (default: dist/surface-status)
  --derived-data DIR       Xcode DerivedData directory
  --notary-profile NAME    notarytool keychain profile; submits and staples DMG
  --skip-notarize          Build a signed local-test DMG without notarization
  -h, --help               Show this help

Public distribution requires Developer ID Application signing and notarization.
Without --notary-profile, the script refuses a public package unless
--skip-notarize is explicitly supplied.
EOF
}

while (($#)); do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    --derived-data) DERIVED="$2"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$NOTARY_PROFILE" && "$SKIP_NOTARIZE" != "1" ]]; then
  echo "error: pass --notary-profile for public distribution or --skip-notarize for a local-test DMG" >&2
  exit 2
fi

for command in xcodebuild codesign ditto hdiutil shasum; do
  command -v "$command" >/dev/null || { echo "error: missing command: $command" >&2; exit 1; }
done

# AdapterPayloads is the single canonical source used by the app, tests, and
# package. Keeping a second repository copy previously created avoidable drift.
PAYLOADS="$ROOT/Apps/SurfaceStatus/SurfaceStatusApp/AdapterPayloads"
for payload in pi-sidebar-agent-status.txt opencode-sidebar-agent-status.mjs codex-presence-launcher.py codex-presence.zsh; do
  [[ -s "$PAYLOADS/$payload" ]] || { echo "error: missing bundled payload: $payload" >&2; exit 1; }
done
rm -rf "$DERIVED" "$OUTPUT"
find "$ROOT/Apps/SurfaceStatus/SurfaceStatusApp/AdapterPayloads" \
  -type d -name __pycache__ -prune -exec rm -rf {} +
find "$ROOT/Apps/SurfaceStatus/SurfaceStatusApp/AdapterPayloads" \
  -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
mkdir -p "$OUTPUT"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED" \
  build

APP="$DERIVED/Build/Products/$CONFIGURATION/$APP_NAME"
EXTENSION="$APP/Contents/Extensions/CMUX Surface Status Sidebar Extension.appex"
[[ -d "$APP" && -d "$EXTENSION" ]] || { echo "error: built app or extension missing" >&2; exit 1; }
if find "$APP" -type f \( -name '*.pyc' -o -name '*.pyo' \) | grep -q .; then
  echo "error: packaged app contains generated Python bytecode" >&2
  exit 1
fi

codesign --verify --strict --verbose=4 "$APP"
codesign --verify --strict --verbose=4 "$EXTENSION"

# Product boundary: the only Codex addition is the launch-only presence helper;
# no custom lifecycle hook/writer or migration implementation may ship.
FORBIDDEN_PRODUCT_STRINGS=(
  'codex-sidebar-agent-status.py'
  'codex-sidebar-launch.zsh'
  'CMUX_CODEX_HOOKS_DISABLED=1'
  'dangerously-bypass-hook-trust'
  '.claude/settings.json'
  'autoResumeAgentSessions'
  'restore-helper.py'
  'manager.migration.'
  '62af6602d1879605964d13adc70d6c78f9b2ee222fcdacea7ae65c4c44dd9b91'
  '894d7ae6ca4c3abf357f438e6eb85c80988376b42d62d1ab5bc9955f2ef034c8'
  '845935c169ee8782d43c28741887934ea5bfccaf0c9b711cac350d5344c50ae0'
)
for forbidden in "${FORBIDDEN_PRODUCT_STRINGS[@]}"; do
  if rg -a -l --fixed-strings "$forbidden" "$APP" >/dev/null; then
    echo "error: packaged app contains repository-only prototype migration content: $forbidden" >&2
    exit 1
  fi
done

if [[ -n "$NOTARY_PROFILE" ]]; then
  APP_AUTHORITY="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
  EXT_AUTHORITY="$(codesign -dvv "$EXTENSION" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
  [[ "$APP_AUTHORITY" == Developer\ ID\ Application:* ]] || {
    echo "error: notarized distribution requires Developer ID Application signing; got '$APP_AUTHORITY'" >&2
    exit 1
  }
  [[ "$EXT_AUTHORITY" == Developer\ ID\ Application:* ]] || {
    echo "error: extension is not Developer ID Application signed; got '$EXT_AUTHORITY'" >&2
    exit 1
  }
fi

APP_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
EXT_ENTITLEMENTS="$(codesign -d --entitlements :- "$EXTENSION" 2>/dev/null || true)"
if grep -Fq 'com.apple.security.app-sandbox' <<<"$APP_ENTITLEMENTS"; then
  echo "error: containing app must not be sandboxed; it manages explicit user-approved adapter writes" >&2
  exit 1
fi
if ! grep -Fq 'com.apple.security.app-sandbox' <<<"$EXT_ENTITLEMENTS"; then
  echo "error: embedded sidebar extension must remain sandboxed" >&2
  exit 1
fi

STAGE="$OUTPUT/dmg-root"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "CMUX Surface Status" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$OUTPUT/$DMG_NAME"
rm -rf "$STAGE"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$OUTPUT/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUTPUT/$DMG_NAME"
  xcrun stapler validate "$OUTPUT/$DMG_NAME"
else
  echo "warning: produced a local-test DMG; it is not notarized and must not be published" >&2
fi

shasum -a 256 "$OUTPUT/$DMG_NAME" | tee "$OUTPUT/$DMG_NAME.sha256"
echo "Package: $OUTPUT/$DMG_NAME"
