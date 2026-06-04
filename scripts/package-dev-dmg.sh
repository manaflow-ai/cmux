#!/usr/bin/env bash
# Package a tagged DEV .app into a draggable .dmg for hand-off to the user.
#
# Output: ~/Downloads/cmux-dev-<tag>-<short-sha>.dmg
#
# The dmg contains:
#   cmux DEV <tag>.app            (the actual build, codesigned ad-hoc)
#   /Applications                 (symlink, like the real release dmg)
#   A README stub telling the user to drag the .app anywhere EXCEPT /Applications
#
# Usage:
#   scripts/package-dev-dmg.sh                 # package the .app currently in ~/Downloads/cmux-dev/
#   scripts/package-dev-dmg.sh --tag <tag>     # explicit tag (default: pick newest in ~/Downloads/cmux-dev/)
#   scripts/package-dev-dmg.sh --app <path>    # package a specific .app instead

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOADS_DEV_DIR="$HOME/Downloads/cmux-dev"
DMG_OUTPUT_DIR="$HOME/Downloads"
DMG_NAME_PREFIX="cmux-dev"
DMG_VOLUME_NAME="cmux DEV"
STAGING_DIR="$(mktemp -d -t cmux-dev-dmg.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT

TAG=""
APP_PATH=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--tag <tag>] [--app <path>]

If --app is not given, picks the most recently modified "cmux DEV *.app"
under $DOWNLOADS_DEV_DIR.
USAGE
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --app) APP_PATH="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

# Resolve the .app to package.
if [[ -z "$APP_PATH" ]]; then
  if [[ ! -d "$DOWNLOADS_DEV_DIR" ]]; then
    echo "error: $DOWNLOADS_DEV_DIR does not exist; run ./scripts/reload.sh --tag <name> first" >&2
    exit 65
  fi
  if [[ -n "$TAG" ]]; then
    APP_PATH="$DOWNLOADS_DEV_DIR/cmux DEV ${TAG}.app"
  else
    APP_PATH=$(ls -td "$DOWNLOADS_DEV_DIR"/cmux\ DEV\ *.app 2>/dev/null | head -1 || true)
  fi
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "error: could not find a .app to package (looked for: ${APP_PATH:-<auto>})" >&2
  exit 65
fi

APP_BASENAME="$(basename "$APP_PATH")"
# Strip the trailing ".app" and leading "cmux DEV " to derive a tag suffix.
APP_TAG="${APP_BASENAME#cmux DEV }"
APP_TAG="${APP_TAG%.app}"
if [[ -z "$APP_TAG" || "$APP_TAG" == "$APP_BASENAME" ]]; then
  echo "error: app name does not look like a tagged DEV build: $APP_BASENAME" >&2
  echo "       expected 'cmux DEV <tag>.app'" >&2
  exit 65
fi

SHORT_SHA=""
if command -v git >/dev/null 2>&1 && [[ -d "$REPO_ROOT/.git" ]]; then
  SHORT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)
fi
SUFFIX="${APP_TAG}"
if [[ -n "$SHORT_SHA" ]]; then
  SUFFIX="${APP_TAG}-${SHORT_SHA}"
fi
DMG_PATH="$DMG_OUTPUT_DIR/${DMG_NAME_PREFIX}-${SUFFIX}.dmg"

echo "Packaging DEV build for hand-off"
echo "  source app : $APP_PATH"
echo "  dmg output : $DMG_PATH"

# Stage dmg contents: copy the .app and add an Applications symlink like the
# real release dmg, plus a README warning the user not to overwrite the
# public release at /Applications.
STAGED_APP="$STAGING_DIR/$APP_BASENAME"
cp -R "$APP_PATH" "$STAGED_APP"
ln -s /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/README.txt" <<README
cmux DEV build (tag: $APP_TAG)

DO NOT drag cmux DEV $APP_TAG.app into /Applications.
This is a developer build. /Applications is reserved for the public cmux release,
which has its own bundle identifier, UserDefaults, keychain, and Sparkle appcast.
Dropping this .app into /Applications will break the public release's auto-update.

Recommended locations:
  ~/Applications          (create the folder if needed; launchctl will pick it up)
  ~/Downloads/cmux-dev/   (where the .app was packaged from)
  any folder on Desktop

To run:  open "$APP_BASENAME"
To follow logs:  tail -f /tmp/cmux-debug-${APP_TAG}.log
README

# Re-sign ad-hoc inside the staging copy so Gatekeeper does not complain on
# double-click; the staged .app was copied and may have lost its signature.
xattr -cr "$STAGED_APP" 2>/dev/null || true
if /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der \
     --entitlements "$REPO_ROOT/cmux/cmux.entitlements" "$STAGED_APP" 2>/dev/null; then
  echo "  re-signed staged app (ad-hoc)"
else
  echo "  re-sign skipped (CMUX_ALLOW_UNSIGNED_DEV_APP or entitlements missing); dmg may Gatekeeper-warn"
fi

# Build the dmg with hdiutil. UDRO is read-only; we want read-only so the
# user can't mutate the archive and so checksums stay stable.
mkdir -p "$DMG_OUTPUT_DIR"
rm -f "$DMG_PATH"
hdiutil create -volname "$DMG_VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDRO \
  -fs HFS+ \
  "$DMG_PATH" >/dev/null

echo
echo "Done. Drag-ready dmg at:"
echo "  $DMG_PATH"
echo
echo "Hand-off instructions for the user:"
echo "  1. open $DMG_PATH"
echo "  2. drag cmux DEV $APP_TAG.app anywhere EXCEPT /Applications (e.g. ~/Applications or Desktop)"
echo "  3. open it from Finder; the user is up and running with a fully isolated DEV build"
