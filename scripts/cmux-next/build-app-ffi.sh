#!/usr/bin/env bash
# Builds CCmuxAppFFI.xcframework: the ONE Rust library the cmux macOS app
# links (cmux-tui/crates/cmux-app-ffi = the remote desktop core C ABI + the
# sidebar layout reducer C ABI + the cmux-motion C ABI over one Rust
# runtime), as a dynamic library: libcmux_app_ffi.dylib, install name
# @rpath/libcmux_app_ffi.dylib. The app carries it at
# Contents/Frameworks/libcmux_app_ffi.dylib, which Xcode embeds from the package's dynamic xcframework,
# so a change to the FFI crates alone swaps that one file and restarts the app
# with its sessions kept (hot-apply.py's ffi part) instead of building the app.
# Apple's compact unwind encodes at most three personality routines per image;
# this library is an image of its own with Rust's one, and a new in-tree C ABI
# still joins it, never another Rust library. The headers keep their modules
# (CCmuxRdFFI, CCmuxLayoutReducerFFI, ...), so Swift imports do not change.
# Published by app-ffi-release.yml and pinned in
# Packages/macOS/CmuxNext/Package.swift.
#
# The library exports exactly the C ABIs the headers declare, as the static
# library did: cargo builds the crate's static library, and one clang
# -dynamiclib link per architecture force-loads it with that export list (every
# Rust and std symbol, rust_eh_personality included, stays local), the native
# libraries rustc names for it, and -dead_strip. dsymutil keeps the symbol
# names in the xcframework's dSYM before the library is stripped of them.
#
# Usage: build-app-ffi.sh [--list-exports]
# Environment:
#   CMUX_APP_FFI_ARCHS  macOS architectures, arm64 and/or x86_64 (default: host)
#   CMUX_APP_FFI_OUT    output directory (default: cmux-tui/target/cmux-app-ffi)
#   CMUX_APP_FFI_PERSIST_TARGET=1  keep cargo's target directory across runs, in the
#                       fleet's per-toolchain Rust target root (scripts/ci/fleet-rust-cache.sh),
#                       so a self-hosted runner recompiles only changed crates
set -euo pipefail
REPAIR_URL="https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md"
trap 'echo "error: app FFI build failed; see $REPAIR_URL" >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
crates="$repo_root/cmux-tui/crates"
crate_dir="$crates/cmux-app-ffi"
out_root="${CMUX_APP_FFI_OUT:-$repo_root/cmux-tui/target/cmux-app-ffi}"
case "$out_root" in ""|"/") echo "error: CMUX_APP_FFI_OUT must name a directory" >&2; exit 2 ;; esac
# Absolute: xcodebuild -create-xcframework takes the dSYM only by absolute path.
[[ "$out_root" == /* ]] || out_root="$PWD/$out_root"
lib_name="libcmux_app_ffi.a"
dylib_name="libcmux_app_ffi.dylib"
headers_in=("$crates/acpmux-client/include/acpmux_client.h:CAcpmuxClientFFI"
            "$crates/cmux-rd-ffi/include/cmux_rd_ffi.h:CCmuxRdFFI"
            "$crates/cmux-rd-core/include/cmux_screen_kit.h:CCmuxScreenKitFFI"
            "$crates/cmux-layout-reducer-ffi/include/cmux_layout_reducer_ffi.h:CCmuxLayoutReducerFFI"
            "$crates/cmux-palette-ranker/include/cmux_palette_ranker.h:CCmuxPaletteRankerFFI"
            "$crates/cmux-app-ffi/include/cmux_motion_ffi.h:CCmuxMotionFFI"
            "$crates/cmux-app-ffi/include/cmux_wallpaper_ffi.h:CCmuxWallpaperFFI"
            "$crates/cmux-app-ffi/include/cmux_launch_record.h:CCmuxLaunchRecordFFI"
            "$crates/cmux-app-ffi/include/cmux_sign_clone_sweep.h:CCmuxSignCloneSweepFFI"
            "$crates/cmux-app-ffi/include/cmux_files_lister.h:CCmuxFilesListerFFI"
            "$crates/cmux-app-ffi/include/cmux_system_calendar.h:CCmuxSystemCalendarFFI"
            "$crates/cmux-app-ffi/include/cmux_settings.h:CCmuxSettingsFFI"
            "$crates/cmux-app-ffi/include/cmux_home.h:CCmuxHomeFFI"
            "$crates/cmux-app-ffi/include/cmux_interactivity.h:CCmuxInteractivityFFI"
            "$crates/cmux-launch-shell/include/cmux_launch_shell.h:CCmuxLaunchShellFFI"
            "$crates/cmux-layout-cache/include/cmux_layout_cache.h:CCmuxLayoutCacheFFI"
            "$crates/cmux-app-ffi/include/cmux_background_ready.h:CCmuxBackgroundReadyFFI"
            "$crates/cmux-agent-pane-policy/include/cmux_agent_pane_policy.h:CCmuxAgentPanePolicyFFI"
            "$crates/cmux-action-catalog/include/cmux_action_catalog.h:CCmuxActionCatalogFFI"
            "$crates/cmux-cookie-sync/include/cmux_cookie_sync.h:CCmuxCookieSyncFFI"
            "$crates/cmux-daemon-conn-core/include/cmux_daemon_conn.h:CCmuxDaemonConnFFI"
            "$crates/cmux-daemon-launch-core/include/cmux_daemon_launch.h:CCmuxDaemonLaunchFFI"
            "$crates/cmux-health-core/include/cmux_health.h:CCmuxHealthFFI"
            "$crates/cmux-keymap/include/cmux_keymap.h:CCmuxKeymapFFI"
            "$crates/cmux-launch-image/include/cmux_launch_image.h:CCmuxLaunchImageFFI"
            "$crates/cmux-pane-pictures/include/cmux_pane_pictures.h:CCmuxPanePicturesFFI"
            "$crates/cmux-design-core/include/cmux_design.h:CCmuxDesignFFI"
            "$crates/cmux-chat-markdown/include/cmux_chat_markdown.h:CCmuxChatMarkdownFFI"
            "$crates/cmux-acpmux-remote-wire/include/cmux_acpmux_remote_wire.h:CCmuxAcpmuxRemoteWireFFI"
            "$crates/cmux-screenshots/include/cmux_screenshots.h:CCmuxScreenshotsFFI"
            "$crates/cmux-sdk-ffi/include/cmux_sdk_ffi.h:CCmuxSdkFFI"
            "$crates/cmux-terminal-prediction/include/cmux_terminal_prediction.h:CCmuxTerminalPredictionFFI"
            "$crates/cmux-update-prewarm-core/include/cmux_update_prewarm.h:CCmuxUpdatePrewarmFFI"
            "$crates/cmux-url-input/include/cmux_url_input.h:CCmuxURLInputFFI")

# Also available on Linux so the header/export contract needs no macOS build.
list_exports() {
  for entry in "${headers_in[@]}"; do
    grep -oE '\b(cmux_|acpmux_client_|acpmux_page_driver_)[a-z0-9_]+\(' "${entry%%:*}" | tr -d '(' | sort -u | sed 's/^/_/'
  done | sort -u
}
if [[ "${1:-}" == --list-exports ]]; then
  list_exports
  exit
fi

for tool in cargo rustup xcodebuild lipo clang dsymutil strip codesign; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

targets=()
for arch in ${CMUX_APP_FFI_ARCHS:-$(uname -m)}; do
  arch="${arch//,/ }"
  for one in $arch; do
    case "$one" in
      arm64|aarch64) targets+=(aarch64-apple-darwin) ;;
      x86_64) targets+=(x86_64-apple-darwin) ;;
      *) echo "error: unsupported architecture $one" >&2; exit 2 ;;
    esac
  done
done
installed="$(cd "$crate_dir" && rustup target list --installed)"
for target in "${targets[@]}"; do
  grep -Fxq "$target" <<<"$installed" || { echo "error: Rust target $target is not installed" >&2; exit 1; }
done

export CARGO_TARGET_DIR="$out_root/cargo"
# A self-hosted runner keeps cargo's target directory between runs. Under
# runner.temp, which is wiped after every job, each release compiled all ~250
# crates cold: 160-170 s of a 4m17s-4m33s arm64 cargo build went to dependencies,
# and 98-101 s to cmux-app-ffi itself (the staticlib and its fat LTO, which no
# compiler cache can reuse) in app FFI release runs 45777589600 and 45762822886 (2026-11-26).
# Cargo locks the directory against two builds at once, and its fingerprints
# include the toolchain, the target, the profile's LTO and RUSTFLAGS.
if [[ "${CMUX_APP_FFI_PERSIST_TARGET:-0}" == 1 ]]; then
  # shellcheck source=scripts/ci/fleet-rust-cache.sh
  source "$repo_root/scripts/ci/fleet-rust-cache.sh"
  # A directory that cannot be resolved or made keeps the job-private one: a
  # release never fails for want of a warm cache.
  if persistent="$(fleet_rust_target_dir cmux-app-ffi "" "$crate_dir")" && mkdir -p "$persistent"; then
    export CARGO_TARGET_DIR="$persistent"
    # A fresh crate makes cargo skip rustc, which then prints no native-static-libs
    # (a rerun of the same commit): rebuild the top crate every time, as a cold
    # directory did.
    touch "$crate_dir/src/lib.rs"
    echo "==> persistent cargo target directory $CARGO_TARGET_DIR" >&2
  else
    echo "warning: no persistent cargo target directory; building cold in $CARGO_TARGET_DIR" >&2
  fi
fi
export MACOSX_DEPLOYMENT_TARGET=14.0
# Machine code only: Xcode's ld and nm cannot read a newer rustc's bitcode.
# Fat LTO keeps it so: rustc itself runs the one optimization over this crate,
# std and every dependency and writes machine code, so no bitcode reaches
# Xcode (iroh-ffi, the app's other Rust library, ships the same way). Without
# it every crate kept its own copy of each generic it instantiated and nothing
# was inlined across crates. CMUX_APP_FFI_LTO=off builds the old way, for
# scripts/measure/app-ffi-size.sh only.
lto="${CMUX_APP_FFI_LTO:-fat}"
case "$lto" in fat|off) ;; *) echo "error: CMUX_APP_FFI_LTO must be fat or off" >&2; exit 2 ;; esac
export CARGO_PROFILE_RELEASE_LTO="$lto"
# rustc refuses -C embed-bitcode=no together with LTO.
if [[ "$lto" == off ]]; then
  export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C embed-bitcode=no"
fi
# The SQLite that rusqlite bundles here keeps each block's size in its own header
# instead of asking malloc_default_zone()->size(). That virtual zone follows zones[0]: the
# app's early delegating zone, then PartitionAlloc's once CEF loads, and neither owns
# SQLite's older blocks. A 0 there crashed nightly 4294166855401 at launch (#41049).
export LIBSQLITE3_FLAGS="${LIBSQLITE3_FLAGS:+$LIBSQLITE3_FLAGS }-DSQLITE_WITHOUT_ZONEMALLOC"

work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-app-ffi.XXXXXX")"
trap 'rm -rf "$work"' EXIT
exports="$work/exports.txt"
list_exports > "$exports"

headers="$out_root/headers"
rm -rf "$headers"
for entry in "${headers_in[@]}"; do
  header="${entry%%:*}"; module="${entry##*:}"
  # One folder per module: SwiftPM merges every binary target's Headers into
  # one include directory, and GhosttyKit owns the top-level module.modulemap.
  mkdir -p "$headers/$module"
  cp "$header" "$headers/$module/"
  printf 'module %s {\n    header "%s"\n    export *\n}\n' "$module" "$(basename "$header")" > "$headers/$module/module.modulemap"
done

rm -rf "$out_root/slices"
mkdir -p "$out_root/slices" "$out_root/macos"
dylibs=() libs=()
for target in "${targets[@]}"; do
  echo "==> cargo build cmux-app-ffi ($target)" >&2
  # --print native-static-libs: the system libraries and frameworks the static
  # library needs, which the dylib's own link names (the app's link did before).
  # Cargo replays the note from its cache when nothing rebuilds.
  (cd "$crate_dir" && cargo rustc --lib --locked --release --target "$target" -- --print native-static-libs) 2>&1 \
    | tee "$work/$target.cargo.log" >&2
  native="$(sed -n 's/^note: native-static-libs: //p' "$work/$target.cargo.log" | tail -n 1)"
  [[ -n "$native" ]] || { echo "error: cargo printed no native-static-libs for $target" >&2; exit 1; }
  # clang links libSystem itself (-lSystem, -lc and -lm are in it).
  native_libs=()
  for one in $native; do case "$one" in -lSystem|-lc|-lm) ;; *) native_libs+=("$one") ;; esac; done
  arch="${target%%-*}"; [[ "$arch" == aarch64 ]] && arch=arm64
  # One prelinked object whose only globals are the C ABIs: every Rust and std
  # symbol, rust_eh_personality included, becomes local (one copy per image).
  # It is also kept as a static archive (macos/libcmux_app_ffi.a, not in the
  # xcframework) for the Linux cross-compile parity check, which builds the same
  # object (scripts/ci/macos-cross.sh ffi).
  clang -target "$arch-apple-macos$MACOSX_DEPLOYMENT_TARGET" -r -nostdlib \
    -Wl,-force_load,"$CARGO_TARGET_DIR/$target/release/$lib_name" \
    -Wl,-exported_symbols_list,"$exports" -o "$work/$target.o"
  libtool -static -o "$out_root/slices/$target.a" "$work/$target.o"
  libs+=("$out_root/slices/$target.a")
  # The library: that object, the native libraries it needs, and -dead_strip.
  clang -target "$arch-apple-macos$MACOSX_DEPLOYMENT_TARGET" -dynamiclib -dead_strip \
    -install_name "@rpath/$dylib_name" -compatibility_version 1 -current_version 1 \
    -Wl,-exported_symbols_list,"$exports" -Wl,-headerpad_max_install_names \
    "$work/$target.o" "${native_libs[@]}" -o "$out_root/slices/$target.dylib"
  dylibs+=("$out_root/slices/$target.dylib")
done
lib="$out_root/macos/$dylib_name"
if ((${#dylibs[@]} == 1)); then
  cp -f "${dylibs[0]}" "$lib"
  cp -f "${libs[0]}" "$out_root/macos/$lib_name"
else
  lipo -create "${dylibs[@]}" -output "$lib"
  lipo -create "${libs[@]}" -output "$out_root/macos/$lib_name"
fi
# The symbol names go into the dSYM (a crash report's Rust frames symbolicate
# from it), then out of the library, as strip-release-bundle.sh strips the app's
# own code. The strip drops the linker's ad hoc signature, and an arm64 Mach-O
# without one does not load, so it is signed ad hoc again; the release signer
# (scripts/sign-cmux-bundle.sh) signs it with the app's identity.
dsym="$out_root/macos/$dylib_name.dSYM"
rm -rf "$dsym"
dsymutil "$lib" -o "$dsym"
strip -x "$lib"
codesign --force --sign - --timestamp=none "$lib"
rm -rf "$out_root/CCmuxAppFFI.xcframework"
xcodebuild -create-xcframework -library "$lib" -headers "$headers" -debug-symbols "$dsym" \
  -output "$out_root/CCmuxAppFFI.xcframework" >/dev/null
printf 'built %s\n' "$out_root/CCmuxAppFFI.xcframework"
