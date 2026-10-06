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
# A step's HOME is disposable; use the worker's provisioned rustup toolchains
# (as the build recipe does), with Cargo's registry in the step.
provisioned_home="$(eval echo "~$(id -un)")"
if [[ -x "$provisioned_home/.cargo/bin/rustup" ]]; then
  export RUSTUP_HOME="$provisioned_home/.rustup" CARGO_HOME="$work/cargo"
  mkdir -p "$CARGO_HOME"
  PATH="$provisioned_home/.cargo/bin:$PATH"
else
  ./scripts/install-rust-ci.sh
  [[ -s "$GITHUB_PATH" ]] && PATH="$(paste -sd: "$GITHUB_PATH"):$PATH"
fi
export PATH
CMUX_NEXT_ACPMUX_ARCHS=arm64 scripts/cmux-next/build-acpmux.sh --output "$work/acpmux/acpmux"
# Same environment for both configurations: no CEF or Zig rebuild, and the
# pinned cmux-tui (tree mode needs a GitHub token this step does not have).
export CMUX_NEXT_ACPMUX_BIN="$work/acpmux/acpmux" CMUX_NEXT_TUI_MODE=pin \
  CMUX_NEXT_SKIP_CEF=1 CMUX_SKIP_ZIG_BUILD=1
# The step checkout is not a git repository; pick the app's largest source file.
touched="$(find Sources -name '*.swift' -type f -exec wc -l {} + | grep -v ' total$' | sort -n | tail -n 1 | awk '{print $2}')"
[[ -f "$touched" ]] || { echo "no app source file to touch" >&2; exit 1; }
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
  echo "MEASURE $configuration cold=${cold}s"
  touch "$touched"
  incremental="$(build "$configuration")"
  app="$(find "$work/dd-$configuration/Build/Products/$configuration" -maxdepth 1 -name '*.app' | head -n 1)"
  size="$(du -sm "$app" | cut -f1)"
  results+=("$configuration cold=${cold}s incremental=${incremental}s app=${size}MB")
  echo "MEASURE $configuration cold=${cold}s incremental(touch $touched)=${incremental}s app=${size}MB"
done
echo "MEASURE cpus=$(sysctl -n hw.ncpu) xcode=$(xcodebuild -version | head -n 1)"
printf 'MEASURE %s\n' "${results[@]}"
