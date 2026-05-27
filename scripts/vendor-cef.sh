#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CEF_VERSION="${CMUX_CEF_VERSION:-147.0.10+gd58e84d}"
CHROMIUM_VERSION="${CMUX_CHROMIUM_VERSION:-147.0.7727.118}"
CMAKE_BIN="${CMAKE_BIN:-cmake}"
VENDOR_DIR="${CMUX_CEF_VENDOR_DIR:-$REPO_ROOT/Vendor}"
LINK_ROOT="${CMUX_CEF_LINK_ROOT:-$VENDOR_DIR/cef-active}"
REQUESTED_ARCHS="${CMUX_CEF_ARCHS:-${ARCHS:-$(uname -m)}}"

usage() {
  cat >&2 <<'EOF'
usage: scripts/vendor-cef.sh [--archs "arm64 x86_64"] [--link-root <path>]

Downloads the pinned CEF binary distribution, builds libcef_dll_wrapper and the
cmux CEF helper executable, and points Vendor/cef-active at the selected root.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archs)
      REQUESTED_ARCHS="${2:-}"
      shift 2
      ;;
    --link-root)
      LINK_ROOT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

normalize_arch() {
  case "$1" in
    arm64|aarch64)
      printf 'arm64\n'
      ;;
    x86_64|x64|amd64)
      printf 'x86_64\n'
      ;;
    *)
      return 1
      ;;
  esac
}

selected_arches() {
  local raw=" $REQUESTED_ARCHS "
  local has_arm64=0
  local has_x86_64=0
  case "$raw" in
    *" arm64 "*|*" aarch64 "*) has_arm64=1 ;;
  esac
  case "$raw" in
    *" x86_64 "*|*" x64 "*|*" amd64 "*) has_x86_64=1 ;;
  esac
  if [[ "$has_arm64" -eq 1 ]]; then
    printf 'arm64\n'
  fi
  if [[ "$has_x86_64" -eq 1 ]]; then
    printf 'x86_64\n'
  fi
  if [[ "$has_arm64" -eq 0 && "$has_x86_64" -eq 0 ]]; then
    normalize_arch "$(uname -m)"
  fi
}

cef_archive_arch() {
  case "$1" in
    arm64) printf 'macosarm64\n' ;;
    x86_64) printf 'macosx64\n' ;;
  esac
}

cmake_project_arch() {
  case "$1" in
    arm64) printf 'arm64\n' ;;
    x86_64) printf 'x86_64\n' ;;
  esac
}

cef_root_for_arch() {
  printf '%s/cef-%s\n' "$VENDOR_DIR" "$1"
}

expected_version_for_arch() {
  printf '%s+chromium-%s+%s\n' "$CEF_VERSION" "$CHROMIUM_VERSION" "$1"
}

ensure_cmake() {
  if command -v "$CMAKE_BIN" >/dev/null 2>&1; then
    return
  fi

  local vendored="$VENDOR_DIR/cmake/CMake.app/Contents/bin/cmake"
  if [[ -x "$vendored" ]]; then
    CMAKE_BIN="$vendored"
    return
  fi

  local version="3.30.2"
  local temp="$VENDOR_DIR/cmake-temp.tar.gz"
  mkdir -p "$VENDOR_DIR"
  curl -L "https://github.com/Kitware/CMake/releases/download/v${version}/cmake-${version}-macos-universal.tar.gz" -o "$temp"
  rm -rf "$VENDOR_DIR/cmake" "$VENDOR_DIR/cmake-${version}-macos-universal"
  tar -xzf "$temp" -C "$VENDOR_DIR"
  mv "$VENDOR_DIR/cmake-${version}-macos-universal" "$VENDOR_DIR/cmake"
  rm -f "$temp"
  CMAKE_BIN="$vendored"
}

download_cef_arch() {
  local arch="$1"
  local cef_arch
  cef_arch="$(cef_archive_arch "$arch")"
  local root
  root="$(cef_root_for_arch "$arch")"
  local expected
  expected="$(expected_version_for_arch "$arch")"
  if [[ -d "$root" && -f "$root/.cef-version" && "$(cat "$root/.cef-version")" == "$expected" ]]; then
    return
  fi

  rm -rf "$root"
  mkdir -p "$(dirname "$root")" "$root"
  local temp="$VENDOR_DIR/cef-${arch}-temp.tar.bz2"
  local url="https://cef-builds.spotifycdn.com/cef_binary_${CEF_VERSION}+chromium-${CHROMIUM_VERSION}_${cef_arch}_minimal.tar.bz2"
  curl -L "$url" -o "$temp"
  local size
  size="$(stat -f%z "$temp")"
  if [[ "$size" -lt 50000000 ]]; then
    rm -f "$temp"
    echo "error: CEF download was unexpectedly small: $size bytes" >&2
    exit 1
  fi
  tar -xjf "$temp" --strip-components=1 -C "$root"
  rm -f "$temp"
  echo "$expected" > "$root/.cef-version"
}

build_cef_arch() {
  local arch="$1"
  local root
  root="$(cef_root_for_arch "$arch")"
  local cmake_arch
  cmake_arch="$(cmake_project_arch "$arch")"
  ensure_cmake

  if [[ ! -f "$root/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]]; then
    rm -rf "$root/build"
    mkdir -p "$root/build"
    (
      cd "$root/build"
      "$CMAKE_BIN" -DPROJECT_ARCH="$cmake_arch" -DCMAKE_BUILD_TYPE=Release .. >&2
      make -j"$(sysctl -n hw.ncpu)" libcef_dll_wrapper >&2
    )
  fi
  lipo -archs "$root/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework" | grep -Fx "$arch" >&2

  local helper="$root/build/cmux-cef-helper"
  if [[ -x "$helper" ]] && lipo -archs "$helper" | grep -Fx "$arch" >&2; then
    return
  fi

  xcrun --sdk macosx clang++ \
    -arch "$arch" \
    -mmacosx-version-min=14.0 \
    -std=c++20 \
    -ObjC++ \
    -fobjc-arc \
    -I"$root" \
    -c "$REPO_ROOT/Sources/CEF/CMUXCEFProcessHelper.cc" \
    -o "$root/build/CMUXCEFProcessHelper.o"

  xcrun --sdk macosx clang++ \
    -arch "$arch" \
    -mmacosx-version-min=14.0 \
    -std=c++20 \
    "$root/build/CMUXCEFProcessHelper.o" \
    -o "$helper" \
    -framework Cocoa \
    -F"$root/Release" \
    -framework "Chromium Embedded Framework" \
    -L"$root/build/libcef_dll_wrapper" \
    -lcef_dll_wrapper \
    -stdlib=libc++

  install_name_tool \
    -change "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework" \
    "@executable_path/../../../../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework" \
    "$helper"
  lipo -archs "$helper" | grep -Fx "$arch" >&2
}

file_has_macho_arch() {
  local file_path="$1"
  local arch="$2"
  lipo -archs "$file_path" 2>/dev/null | grep -Fx "$arch" >/dev/null
}

lipo_matching_macho_files() {
  local arm_root="$1"
  local x86_root="$2"
  local out_root="$3"
  local rel
  (
    cd "$arm_root"
    find . -type f -print0
  ) | while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    local arm_file="$arm_root/$rel"
    local x86_file="$x86_root/$rel"
    local out_file="$out_root/$rel"
    [[ -f "$x86_file" ]] || continue
    if file_has_macho_arch "$arm_file" arm64 && file_has_macho_arch "$x86_file" x86_64; then
      lipo -create "$arm_file" "$x86_file" -output "$out_file"
    fi
  done
}

build_universal_root() {
  local arm_root
  arm_root="$(cef_root_for_arch arm64)"
  local x86_root
  x86_root="$(cef_root_for_arch x86_64)"
  local universal_root="$VENDOR_DIR/cef-universal"
  local expected="$CEF_VERSION+chromium-$CHROMIUM_VERSION+universal"

  if [[ -d "$universal_root" && -f "$universal_root/.cef-version" && "$(cat "$universal_root/.cef-version")" == "$expected" ]] \
    && file_has_macho_arch "$universal_root/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework" arm64 \
    && file_has_macho_arch "$universal_root/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework" x86_64 \
    && file_has_macho_arch "$universal_root/build/cmux-cef-helper" arm64 \
    && file_has_macho_arch "$universal_root/build/cmux-cef-helper" x86_64; then
    printf '%s\n' "$universal_root"
    return
  fi

  rm -rf "$universal_root"
  mkdir -p "$universal_root"
  rsync -a --delete "$arm_root/" "$universal_root/"
  lipo_matching_macho_files \
    "$arm_root/Release/Chromium Embedded Framework.framework" \
    "$x86_root/Release/Chromium Embedded Framework.framework" \
    "$universal_root/Release/Chromium Embedded Framework.framework"

  mkdir -p "$universal_root/build/libcef_dll_wrapper"
  lipo -create \
    "$arm_root/build/libcef_dll_wrapper/libcef_dll_wrapper.a" \
    "$x86_root/build/libcef_dll_wrapper/libcef_dll_wrapper.a" \
    -output "$universal_root/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
  lipo -create \
    "$arm_root/build/cmux-cef-helper" \
    "$x86_root/build/cmux-cef-helper" \
    -output "$universal_root/build/cmux-cef-helper"
  chmod +x "$universal_root/build/cmux-cef-helper"
  echo "$expected" > "$universal_root/.cef-version"
  printf '%s\n' "$universal_root"
}

ARCHES=()
while IFS= read -r arch; do
  [[ -n "$arch" ]] && ARCHES+=("$arch")
done < <(selected_arches)
if [[ "${#ARCHES[@]}" -eq 0 ]]; then
  echo "error: no supported CEF architecture found in: $REQUESTED_ARCHS" >&2
  exit 1
fi

for arch in "${ARCHES[@]}"; do
  download_cef_arch "$arch"
  build_cef_arch "$arch"
done

if [[ "${#ARCHES[@]}" -gt 1 ]]; then
  CEF_ROOT="$(build_universal_root)"
else
  CEF_ROOT="$(cef_root_for_arch "${ARCHES[0]}")"
fi

mkdir -p "$(dirname "$LINK_ROOT")"
rm -rf "$LINK_ROOT"
ln -s "$CEF_ROOT" "$LINK_ROOT"
printf '%s\n' "$CEF_ROOT"
