#!/usr/bin/env bash
# Build the Screen Sharing helper's WebRTC host (plans/cmux-next/screen-sharing-helper.md): the
# Swift executable cmux-screen-sharing-webrtc (Packages/Shared/CmuxVNCWebRTC) and libwebrtc as a
# plain libWebRTC.dylib beside it. bundle-screen-sharing-helper.sh puts them in
# "<app> Screen Sharing.app" (Contents/MacOS and Contents/Frameworks); the helper's hidden mode
# `__webrtc-host` runs the executable as its child, so an iPhone (WebRTC) viewer's capture and
# input use the helper's Screen Recording and Accessibility grants, never the app's.
#
# Same contract as build-screen-sharing-helper.sh: CI, fleet and nx-remote builds run SwiftPM on a
# miss; a developer Mac only reuses the cache. The cache is keyed by the Swift packages' sources
# and this script, so an app-only commit reuses the last build.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  sed -n '2,11p' "$0" | sed 's/^# //'
  cat <<'USAGE'

Usage: build-screen-sharing-webrtc.sh [--output DIR] [--cached-only] [--print-path]
  --output DIR   also copy cmux-screen-sharing-webrtc and libWebRTC.dylib into DIR
  --print-path   print the cache directory that holds both
Environment:
  CMUX_NEXT_SCREEN_HELPER_ARCHS  space/comma-separated arm64 and/or x86_64 (default: ARCHS, else host)
  CMUX_NEXT_SCREEN_WEBRTC_CACHE  cache root (default: Packages/Shared/CmuxVNCWebRTC/.build/screen-sharing-webrtc)
USAGE
}

build_allowed() { [[ -n "${CI:-}${GITHUB_ACTIONS:-}${CMUX_FLEET_BUILD_TAG:-}${NX_JOB_ID:-}" ]]; }
cached_only=0
print_path=0
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="${2:?missing directory after --output}"; shift 2 ;;
    --cached-only) cached_only=1; shift ;;
    --print-path) print_path=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

package="$repo_root/Packages/Shared/CmuxVNCWebRTC"
EXECUTABLE=cmux-screen-sharing-webrtc
DYLIB=libWebRTC.dylib
[[ -f "$package/Package.swift" ]] || { echo "error: Packages/Shared/CmuxVNCWebRTC is missing" >&2; exit 1; }

# The source key: the committed trees of every input plus any uncommitted change, as
# build-screen-sharing-helper.sh keys the helper.
inputs=(Packages/Shared/CmuxVNCWebRTC/Package.swift Packages/Shared/CmuxVNCWebRTC/Sources
  Packages/Shared/CmuxVNC/Package.swift Packages/Shared/CmuxVNC/Sources
  scripts/cmux-next/build-screen-sharing-webrtc.sh scripts/cmux-next/strip-toolchain-rpaths.sh)
key_material=""
for input in "${inputs[@]}"; do
  key_material+="$(git -C "$repo_root" rev-parse "HEAD:$input" 2>/dev/null || echo "missing:$input")"$'\n'
done
key_material+="$(git -C "$repo_root" diff HEAD -- "${inputs[@]}" 2>/dev/null || true)"
while IFS= read -r untracked; do
  [[ -n "$untracked" ]] || continue
  key_material+="$untracked $(git -C "$repo_root" hash-object -- "$untracked" 2>/dev/null || echo unreadable)"$'\n'
done < <(git -C "$repo_root" ls-files --others --exclude-standard -- "${inputs[@]}" 2>/dev/null || true)
source_key="$(printf '%s' "$key_material" | shasum -a 256 | cut -c1-16)"

normalize_archs() {
  local raw="${CMUX_NEXT_SCREEN_HELPER_ARCHS:-${ARCHS:-}}"
  [[ -n "$raw" ]] || raw="$(uname -m)"
  raw="${raw//,/ }"
  local arch normalized=() seen=" "
  for arch in $raw; do
    case "$arch" in
      arm64|aarch64|aarch64-apple-darwin) arch=arm64 ;;
      x86_64|x86_64-apple-darwin|amd64) arch=x86_64 ;;
      *) echo "error: unsupported Screen Sharing helper architecture '$arch'" >&2; exit 2 ;;
    esac
    if [[ "$seen" != *" $arch "* ]]; then normalized+=("$arch"); seen+="$arch "; fi
  done
  printf '%s\n' "${normalized[*]}"
}

archs="$(normalize_archs)"
arch_key="${archs// /-}"
cache_root="${CMUX_NEXT_SCREEN_WEBRTC_CACHE:-$package/.build/screen-sharing-webrtc}"
cache_dir="$cache_root/$source_key/$arch_key"

copy_output() {
  [[ -n "$output" && "$output" != "$cache_dir" ]] || return 0
  mkdir -p "$output"
  cp -f "$cache_dir/$EXECUTABLE" "$output/$EXECUTABLE"
  cp -f "$cache_dir/$DYLIB" "$output/$DYLIB"
  chmod 755 "$output/$EXECUTABLE" "$output/$DYLIB"
}

if [[ -x "$cache_dir/$EXECUTABLE" && -f "$cache_dir/$DYLIB" ]]; then
  if [[ "$print_path" -eq 1 ]]; then printf '%s\n' "$cache_dir"; else echo "Screen Sharing WebRTC host $source_key $arch_key already cached at $cache_dir"; fi
  copy_output
  exit 0
fi
if [[ "$cached_only" -eq 1 ]]; then
  [[ "$print_path" -eq 1 ]] || echo "error: no cached Screen Sharing WebRTC host for $source_key $arch_key at $cache_dir" >&2
  exit 1
fi
build_allowed || { echo "error: the Screen Sharing WebRTC host is not cached; build it on CI, the fleet or nx-remote" >&2; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "error: swift is required to build the Screen Sharing WebRTC host" >&2; exit 1; }

# Its own scratch path: never the developer's .build, and never the one a concurrent xcodebuild uses.
scratch="${CMUX_NEXT_SCREEN_WEBRTC_SCRATCH:-$package/.build/screen-sharing-webrtc-build}"
arch_args=()
for arch in $archs; do arch_args+=(--arch "$arch"); done
echo "==> building the Screen Sharing WebRTC host ($source_key, $archs)"
(cd "$package" && swift build -c release --scratch-path "$scratch" "${arch_args[@]}" --product "$EXECUTABLE")
bin_dir="$(cd "$package" && swift build -c release --scratch-path "$scratch" "${arch_args[@]}" --show-bin-path)"
[[ -x "$bin_dir/$EXECUTABLE" ]] || { echo "error: swift build did not produce $bin_dir/$EXECUTABLE" >&2; exit 1; }
framework="$(find "$bin_dir" -maxdepth 2 -name WebRTC.framework -type d | head -1)"
[[ -n "$framework" ]] || { echo "error: WebRTC.framework is not in $bin_dir" >&2; exit 1; }
webrtc_binary="$(cd "$framework" && pwd -P)/$(readlink "$framework/WebRTC" 2>/dev/null || echo WebRTC)"
[[ -f "$webrtc_binary" ]] || { echo "error: no WebRTC binary in $framework" >&2; exit 1; }

staged="$cache_dir.tmp.$$"
rm -rf "$staged"
mkdir -p "$staged"
trap 'rm -rf "$staged"' EXIT
cp "$bin_dir/$EXECUTABLE" "$staged/$EXECUTABLE"
# libwebrtc as a plain dylib, thinned to this build's slices: a nested .framework in the helper
# would need a seal of its own, and the nightly refuses a fat Mach-O in a thinned app.
if [[ "$archs" == *" "* ]]; then
  cp "$webrtc_binary" "$staged/$DYLIB"
else
  lipo "$webrtc_binary" -thin "$archs" -output "$staged/$DYLIB" 2>/dev/null || cp "$webrtc_binary" "$staged/$DYLIB"
fi
chmod 755 "$staged/$EXECUTABLE" "$staged/$DYLIB"
old_id="$(otool -D "$staged/$DYLIB" | sed -n '2p')"
[[ -n "$old_id" ]] || { echo "error: $DYLIB has no install name" >&2; exit 1; }
install_name_tool -id "@rpath/$DYLIB" "$staged/$DYLIB"
install_name_tool -change "$old_id" "@rpath/$DYLIB" "$staged/$EXECUTABLE"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$staged/$EXECUTABLE" 2>/dev/null || true
otool -L "$staged/$EXECUTABLE" | grep -q "@rpath/$DYLIB" || { echo "error: $EXECUTABLE does not load @rpath/$DYLIB" >&2; exit 1; }
# A Swift back-deployment library through @rpath would need the toolchain's directory, which the
# app never ships; the app's macOS floor has every Swift runtime library in the system.
if otool -L "$staged/$EXECUTABLE" | awk '{print $1}' | grep -E '^@rpath/libswift'; then
  echo "error: $EXECUTABLE loads a Swift back-deployment library through @rpath" >&2; exit 1
fi
"$repo_root/scripts/cmux-next/strip-toolchain-rpaths.sh" "$staged/$EXECUTABLE" "$staged/$DYLIB"
for binary in "$staged/$EXECUTABLE" "$staged/$DYLIB"; do
  actual="$(lipo -archs "$binary")"
  for expected in $archs; do
    [[ " $actual " == *" $expected "* ]] || { echo "error: $(basename "$binary") has '$actual', this build needs '$archs'" >&2; exit 1; }
  done
done
mkdir -p "$cache_root/$source_key"
rm -rf "$cache_dir"
mv "$staged" "$cache_dir"
trap - EXIT
printf '%s\n' "key=$source_key" "commit=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)" "archs=$archs" \
  "sha256=$(shasum -a 256 "$cache_dir/$EXECUTABLE" | awk '{print $1}')" > "$cache_dir/ref"
copy_output
if [[ "$print_path" -eq 1 ]]; then printf '%s\n' "$cache_dir"; else echo "Screen Sharing WebRTC host built at $cache_dir"; fi
