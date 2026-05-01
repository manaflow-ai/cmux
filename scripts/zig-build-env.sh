#!/usr/bin/env bash

cmux_needs_clt_zig_sdk_workaround() {
  [[ "$(uname -s)" == "Darwin" ]] || return 1
  [[ "$(uname -m)" == "arm64" ]] || return 1

  local xcode_tbd="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/libSystem.B.tbd"
  local clt_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
  local clt_tbd="${clt_sdk}/usr/lib/libSystem.B.tbd"

  [[ -f "$xcode_tbd" && -f "$clt_tbd" ]] || return 1
  head -n 8 "$xcode_tbd" | grep -q 'arm64-macos' && return 1
  head -n 8 "$clt_tbd" | grep -q 'arm64-macos'
}

cmux_apply_zig_build_env() {
  if cmux_needs_clt_zig_sdk_workaround; then
    export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
  fi
}

cmux_run_zig() {
  cmux_apply_zig_build_env
  zig "$@"
}
