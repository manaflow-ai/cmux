#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$root/scripts/lib/mobile-attach.sh"
state="${CMUX_WORKLOAD_STATE_ROOT:?CMUX_WORKLOAD_STATE_ROOT is required}"
attempt_id="${CMUX_WORKLOAD_ATTEMPT_ID:?CMUX_WORKLOAD_ATTEMPT_ID is required}"
derived="$state/derived-data"
source_packages="$state/source-packages"
xcode_env="$state/xcode.env"
tag="profile-$attempt_id"
cmux_attach_validate_dev_tag "$tag"
tag_slug="$(cmux_attach__slug "$tag")"
expected_bundle_id="$(cmux_attach_mac_bundle_id "$tag")"

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
CMUX_DEV_BACKEND_MODE=local \
CMUX_DEV_CLOUD_ENABLED=0 \
CMUX_LOCAL_CACHE_PREFLIGHT=0 \
CMUX_GHOSTTYKIT_PREPROVISIONED=1 \
CMUX_SOURCE_PACKAGES_DIR="$source_packages" \
CMUX_RELOAD_NO_GLOBAL_CLI_LINKS=1 \
  ./scripts/reload.sh \
    --tag "$tag" \
    --derived-data "$derived" \
    --no-global-cli-links
stage end compile

stage start validation
app="$derived/Build/Products/Debug/cmux DEV $tag_slug.app"
test -x "$app/Contents/MacOS/cmux DEV"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
test "$bundle_id" = "$expected_bundle_id"
stage end validation
