#!/usr/bin/env bash

cmux_ci_repo="${CMUX_GITHUB_REPO:-manaflow-ai/cmux}"
cmux_ci_create_dmg_version="${CREATE_DMG_VERSION:-8.0.0}"

cmux_ci_require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

cmux_ci_export_github_token() {
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "Missing GH_TOKEN or GITHUB_TOKEN in CircleCI. Set a GitHub token with contents:write access." >&2
    exit 1
  fi
}

cmux_ci_decode_base64_to_file() {
  local value="$1"
  local output="$2"

  if ! printf "%s" "$value" | base64 --decode > "$output" 2>/dev/null; then
    printf "%s" "$value" | base64 -D > "$output"
  fi
}

cmux_ci_select_xcode() {
  set -euo pipefail

  if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    XCODE_DIR="/Applications/Xcode.app/Contents/Developer"
  else
    XCODE_APP="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -n 1 || true)"
    if [ -n "$XCODE_APP" ]; then
      XCODE_DIR="$XCODE_APP/Contents/Developer"
    else
      echo "No Xcode.app found under /Applications" >&2
      exit 1
    fi
  fi

  export DEVELOPER_DIR="$XCODE_DIR"
  xcodebuild -version
  xcrun --sdk macosx --show-sdk-path
}

cmux_ci_install_build_deps() {
  set -euo pipefail

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    brew install node
  fi
  if ! command -v gh >/dev/null 2>&1; then
    brew install gh
  fi
  if ! command -v go >/dev/null 2>&1; then
    brew install go
  fi

  NPM_GLOBAL="$HOME/.npm-global"
  mkdir -p "$NPM_GLOBAL"
  npm install --global --prefix "$NPM_GLOBAL" "create-dmg@${cmux_ci_create_dmg_version}"
  export PATH="$NPM_GLOBAL/bin:$PATH"

  node --version
  npm --version
  gh --version | head -n 1
  go version
  create-dmg --version || true
}

cmux_ci_derive_sparkle_public_key() {
  cmux_ci_require_env SPARKLE_PRIVATE_KEY
  SPARKLE_PUBLIC_KEY="$(swift scripts/derive_sparkle_public_key.swift "$SPARKLE_PRIVATE_KEY")"
  export SPARKLE_PUBLIC_KEY
  echo "Derived Sparkle public key: $SPARKLE_PUBLIC_KEY"
}

cmux_ci_build_universal_release_app() {
  set -euo pipefail

  local icon_name="${1:-}"
  local icon_arg=()
  if [ -n "$icon_name" ]; then
    icon_arg=(ASSETCATALOG_COMPILER_APPICON_NAME="$icon_name")
  fi

  xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release -derivedDataPath build-universal \
    -destination "generic/platform=macOS" \
    -clonedSourcePackagesDirPath .spm-cache \
    -disableAutomaticPackageResolution \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    "${icon_arg[@]}" \
    build
}

cmux_ci_verify_binary_architectures() {
  set -euo pipefail

  local app_path="$1"
  local app_binary="$app_path/Contents/MacOS/cmux"
  local cli_binary="$app_path/Contents/Resources/bin/cmux"
  local helper_binary="$app_path/Contents/Resources/bin/ghostty"
  local app_archs cli_archs helper_archs

  app_archs="$(lipo -archs "$app_binary")"
  cli_archs="$(lipo -archs "$cli_binary")"
  helper_archs="$(lipo -archs "$helper_binary")"
  echo "App binary architectures: $app_archs"
  echo "CLI binary architectures: $cli_archs"
  echo "Ghostty helper architectures: $helper_archs"
  [[ "$app_archs" == *arm64* && "$app_archs" == *x86_64* ]]
  [[ "$cli_archs" == *arm64* && "$cli_archs" == *x86_64* ]]
  [[ "$helper_archs" == *arm64* && "$helper_archs" == *x86_64* ]]
}

cmux_ci_import_signing_cert() {
  set -euo pipefail

  cmux_ci_require_env APPLE_CERTIFICATE_BASE64
  cmux_ci_require_env APPLE_CERTIFICATE_PASSWORD

  KEYCHAIN_PASSWORD="$(uuidgen)"
  cmux_ci_decode_base64_to_file "$APPLE_CERTIFICATE_BASE64" /tmp/cert.p12
  security delete-keychain build.keychain >/dev/null 2>&1 || true
  security create-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
  security set-keychain-settings -lut 21600 build.keychain
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
  security import /tmp/cert.p12 -k build.keychain -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" build.keychain
  security list-keychains -d user -s build.keychain
}

cmux_ci_cleanup_keychain() {
  security delete-keychain build.keychain >/dev/null 2>&1 || true
  rm -f /tmp/cert.p12
}

cmux_ci_upload_dsyms_to_sentry() {
  set -euo pipefail

  if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
    echo "SENTRY_AUTH_TOKEN not set, skipping dSYM upload"
    return 0
  fi

  export SENTRY_ORG="${SENTRY_ORG:-manaflow}"
  export SENTRY_PROJECT="${SENTRY_PROJECT:-cmuxterm-macos}"
  brew install getsentry/tools/sentry-cli || true
  sentry-cli debug-files upload --include-sources build-universal/Build/Products/Release/
}

cmux_ci_upload_appcast_to_r2() {
  set -euo pipefail

  local channel="$1"
  local should_upload="${2:-true}"
  if [ "$should_upload" != "true" ]; then
    echo "Skipping R2 $channel appcast upload"
    return 0
  fi

  if [ -z "${CF_R2_ACCESS_KEY_ID:-}" ] || [ -z "${CF_R2_SECRET_ACCESS_KEY:-}" ] || [ -z "${CF_R2_ACCOUNT_ID:-}" ]; then
    echo "R2 credentials are not set, skipping $channel appcast upload"
    return 0
  fi

  command -v aws >/dev/null 2>&1 || brew install awscli

  AWS_ACCESS_KEY_ID="$CF_R2_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$CF_R2_SECRET_ACCESS_KEY" \
  AWS_DEFAULT_REGION=auto \
  aws s3 cp appcast.xml \
    "s3://cmux-binaries/${channel}/appcast.xml" \
    --endpoint-url "https://${CF_R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
    --cache-control "no-cache, no-store, must-revalidate"

  echo "R2 appcast upload complete: https://files.cmux.com/${channel}/appcast.xml"
}

cmux_ci_release_asset_guard() {
  set -euo pipefail

  local tag="$1"
  local names_file="/tmp/cmux-release-asset-names.txt"
  local guard_file="/tmp/cmux-release-asset-guard.env"
  rm -f "$names_file" "$guard_file"

  if ! gh release view "$tag" --repo "$cmux_ci_repo" --json assets --jq '.assets[].name' > "$names_file" 2>/tmp/cmux-release-view.err; then
    if grep -qi "not found\\|404" /tmp/cmux-release-view.err; then
      echo "Release $tag does not exist yet, continuing."
      return 1
    fi
    cat /tmp/cmux-release-view.err >&2
    return 2
  fi

  set +e
  ASSET_NAMES_FILE="$names_file" node > "$guard_file" <<'NODE'
const fs = require("node:fs");
const { evaluateReleaseAssetGuard } = require("./scripts/release_asset_guard");
const existingAssetNames = fs.readFileSync(process.env.ASSET_NAMES_FILE, "utf8")
  .split(/\r?\n/)
  .filter(Boolean);
const result = evaluateReleaseAssetGuard({ existingAssetNames });

console.log(`GUARD_STATE=${result.guardState}`);
console.log(`SKIP_ALL=${result.shouldSkipBuildAndUpload ? "true" : "false"}`);
console.log(`CONFLICTS=${JSON.stringify(result.conflicts)}`);
console.log(`MISSING_IMMUTABLE_ASSETS=${JSON.stringify(result.missingImmutableAssets)}`);

if (result.hasPartialConflict) {
  process.exitCode = 3;
}
NODE
  local node_status=$?
  set -e
  # shellcheck disable=SC1090
  source "$guard_file"

  if [ "$node_status" -eq 3 ]; then
    echo "Release $tag has a partial immutable asset state." >&2
    echo "Existing immutable assets: $CONFLICTS" >&2
    echo "Missing immutable assets: $MISSING_IMMUTABLE_ASSETS" >&2
    return 3
  fi

  if [ "${SKIP_ALL:-false}" = "true" ]; then
    echo "Release $tag already has all immutable assets, skipping build and upload."
    return 0
  fi

  echo "Release $tag exists without immutable release assets, continuing."
  return 1
}
