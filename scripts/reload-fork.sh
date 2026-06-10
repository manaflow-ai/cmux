#!/usr/bin/env bash
# Build a Release app from a fork, without Manaflow's signing certificates.
#
# Personal values come from env vars or a `.fork-config` file at the repo root.
# The file is sourced as shell, so quote values containing spaces
# (FORK_APP_NAME="my cmux"); keep it out of git via .git/info/exclude.
#   FORK_BUNDLE_ID   required. Must be in YOUR namespace, e.g. dev.you.cmux.staging
#                    (com.cmuxterm.* is registered to Manaflow's Apple team).
#   FORK_TEAM_ID     optional. Apple team ID for development signing (free personal
#                    teams work). When unset, builds ad-hoc with no entitlements.
#   FORK_APP_NAME    optional display name. Default: "cmux STAGING".
#
# CMUX_SKIP_ZIG_BUILD=1 is passed through if set (needed where zig 0.15.2 cannot
# link against the host SDK; see scripts/build-ghostty-cli-helper.sh).
#
# Usage: ./scripts/reload-fork.sh [--install]
#   --install  copy the built app to ~/Applications/"$FORK_APP_NAME.app"
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
case "${1:-}" in
  --install) INSTALL=1 ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; exit 1 ;;
esac

if [[ -f .fork-config ]]; then
  # shellcheck disable=SC1091
  source .fork-config
fi

FORK_APP_NAME="${FORK_APP_NAME:-cmux STAGING}"
FORK_TEAM_ID="${FORK_TEAM_ID:-}"
if [[ -z "${FORK_BUNDLE_ID:-}" ]]; then
  echo "error: FORK_BUNDLE_ID is not set." >&2
  echo "Set it in .fork-config or the environment, e.g.:" >&2
  echo "  echo 'FORK_BUNDLE_ID=dev.you.cmux.staging' >> .fork-config" >&2
  echo "Use your own namespace: com.cmuxterm.* cannot be registered to other teams." >&2
  exit 1
fi

DERIVED_DATA="/tmp/cmux-release-fork"

XCODEBUILD_ARGS=(
  -project cmux.xcodeproj
  -scheme cmux
  -configuration Release
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED_DATA"
  INFOPLIST_KEY_CFBundleName="$FORK_APP_NAME"
  INFOPLIST_KEY_CFBundleDisplayName="$FORK_APP_NAME"
  PRODUCT_BUNDLE_IDENTIFIER="$FORK_BUNDLE_ID"
)

if [[ -n "$FORK_TEAM_ID" ]]; then
  echo "==> Release build signed with team $FORK_TEAM_ID ($FORK_BUNDLE_ID)"
  XCODEBUILD_ARGS+=(
    DEVELOPMENT_TEAM="$FORK_TEAM_ID"
    -allowProvisioningUpdates
    CODE_SIGN_ENTITLEMENTS=scripts/fork-dev.entitlements
  )
else
  echo "==> Release build with ad-hoc signing ($FORK_BUNDLE_ID); set FORK_TEAM_ID for a signed build"
  XCODEBUILD_ARGS+=(CODE_SIGN_ENTITLEMENTS="")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build

APP="$DERIVED_DATA/Build/Products/Release/cmux.app"
if [[ ! -d "$APP" ]]; then
  echo "error: build succeeded but app not found at $APP" >&2
  exit 1
fi

echo
echo "App path:"
echo "  $APP"

if [[ "$INSTALL" -eq 1 ]]; then
  TARGET="$HOME/Applications/$FORK_APP_NAME.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$TARGET"
  cp -R "$APP" "$TARGET"
  echo
  echo "Installed:"
  echo "  $TARGET"
fi
