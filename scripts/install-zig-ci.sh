#!/usr/bin/env bash
set -euo pipefail

ZIG_REQUIRED="${ZIG_REQUIRED:-0.15.2}"
ZIG_MINISIGN_PUBLIC_KEY="${ZIG_MINISIGN_PUBLIC_KEY:-RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U}"
ZIG_INDEX_URL="${ZIG_INDEX_URL:-https://ziglang.org/download/index.json}"
ZIG_EXPECTED_SHA256="${ZIG_EXPECTED_SHA256:-}"
ZIG_WORK_PARENT="${RUNNER_TEMP:-/tmp/cmux-zig-ci}"
ZIG_SYSTEM_PREFIX="${ZIG_SYSTEM_PREFIX:-/usr/local}"
ZIG_SYSTEM_PREFIX="${ZIG_SYSTEM_PREFIX%/}"
export HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-1}"
export HOMEBREW_NO_INSTALL_CLEANUP="${HOMEBREW_NO_INSTALL_CLEANUP:-1}"
export HOMEBREW_NO_ENV_HINTS="${HOMEBREW_NO_ENV_HINTS:-1}"

publish_zig_for_later_steps() {
  local zig_path="$1"
  local zig_dir
  zig_dir="$(cd "$(dirname "$zig_path")" && pwd)"
  zig_path="${zig_dir}/$(basename "$zig_path")"
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$zig_dir" >> "$GITHUB_PATH"
  fi
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "CMUX_ZIG=$zig_path" >> "$GITHUB_ENV"
  fi
}

read_zig_lib_dir() {
  local zig_path="$1"
  "$zig_path" env 2>/dev/null | python3 -c 'import json, re, sys
text = sys.stdin.read()
try:
    print(json.loads(text).get("lib_dir", ""))
except Exception:
    match = re.search(r"(?m)^\s*\.lib_dir\s*=\s*\"([^\"]*)\"", text)
    print(match.group(1) if match else "")
'
}

zig_has_required_version() {
  local zig_path="$1"
  local zig_lib_dir
  [ -x "$zig_path" ] || return 1
  [ "$("$zig_path" version 2>/dev/null || true)" = "$ZIG_REQUIRED" ] || return 1
  zig_lib_dir="$(read_zig_lib_dir "$zig_path" || true)"
  [ -n "$zig_lib_dir" ] || return 1
  [ -f "$zig_lib_dir/compiler/build_runner.zig" ] || return 1
}

use_existing_zig_if_available() {
  if [ "${ZIG_FORCE_LOCAL_INSTALL:-0}" = "1" ]; then
    return 0
  fi

  local candidate
  local seen=" "
  for candidate in "$(command -v zig 2>/dev/null || true)" /opt/homebrew/bin/zig /usr/local/bin/zig; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    candidate="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
    case "$seen" in
      *" $candidate "*) continue ;;
    esac
    seen="${seen}${candidate} "
    if zig_has_required_version "$candidate"; then
      echo "zig ${ZIG_REQUIRED} already installed at $candidate"
      publish_zig_for_later_steps "$candidate"
      exit 0
    fi
  done
}

use_existing_zig_if_available

case "$(uname -m)" in
  arm64 | aarch64) ZIG_ARCH="aarch64" ;;
  x86_64) ZIG_ARCH="x86_64" ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

ZIG_NAME="zig-${ZIG_ARCH}-macos-${ZIG_REQUIRED}"
mkdir -p "$ZIG_WORK_PARENT"
ZIG_WORK_ROOT="$(mktemp -d "${ZIG_WORK_PARENT%/}/cmux-zig-install-${ZIG_REQUIRED}.XXXXXX")"
cleanup_work_root() {
  rm -rf "$ZIG_WORK_ROOT"
}
trap cleanup_work_root EXIT
ZIG_TAR="${ZIG_WORK_ROOT}/${ZIG_NAME}.tar.xz"
ZIG_SIG="${ZIG_TAR}.minisig"
ZIG_DIR="${ZIG_WORK_ROOT}/${ZIG_NAME}"
ZIG_OFFICIAL_URL="https://ziglang.org/download/${ZIG_REQUIRED}/${ZIG_NAME}.tar.xz"
ZIG_MIRROR_URL="${ZIG_MIRROR_URL:-https://zigmirror.hryx.net/zig/${ZIG_NAME}.tar.xz}"
ZIG_INDEX_ARCH="${ZIG_ARCH}-macos"

download_file() {
  local url="$1"
  local output="$2"
  curl \
    --fail \
    --location \
    --show-error \
    --connect-timeout 20 \
    --max-time 300 \
    --retry 8 \
    --retry-all-errors \
    --retry-delay 10 \
    --retry-max-time 300 \
    "$url" \
    --output "$output"
}

resolve_zig_sha256() {
  if [ -n "$ZIG_EXPECTED_SHA256" ]; then
    printf '%s\n' "$ZIG_EXPECTED_SHA256"
    return 0
  fi

  local index_file="${ZIG_WORK_ROOT}/zig-download-index-${ZIG_REQUIRED}.json"
  download_file "$ZIG_INDEX_URL" "$index_file"
  python3 - "$index_file" "$ZIG_REQUIRED" "$ZIG_INDEX_ARCH" <<'PY'
import json
import sys

index_path, version, arch = sys.argv[1:4]
with open(index_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

try:
    shasum = data[version][arch]["shasum"]
except KeyError as exc:
    raise SystemExit(f"missing Zig checksum for {version} {arch}: {exc}") from exc

if not isinstance(shasum, str) or not shasum:
    raise SystemExit(f"invalid Zig checksum for {version} {arch}")

print(shasum)
PY
  rm -f "$index_file"
}

verify_zig_sha256() {
  local expected_sha256="$1"
  printf '%s  %s\n' "$expected_sha256" "$ZIG_TAR" | shasum -a 256 -c -
}

install_zig_without_sudo() {
  local install_parent="${RUNNER_TEMP:-/tmp/cmux-zig-ci}"
  local install_root="${ZIG_INSTALL_ROOT:-${install_parent}}"
  local source_root
  local target_root
  if [ "$(basename "$install_root")" != "$ZIG_NAME" ]; then
    install_root="${install_root%/}/${ZIG_NAME}"
  fi
  source_root="$(cd "$ZIG_DIR" && pwd -P)"
  mkdir -p "$(dirname "$install_root")"
  target_root="$(cd "$(dirname "$install_root")" && pwd -P)/$(basename "$install_root")"
  if [ "$(basename "$target_root")" != "$ZIG_NAME" ]; then
    echo "Refusing unsafe Zig install root: ${target_root}" >&2
    exit 1
  fi
  if [ "${ZIG_FORCE_LOCAL_INSTALL:-0}" = "1" ]; then
    echo "ZIG_FORCE_LOCAL_INSTALL=1; installing zig under ${target_root}"
  else
    echo "sudo unavailable; installing zig under ${target_root}"
  fi
  if [ "$source_root" != "$target_root" ]; then
    rm -rf "$target_root"
    mv "$source_root" "$target_root"
  fi
  publish_zig_for_later_steps "${target_root}/zig"
  "${target_root}/zig" version
}

install_zig_with_sudo() {
  local system_prefix="$ZIG_SYSTEM_PREFIX"
  local bin_dir="${system_prefix}/bin"
  local lib_dir="${system_prefix}/lib"
  local install_root="${lib_dir}/${ZIG_NAME}"
  if [ -z "$system_prefix" ] || [ "$system_prefix" = "/" ]; then
    echo "Refusing unsafe Zig system prefix: ${ZIG_SYSTEM_PREFIX}" >&2
    exit 1
  fi
  case "$system_prefix" in
    /*) ;;
    *)
      echo "Refusing non-absolute Zig system prefix: ${system_prefix}" >&2
      exit 1
      ;;
  esac
  sudo mkdir -p "$bin_dir" "$lib_dir"
  sudo rm -rf "${lib_dir}/zig" "$install_root"
  sudo cp -R "$ZIG_DIR" "$install_root"
  sudo ln -s "${install_root}/lib" "${lib_dir}/zig"
  sudo rm -f "${bin_dir}/zig"
  sudo ln -s "${install_root}/zig" "${bin_dir}/zig"
  if ! zig_has_required_version "${bin_dir}/zig"; then
    echo "Installed zig ${ZIG_REQUIRED} at ${bin_dir}/zig, but its lib_dir is incomplete" >&2
    exit 1
  fi
  publish_zig_for_later_steps "${bin_dir}/zig"
  "${bin_dir}/zig" version
}

echo "Installing verified zig ${ZIG_REQUIRED}"
rm -f "$ZIG_TAR" "$ZIG_SIG"
if ! download_file "$ZIG_MIRROR_URL" "$ZIG_TAR"; then
  echo "Mirror download failed; retrying from ${ZIG_OFFICIAL_URL}" >&2
  download_file "$ZIG_OFFICIAL_URL" "$ZIG_TAR"
fi
ZIG_RESOLVED_SHA256="$(resolve_zig_sha256)"
verify_zig_sha256 "$ZIG_RESOLVED_SHA256"

if command -v minisign >/dev/null 2>&1; then
  if ! download_file "${ZIG_MIRROR_URL}.minisig" "$ZIG_SIG"; then
    echo "Mirror signature download failed; retrying from ${ZIG_OFFICIAL_URL}.minisig" >&2
    download_file "${ZIG_OFFICIAL_URL}.minisig" "$ZIG_SIG"
  fi
  minisign -Vm "$ZIG_TAR" -x "$ZIG_SIG" -P "$ZIG_MINISIGN_PUBLIC_KEY"
else
  echo "minisign not found; verified Zig tarball with SHA-256 from ${ZIG_INDEX_URL}"
fi

rm -rf "$ZIG_DIR"
tar xf "$ZIG_TAR" -C "$ZIG_WORK_ROOT"
if [ "${ZIG_FORCE_LOCAL_INSTALL:-0}" != "1" ] && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  install_zig_with_sudo
  exit 0
fi
install_zig_without_sudo
