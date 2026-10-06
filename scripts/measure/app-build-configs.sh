#!/usr/bin/env bash
# Build cost of the cmux app scheme in Debug and Release on one idle worker:
# a cold build of each into its own DerivedData, then a rebuild after touching
# one app source file. Run alone on a worker:
#   cmux-ci run --class exclusive --script scripts/measure/app-build-configs.sh --ref SHA
set -euo pipefail
work="$(mktemp -d)"
export GITHUB_ENV="$work/github-env" GITHUB_PATH="$work/github-path"
./scripts/select-ci-xcode.sh
DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$GITHUB_ENV" | tail -n 1)"
export DEVELOPER_DIR
./scripts/install-rust-ci.sh
[[ -s "$GITHUB_PATH" ]] && PATH="$(paste -sd: "$GITHUB_PATH"):$PATH"
export PATH
CMUX_NEXT_ACPMUX_ARCHS=arm64 scripts/cmux-next/build-acpmux.sh --output "$work/acpmux/acpmux"
# Same environment for both configurations: no CEF or Zig rebuild, and the
# pinned cmux-tui (tree mode needs a GitHub token this step does not have).
export CMUX_NEXT_ACPMUX_BIN="$work/acpmux/acpmux" CMUX_NEXT_TUI_MODE=pin \
  CMUX_NEXT_SKIP_CEF=1 CMUX_SKIP_ZIG_BUILD=1
touched="Sources/AppDelegate.swift"
[[ -f "$touched" ]] || touched="$(git ls-files 'Sources/*.swift' | head -n 1)"
build() {
  local configuration="$1" started status=0
  started="$(date +%s)"
  xcodebuild -project cmux.xcodeproj -scheme cmux -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$work/dd-$configuration" \
    ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO \
    build > "$work/$configuration.log" 2>&1 || status=$?
  echo "$(( $(date +%s) - started ))"
  if (( status )); then
    grep -E "error:|BUILD FAILED" "$work/$configuration.log" | head -n 20 >&2
    return "$status"
  fi
}
results=()
for configuration in Debug Release; do
  cold="$(build "$configuration")"
  touch "$touched"
  incremental="$(build "$configuration")"
  app="$(find "$work/dd-$configuration/Build/Products/$configuration" -maxdepth 1 -name '*.app' | head -n 1)"
  size="$(du -sm "$app" | cut -f1)"
  results+=("$configuration cold=${cold}s incremental=${incremental}s app=${size}MB")
  echo "MEASURE $configuration cold=${cold}s incremental(touch $touched)=${incremental}s app=${size}MB"
done
echo "MEASURE host=$(hostname -s | sed 's/./x/g') cpus=$(sysctl -n hw.ncpu) xcode=$(xcodebuild -version | head -n 1)"
printf 'MEASURE %s\n' "${results[@]}"
