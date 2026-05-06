#!/usr/bin/env bash
set -euo pipefail

ZIG_REQUIRED="${ZIG_REQUIRED:-0.15.2}"
ZIG_MINISIGN_PUBLIC_KEY="${ZIG_MINISIGN_PUBLIC_KEY:-RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U}"
ZIG_INSTALL_BIN_DIR="${ZIG_INSTALL_BIN_DIR:-/usr/local/bin}"
ZIG_INSTALL_LIB_DIR="${ZIG_INSTALL_LIB_DIR:-/usr/local/lib/zig}"

if [ "$(basename "$ZIG_INSTALL_LIB_DIR")" != "zig" ]; then
  echo "Refusing to replace non-zig lib directory: ${ZIG_INSTALL_LIB_DIR}" >&2
  exit 1
fi

if [ "${ZIG_FORCE_INSTALL:-0}" != "1" ] &&
  command -v zig >/dev/null 2>&1 &&
  zig version 2>/dev/null | grep -q "^${ZIG_REQUIRED}"; then
  echo "zig ${ZIG_REQUIRED} already installed"
  exit 0
fi

case "$(uname -m)" in
  arm64) ZIG_ARCH="aarch64" ;;
  x86_64) ZIG_ARCH="x86_64" ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

install_zig_files() {
  local source_bin="$1"
  local source_lib="$2"
  local source_description="$3"
  local sudo_cmd=()

  if [ ! -x "$source_bin" ]; then
    echo "zig binary not found at ${source_bin}" >&2
    return 1
  fi
  if [ ! -d "$source_lib" ]; then
    echo "zig lib directory not found at ${source_lib}" >&2
    return 1
  fi

  if [ ! -d "$ZIG_INSTALL_BIN_DIR" ]; then
    mkdir -p "$ZIG_INSTALL_BIN_DIR" 2>/dev/null || true
  fi
  if [ ! -d "$(dirname "$ZIG_INSTALL_LIB_DIR")" ]; then
    mkdir -p "$(dirname "$ZIG_INSTALL_LIB_DIR")" 2>/dev/null || true
  fi
  if [ ! -w "$ZIG_INSTALL_BIN_DIR" ] || [ ! -w "$(dirname "$ZIG_INSTALL_LIB_DIR")" ]; then
    sudo_cmd=(sudo)
  fi

  echo "Installing zig ${ZIG_REQUIRED} from ${source_description}"
  "${sudo_cmd[@]}" mkdir -p "$ZIG_INSTALL_BIN_DIR" "$ZIG_INSTALL_LIB_DIR"
  "${sudo_cmd[@]}" rm -rf "$ZIG_INSTALL_LIB_DIR"
  "${sudo_cmd[@]}" mkdir -p "$ZIG_INSTALL_LIB_DIR"
  "${sudo_cmd[@]}" cp -f "$source_bin" "${ZIG_INSTALL_BIN_DIR}/zig"
  "${sudo_cmd[@]}" cp -Rf "${source_lib}/." "$ZIG_INSTALL_LIB_DIR/"

  "${ZIG_INSTALL_BIN_DIR}/zig" version
}

install_from_homebrew() {
  local formula="zig@0.15"
  local brew_prefix
  local brew_zig
  local brew_lib

  if ! command -v brew >/dev/null 2>&1; then
    return 1
  fi

  if ! HOMEBREW_NO_AUTO_UPDATE=1 brew info "$formula" >/dev/null 2>&1; then
    return 1
  fi

  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install "$formula" || return 1
  brew_prefix="$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix "$formula" 2>/dev/null || true)"
  if [ -z "$brew_prefix" ]; then
    return 1
  fi

  brew_zig="${brew_prefix}/bin/zig"
  brew_lib="${brew_prefix}/lib/zig"
  if [ ! -x "$brew_zig" ] || ! "$brew_zig" version 2>/dev/null | grep -q "^${ZIG_REQUIRED}"; then
    return 1
  fi

  install_zig_files "$brew_zig" "$brew_lib" "Homebrew ${formula}"
}

if install_from_homebrew; then
  exit 0
fi

if ! command -v minisign >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "minisign is required to verify zig and Homebrew is unavailable" >&2
    exit 1
  fi
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install minisign
fi

ZIG_BASENAME="zig-${ZIG_ARCH}-macos-${ZIG_REQUIRED}"
ZIG_URL="https://ziglang.org/download/${ZIG_REQUIRED}/${ZIG_BASENAME}.tar.xz"
ZIG_WORKDIR="${TMPDIR:-/tmp}/cmux-zig-${ZIG_ARCH}-${ZIG_REQUIRED}"
ZIG_TARBALL="${ZIG_WORKDIR}/${ZIG_BASENAME}.tar.xz"
ZIG_SIGNATURE="${ZIG_TARBALL}.minisig"

mkdir -p "$ZIG_WORKDIR"

download_file() {
  local url="$1"
  local output="$2"
  local resume="$3"
  local attempt
  local status
  local bytes
  local curl_resume_args=()

  if [ "$resume" = "true" ]; then
    curl_resume_args=(--continue-at -)
  else
    rm -f "$output"
  fi

  for attempt in $(seq 1 12); do
    echo "Downloading ${url} attempt ${attempt}/12"
    if curl --fail --show-error --location \
      "${curl_resume_args[@]}" \
      --retry 3 --retry-all-errors --retry-delay 2 \
      --connect-timeout 20 --max-time 180 \
      --speed-limit 1024 --speed-time 30 \
      "$url" \
      -o "$output"; then
      return 0
    fi

    status="$?"
    bytes="$(wc -c < "$output" 2>/dev/null || echo 0)"
    echo "Download failed with ${status} after ${bytes} bytes" >&2
    if [ "$attempt" -eq 12 ]; then
      return "$status"
    fi
    sleep 5
  done
}

echo "Installing verified zig ${ZIG_REQUIRED} from tarball"
download_file "$ZIG_URL" "$ZIG_TARBALL" true
download_file "${ZIG_URL}.minisig" "$ZIG_SIGNATURE" false
minisign -Vm "$ZIG_TARBALL" -x "$ZIG_SIGNATURE" -P "$ZIG_MINISIGN_PUBLIC_KEY"

rm -rf "${ZIG_WORKDIR:?}/${ZIG_BASENAME}"
tar xf "$ZIG_TARBALL" -C "$ZIG_WORKDIR"
install_zig_files "${ZIG_WORKDIR}/${ZIG_BASENAME}/zig" "${ZIG_WORKDIR}/${ZIG_BASENAME}/lib" "verified tarball"
