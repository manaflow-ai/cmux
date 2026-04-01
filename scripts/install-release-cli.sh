#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/install-release-cli.sh [--launch] [--no-install-app]

Build the Release cmux.app, find the newest build product, and symlink the
bundled CLI to ~/.local/bin/cmux.

Options:
  --launch          Launch the installed Release app after installation.
  --no-install-app  Do not copy the built app into /Applications/cmux.app.
  -h, --help        Show this help message.
EOF
}

LAUNCH="false"
INSTALL_APP="true"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch)
      LAUNCH="true"
      shift
      ;;
    --no-install-app)
      INSTALL_APP="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

echo "Building Release app..."
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release -destination 'platform=macOS' build

APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/cmux.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"
if [[ -z "${APP_PATH}" ]]; then
  echo "error: cmux.app not found in DerivedData" >&2
  exit 1
fi

CLI_PATH="${APP_PATH}/Contents/Resources/bin/cmux"
if [[ ! -x "${CLI_PATH}" ]]; then
  echo "error: bundled cmux CLI not found at ${CLI_PATH}" >&2
  exit 1
fi

INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "${INSTALL_DIR}"
ln -sfn "${CLI_PATH}" "${INSTALL_DIR}/cmux"

INSTALLED_APP_PATH="${APP_PATH}"
if [[ "${INSTALL_APP}" == "true" ]]; then
  INSTALLED_APP_PATH="/Applications/cmux.app"
  rm -rf "${INSTALLED_APP_PATH}"
  cp -R "${APP_PATH}" "${INSTALLED_APP_PATH}"
fi

echo "Release app:"
echo "  ${APP_PATH}"
if [[ "${INSTALL_APP}" == "true" ]]; then
  echo "Installed app:"
  echo "  ${INSTALLED_APP_PATH}"
fi
echo "Installed CLI:"
echo "  ${INSTALL_DIR}/cmux -> ${INSTALLED_APP_PATH}/Contents/Resources/bin/cmux"
echo ""
echo "Verify:"
echo "  command -v cmux"
echo "  cmux version"
if [[ "${INSTALL_APP}" == "true" ]]; then
  echo "  /Applications/cmux.app/Contents/Resources/bin/cmux version"
fi
echo ""
echo "If your shell still resolves an older path, run:"
echo "  rehash"

if [[ "${LAUNCH}" == "true" ]]; then
  echo ""
  echo "Launching app..."
  env -u GIT_PAGER -u GH_PAGER open -g "${INSTALLED_APP_PATH}"
fi
