#!/usr/bin/env bash
# Boot an iOS-simulator-shaped target on a Linux host and run cmux iOS package tests in it.
#
# This is not an iOS Simulator: there is no UIKit, SwiftUI or CoreSimulator on Linux. It gives the
# platform-independent half of Packages/iOS (models, protocols, stores, billing, pairing) a place to
# run on a Linux lane VM, shaped like a simulator device so the same code paths see the same inputs:
#
#   - a device record (name, model identifier, runtime version, UDID) like `xcrun simctl create`
#   - a per-device data container (Documents, Library/Caches, Library/Preferences, tmp) that HOME and
#     TMPDIR point into, so a test that writes files sees a fresh container per boot
#   - the SIMULATOR_* environment Xcode sets in a simulator process (cmux reads SIMULATOR_DEVICE_NAME,
#     SIMULATOR_MODEL_IDENTIFIER and SIMULATOR_SHARED_RESOURCES_DIRECTORY)
#   - shim modules for Apple frameworks whose used surface is small (scripts/ios-linux-harness/shims:
#     CoreGraphics geometry), built once per toolchain and put on every build's search path
#
# Usage:
#   scripts/ios-linux-harness.sh boot [--device NAME] [--model ID] [--runtime VERSION]
#   scripts/ios-linux-harness.sh test PACKAGE [--filter F]   PACKAGE: Packages/iOS/X or just X
#   scripts/ios-linux-harness.sh survey                      every Packages/iOS package, one row each
#   scripts/ios-linux-harness.sh status | shutdown | erase
#   CMUX_IOS_LINUX_NO_SHIMS=1 ...   the same run without the shims (the "before" side)
#
# Each test or survey row ends with one `ios-linux-harness:` JSON line (package, build, test, seconds,
# device UDID) for a caller to read. See docs/ios-linux-harness.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${CMUX_IOS_LINUX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/cmux-ios-linux}"
BOOTED="$STATE/booted"
BUILD_TIMEOUT="${CMUX_IOS_LINUX_BUILD_TIMEOUT:-900}"
TEST_TIMEOUT="${CMUX_IOS_LINUX_TEST_TIMEOUT:-600}"

die() { echo "ios-linux-harness: $*" >&2; exit 2; }

find_toolchain() {
  if command -v swift >/dev/null 2>&1; then
    command -v swift
    return
  fi
  local candidate
  for candidate in /opt/swift/usr/bin/swift /opt/swift-*/usr/bin/swift /usr/share/swift/usr/bin/swift; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return
    fi
  done
  die "no toolchain: put \`swift\` on PATH (a lane VM has /opt/swift), or run inside public.ecr.aws/docker/library/swift:6.2-noble"
}

device_field() { sed -n "s/^$1=//p" "$BOOTED/device.env" 2>/dev/null | head -1; }

cmd_boot() {
  local name="iPhone 16 (Linux harness)" model="iPhone17,3" runtime="17.0"
  while [ $# -gt 0 ]; do
    case "$1" in
      --device) name="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --runtime) runtime="$2"; shift 2 ;;
      *) die "boot: unknown argument $1" ;;
    esac
  done
  [ "$(uname -s)" = Linux ] || die "boot: this harness is for Linux hosts; on a Mac use xcrun simctl"
  local swift
  swift="$(find_toolchain)"
  if [ -f "$BOOTED/device.env" ]; then
    echo "ios-linux-harness: already booted: $(device_field SIMULATOR_DEVICE_NAME) $(device_field SIMULATOR_UDID)"
    return
  fi
  local udid
  udid="$(tr '[:lower:]' '[:upper:]' < /proc/sys/kernel/random/uuid)"
  local device="$STATE/devices/$udid"
  mkdir -p "$device/data/Documents" "$device/data/Library/Caches" "$device/data/Library/Preferences" \
    "$device/data/tmp" "$device/shared"
  {
    echo "SIMULATOR_DEVICE_NAME=$name"
    echo "SIMULATOR_MODEL_IDENTIFIER=$model"
    echo "SIMULATOR_RUNTIME_VERSION=$runtime"
    echo "SIMULATOR_UDID=$udid"
    echo "SIMULATOR_SHARED_RESOURCES_DIRECTORY=$device/shared"
    echo "SIMULATOR_HOST_HOME=$HOME"
    echo "HOME=$device/data"
    echo "TMPDIR=$device/data/tmp"
    echo "CMUX_IOS_LINUX_HARNESS=1"
    echo "CMUX_SWIFTPM_TARGET_LINUX=1"
    echo "SWIFT=$swift"
  } > "$device/device.env"
  ln -sfn "$device" "$BOOTED"
  build_shims "$swift"
  echo "ios-linux-harness: booted $name ($model, iOS $runtime runtime shape) $udid"
  echo "ios-linux-harness: toolchain $("$swift" --version 2>/dev/null | head -1)"
}

# Compile each shim in scripts/ios-linux-harness/shims into one search directory: a .swiftmodule for
# the compiler and, for a module with code, a static library the linker finds through -module-link-name.
build_shims() {
  local swift="$1" swiftc shim_src="$ROOT/scripts/ios-linux-harness/shims" key dir
  swiftc="$(dirname "$swift")/swiftc"
  key="$({ "$swift" --version 2>/dev/null | head -1; cat "$shim_src"/*.swift; } | sha256sum | cut -c1-16)"
  dir="$STATE/shims/$key"
  if [ ! -f "$dir/.complete" ]; then
    mkdir -p "$dir"
    # CoreGraphics first: the swift-testing overlay imports it.
    "$swiftc" -parse-as-library -module-name CoreGraphics -module-link-name CoreGraphics \
      -emit-module -emit-module-path "$dir/CoreGraphics.swiftmodule" \
      -emit-object -o "$dir/CoreGraphics.o" "$shim_src/CoreGraphics.swift"
    ar rcs "$dir/libCoreGraphics.a" "$dir/CoreGraphics.o"
    "$swiftc" -parse-as-library -module-name _Testing_CoreGraphics -I "$dir" \
      -emit-module -emit-module-path "$dir/_Testing_CoreGraphics.swiftmodule" "$shim_src/_Testing_CoreGraphics.swift"
    : > "$dir/.complete"
  fi
  echo "CMUX_IOS_LINUX_SHIMS=$dir" >> "$BOOTED/device.env"
  echo "ios-linux-harness: shims CoreGraphics (geometry) in $dir"
}

ensure_booted() { [ -f "$BOOTED/device.env" ] || cmd_boot; }

# Run a command inside the booted device: its env, its HOME and TMPDIR. The build cache stays in the
# package's own .build (its host-side home), so a fresh device does not mean a cold compile.
in_device() {
  local -a env_args=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && env_args+=("$line")
  done < "$BOOTED/device.env"
  env "${env_args[@]}" SWIFTPM_CACHE_HOME="${SWIFTPM_CACHE_HOME:-$HOME/.cache/org.swift.swiftpm}" "$@"
}

resolve_package() {
  local package="$1"
  case "$package" in
    */*) ;;
    *) package="Packages/iOS/$package" ;;
  esac
  [ -f "$ROOT/$package/Package.swift" ] || die "no package at $package"
  echo "$package"
}

run_package() {
  local package="$1" filter="${2:-}" log_dir="$3"
  local name swift start build=pass test=skip
  name="$(basename "$package")"
  swift="$(device_field SWIFT)"
  # SwiftPM keeps its cache and config under HOME; the device's HOME is fresh, so point those at the
  # host's so a boot does not re-fetch every dependency.
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}"
  local shims
  shims="$(device_field CMUX_IOS_LINUX_SHIMS)"
  local -a shim_flags=()
  if [ "${CMUX_IOS_LINUX_NO_SHIMS:-0}" != 1 ] && [ -n "$shims" ]; then
    shim_flags=(-Xswiftc -I"$shims" -Xlinker -L"$shims")
  fi
  start="$(date +%s)"
  if ! in_device XDG_CACHE_HOME="$cache" timeout --kill-after=30 "$BUILD_TIMEOUT" \
      "$swift" build --package-path "$ROOT/$package" --build-tests "${shim_flags[@]}" >"$log_dir/$name.build.log" 2>&1; then
    build=fail
  else
    local -a args=(test --package-path "$ROOT/$package" --skip-build "${shim_flags[@]}")
    [ -z "$filter" ] || args+=(--filter "$filter")
    if in_device XDG_CACHE_HOME="$cache" timeout --kill-after=30 "$TEST_TIMEOUT" \
        "$swift" "${args[@]}" >"$log_dir/$name.test.log" 2>&1; then
      test=pass
    else
      test=fail
    fi
  fi
  local secs=$(( $(date +%s) - start ))
  local counts=""
  if [ -f "$log_dir/$name.test.log" ]; then
    # swift-testing ("Test run with N tests ... passed") and XCTest ("Executed N tests") summaries.
    counts="$(grep -hoE 'Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)|Executed [0-9]+ tests?, with [0-9]+ failures?' \
      "$log_dir/$name.test.log" | grep -v '^Executed 0 tests' | tr '\n' ';' | sed 's/;$//')"
  fi
  local first_error=""
  if [ "$build" = fail ]; then
    # The first compiler error, not the "emit-module command failed" line SwiftPM prints first.
    first_error="$(grep -oE 'error: .*' "$log_dir/$name.build.log" | grep -v -m1 'command failed with exit code' |
      cut -c1-160 | tr -d '"[:cntrl:]' | sed 's/[\\]//g')"
  fi
  # `shims` sits beside the result so a before/after (CMUX_IOS_LINUX_NO_SHIMS=1) reads from one harness.
  local shims_used=on
  [ "${#shim_flags[@]}" -gt 0 ] || shims_used=off
  printf 'ios-linux-harness: {"package":"%s","build":"%s","test":"%s","seconds":%s,"shims":"%s","device":"%s","counts":"%s","first_error":"%s"}\n' \
    "$package" "$build" "$test" "$secs" "$shims_used" "$(device_field SIMULATOR_UDID)" "$counts" "$first_error"
  [ "$build" = pass ] && [ "$test" = pass ]
}

cmd_test() {
  [ $# -ge 1 ] || die "test: name a package (Packages/iOS/X or X)"
  local package filter=""
  package="$(resolve_package "$1")"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --filter) filter="$2"; shift 2 ;;
      *) die "test: unknown argument $1" ;;
    esac
  done
  ensure_booted
  local log_dir="$BOOTED/logs"
  mkdir -p "$log_dir"
  run_package "$package" "$filter" "$log_dir" || {
    echo "ios-linux-harness: logs in $log_dir" >&2
    return 1
  }
}

cmd_survey() {
  ensure_booted
  local log_dir="$BOOTED/logs" pass=0 total=0 package
  mkdir -p "$log_dir"
  for package in "$ROOT"/Packages/iOS/*/Package.swift; do
    package="${package#"$ROOT"/}"
    package="$(dirname "$package")"
    total=$((total + 1))
    if run_package "$package" "" "$log_dir"; then pass=$((pass + 1)); fi
  done
  echo "ios-linux-harness: survey: $pass of $total Packages/iOS packages build and pass their tests here (logs: $log_dir)"
}

cmd_status() {
  if [ -f "$BOOTED/device.env" ]; then
    echo "Booted: $(device_field SIMULATOR_DEVICE_NAME) ($(device_field SIMULATOR_MODEL_IDENTIFIER)) $(device_field SIMULATOR_UDID)"
    echo "Data: $(device_field HOME)"
  else
    echo "Shutdown"
  fi
}

cmd_shutdown() {
  [ -L "$BOOTED" ] && rm "$BOOTED"
  echo "ios-linux-harness: shutdown (device data kept under $STATE/devices; \`erase\` removes it)"
}

cmd_erase() {
  [ -L "$BOOTED" ] && rm "$BOOTED"
  # Only this harness's own state directory, which boot created.
  [ -d "$STATE/devices" ] && rm -r "$STATE/devices"
  echo "ios-linux-harness: erased $STATE/devices"
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    boot) cmd_boot "$@" ;;
    test) cmd_test "$@" ;;
    survey) cmd_survey "$@" ;;
    status) cmd_status ;;
    shutdown) cmd_shutdown ;;
    erase) cmd_erase ;;
    *) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; [ -n "$cmd" ] && exit 2; exit 0 ;;
  esac
}

main "$@"
