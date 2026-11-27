#!/usr/bin/env bash
# Compile the classic NIGHTLY's app for one architecture, the way
# .github/workflows/nightly.yml's "Build nightly app (Release)" step compiles
# it: scheme cmux, Release, CMUX_SKIP_ZIG_BUILD=1 against the pinned prebuilt
# GhosttyKit, unsigned, through run-xcodebuild-with-diagnostics.sh. The pull
# request workflow .github/workflows/classic-pr-build.yml runs it as a
# fleet job, so a change that only the Release compile rejects fails at its pull
# request instead of hours later in a NIGHTLY that does not publish.
#
# Usage: scripts/ci/classic-nightly-release-compile.sh [--archs arm64|x86_64] [derived-data]
#
# Exit 0: compiled. Exit 75: the machine could not be set up (submodules,
# Xcode, GhosttyKit, Rust), which is not the change's fault; the workflow
# reports it as not judged. Any other status: the Release compile failed.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

archs=arm64
if [[ "${1:-}" == --archs ]]; then
  case "${2:-}" in
    arm64|x86_64) archs="$2" ;;
    *) echo "classic-nightly-release-compile: --archs takes arm64 or x86_64, got '${2:-}'" >&2; exit 2 ;;
  esac
  shift 2
fi
state="${CMUX_WORKLOAD_STATE_ROOT:-$root/.build}"
derived="${1:-$state/classic-nightly-release-compile-$archs}"

setup_failed() {
  echo "::warning::classic-nightly-release-compile: setup failed ($1); not judging the change" >&2
  exit 75
}

export CMUX_SKIP_ZIG_BUILD=1
export PATH="$HOME/.cargo/bin:$PATH"
export CMUX_CI_REQUIRED_MACOS_SDK_MAJOR="${CMUX_CI_REQUIRED_MACOS_SDK_MAJOR:-26}"

# The app bundles ghostty's terminfo and links vendor/bonsplit.
for path in ghostty vendor/bonsplit; do
  if ! [[ -e "$path/.git" ]]; then
    bash scripts/ci/init-submodule.sh "$path" || setup_failed "submodule $path"
  fi
done

mkdir -p "$state"
xcode_env="$(mktemp "$state/xcode-env.XXXXXX")"
GITHUB_ENV="$xcode_env" ./scripts/select-ci-xcode.sh || setup_failed "select Xcode"
while IFS= read -r assignment; do
  case "$assignment" in
    DEVELOPER_DIR=*) export "${assignment?}" ;;
  esac
done < "$xcode_env"
rm -f "$xcode_env"

./scripts/install-rust-ci.sh || setup_failed "install Rust"
./scripts/download-prebuilt-ghosttykit.sh || setup_failed "download GhosttyKit"

echo "classic-nightly-release-compile: Release $archs at $(git rev-parse HEAD) into $derived"
./scripts/ci/run-xcodebuild-with-diagnostics.sh -- \
  env CMUX_SKIP_ZIG_BUILD=1 xcodebuild -scheme cmux -configuration Release -derivedDataPath "$derived" \
  -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath "$state/classic-nightly-spm" \
  -packageCachePath "$state/classic-nightly-spm/.package-cache" \
  -showBuildTimingSummary \
  ARCHS="$archs" \
  ONLY_ACTIVE_ARCH=NO \
  COMPILATION_CACHE_ENABLE_CACHING=YES \
  COMPILATION_CACHE_LIMIT_SIZE=3221225472 \
  COMPILER_INDEX_STORE_ENABLE=NO \
  CODE_SIGNING_ALLOWED=NO ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Nightly build
test -d "$derived/Build/Products/Release/cmux.app"
