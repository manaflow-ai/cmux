#!/usr/bin/env bash
# Prints the input key of the unsigned "cmux Computer Use.app" that
# `scripts/build-cmux-cua.sh --helper-app` assembles: one sha256 over every
# input that changes its bytes. Two builds with the same key build the same
# helper, so the nightly reuses a prebuilt one (scripts/cmux-next/cmux-cua-helper.pin.json,
# scripts/ci/nightly-steps/app-assemble-computer-use-helper.sh) instead of
# cloning cmux-cua and compiling it again.
#
#   cmux-cua-helper-key.sh --archs "arm64" [--fields]
#
# --fields prints the key's fields (one NAME=VALUE per line) before the key.
# Inputs: build-cmux-cua.sh itself (the cmux-cua pin, the patch list, the cargo
# features and the assembly), each patch's bytes, the patch and rpath tools,
# the helper icon, the Rust toolchain cmux-tui pins, the archs, the display
# name, and the selected Xcode and macOS SDK versions. Bump RECIPE to start every
# prebuilt over.
set -euo pipefail
RECIPE="cmux-cua-helper-prebuilt-v1"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archs="" fields=0
while (($#)); do
  case "$1" in
    --archs) archs="${2:?}"; shift 2 ;;
    --fields) fields=1; shift ;;
    *) echo "usage: cmux-cua-helper-key.sh --archs \"arm64 [x86_64]\" [--fields]" >&2; exit 2 ;;
  esac
done
[[ -n "$archs" ]] || { echo "error: --archs is required" >&2; exit 2; }
read -r -a arch_list <<<"$archs"
for arch in "${arch_list[@]}"; do
  case "$arch" in arm64|x86_64) ;; *) echo "error: unsupported arch $arch" >&2; exit 2 ;; esac
done
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
build="$root/scripts/build-cmux-cua.sh"
pin="$(sed -n 's/^CMUX_CUA_PINNED_SHA="\([0-9a-f]\{40\}\)"$/\1/p' "$build")"
[[ -n "$pin" ]] || { echo "error: no CMUX_CUA_PINNED_SHA in $build" >&2; exit 1; }
patches=()
while IFS= read -r p; do [[ -n "$p" ]] && patches+=("$p"); done < <(
  sed -n '/^CMUX_CUA_PATCH_RELATIVE_PATHS=(/,/^)/p' "$build" | sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p')
toolchain="$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$root/cmux-tui/rust-toolchain.toml")"
[[ -n "$toolchain" ]] || { echo "error: no channel in cmux-tui/rust-toolchain.toml" >&2; exit 1; }
icon="$root/Resources/ComputerUseHelperIcon.icns"
# The publisher checks a nightly's recorded key on a host with another Xcode: it passes the
# recorded versions (CMUX_CUA_KEY_XCODE, CMUX_CUA_KEY_SDK) and every other field is this checkout's.
xcode="${CMUX_CUA_KEY_XCODE:-$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true)}"
sdk="${CMUX_CUA_KEY_SDK:-$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true) $(xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || true)}"
[[ -n "$xcode" && "$sdk" != " " ]] || { echo "error: cannot read the selected Xcode and macOS SDK" >&2; exit 1; }

lines=(
  "recipe=$RECIPE"
  "cmux_cua_pinned_sha=$pin"
  "build_script=$(sha_of "$build")"
  "apply_patch=$(sha_of "$root/scripts/apply-cmux-cua-patch.sh")"
  "strip_rpaths=$(sha_of "$root/scripts/strip-cmux-cua-rpaths.sh")"
  "icon=$([[ -f "$icon" ]] && sha_of "$icon" || echo none)"
  "rust_toolchain=$toolchain"
  "archs=${arch_list[*]}"
  "display_name=${CMUX_CUA_HELPER_DISPLAY_NAME:-cmux Computer Use}"
  "xcode=$xcode"
  "macos_sdk=$sdk"
)
for p in ${patches[@]+"${patches[@]}"}; do
  lines+=("patch:$p=$(sha_of "$root/$p")")
done
if ((fields)); then printf '%s\n' "${lines[@]}"; fi
printf '%s\n' "${lines[@]}" | shasum -a 256 | awk '{print $1}'
