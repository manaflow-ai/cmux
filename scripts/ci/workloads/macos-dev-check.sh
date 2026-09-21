#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
state="${CMUX_WORKLOAD_STATE_ROOT:?CMUX_WORKLOAD_STATE_ROOT is required}"
derived="$state/derived-data"
source_packages="$state/source-packages"
xcode_env="$state/xcode.env"

stage() {
  python3 "$root/scripts/ci/cmux_workload_profile.py" stage "$1" "$2"
}

cd "$root"
mkdir -p "$state" "$derived" "$source_packages"
export PATH="$HOME/.cargo/bin:$PATH"

stage start setup
: > "$xcode_env"
GITHUB_ENV="$xcode_env" CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=26 \
  ./scripts/select-ci-xcode.sh
while IFS= read -r assignment; do
  case "$assignment" in
    DEVELOPER_DIR=*) export "$assignment" ;;
  esac
done < "$xcode_env"
./scripts/install-rust-ci.sh
./scripts/download-prebuilt-ghosttykit.sh
stage end setup

stage start compile
xcodebuild \
  -project cmux.xcodeproj \
  -scheme cmux \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$derived" \
  -clonedSourcePackagesDirPath "$source_packages" \
  CODE_SIGNING_ALLOWED=NO \
  CMUX_SKIP_ZIG_BUILD=1 \
  clean build
stage end compile

stage start validation
app="$derived/Build/Products/Debug/cmux DEV.app"
test -x "$app/Contents/MacOS/cmux DEV"
stage end validation
