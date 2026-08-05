#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=ghostty-zig-version.sh
source "$SCRIPT_DIR/ghostty-zig-version.sh"

ZIG_REQUIRED="${ZIG_REQUIRED:-$(ghostty_minimum_zig_version "$REPO_ROOT")}"
ZIG_MINISIGN_PUBLIC_KEY="${ZIG_MINISIGN_PUBLIC_KEY:-RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U}"
ZIG_INDEX_URL="${ZIG_INDEX_URL:-https://ziglang.org/download/index.json}"
ZIG_EXPECTED_SHA256="${ZIG_EXPECTED_SHA256:-}"
ZIG_WORK_PARENT="${RUNNER_TEMP:-/tmp/cmux-zig-ci}"
ZIG_SYSTEM_PREFIX="${ZIG_SYSTEM_PREFIX:-/usr/local}"
ZIG_SYSTEM_PREFIX="${ZIG_SYSTEM_PREFIX%/}"
ZIG_PATH_OUTPUT="${ZIG_PATH_OUTPUT:-}"
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
  if [ -n "$ZIG_PATH_OUTPUT" ]; then
    case "$ZIG_PATH_OUTPUT" in
      /*) ;;
      *)
        echo "ZIG_PATH_OUTPUT must be an absolute path: $ZIG_PATH_OUTPUT" >&2
        exit 1
        ;;
    esac
    if [ ! -d "$(dirname "$ZIG_PATH_OUTPUT")" ]; then
      echo "ZIG_PATH_OUTPUT parent does not exist: $(dirname "$ZIG_PATH_OUTPUT")" >&2
      exit 1
    fi
    printf '%s\n' "$zig_path" > "$ZIG_PATH_OUTPUT"
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
  local cached_candidate=""
  local seen=" "
  if [ -n "${ZIG_INSTALL_ROOT:-}" ]; then
    cached_candidate="${ZIG_INSTALL_ROOT%/}"
    if [ "$(basename "$cached_candidate")" != "$ZIG_NAME" ]; then
      cached_candidate="${cached_candidate}/${ZIG_NAME}"
    fi
    cached_candidate="${cached_candidate}/zig"
  fi
  for candidate in "${CMUX_ZIG:-}" "$cached_candidate" "$(command -v zig 2>/dev/null || true)" /opt/homebrew/bin/zig /usr/local/bin/zig; do
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

case "$(uname -s)" in
  Darwin)
    ZIG_OS="macos"
    ZIG_UNSUPPORTED_OS="macOS"
    ;;
  Linux)
    ZIG_OS="linux"
    ZIG_UNSUPPORTED_OS="Linux"
    ;;
  *)
    echo "Unsupported operating system: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64 | aarch64) ZIG_ARCH="aarch64" ;;
  x86_64) ZIG_ARCH="x86_64" ;;
  *)
    echo "Unsupported ${ZIG_UNSUPPORTED_OS} architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

ZIG_NAME="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_REQUIRED}"
use_existing_zig_if_available
mkdir -p "$ZIG_WORK_PARENT"
ZIG_WORK_ROOT="$(mktemp -d "${ZIG_WORK_PARENT%/}/cmux-zig-install-${ZIG_REQUIRED}.XXXXXX")"
ZIG_INSTALL_LOCK=""
ZIG_INSTALL_STAGING=""
cleanup_work_root() {
  if [ -n "$ZIG_INSTALL_STAGING" ]; then
    rm -rf -- "$ZIG_INSTALL_STAGING"
  fi
  if [ -n "$ZIG_INSTALL_LOCK" ]; then
    if [ -d "$ZIG_INSTALL_LOCK" ]; then
      rm -f -- "$ZIG_INSTALL_LOCK/pid"
      rmdir "$ZIG_INSTALL_LOCK" 2>/dev/null || true
    else
      rm -f -- "$ZIG_INSTALL_LOCK"
    fi
  fi
  rm -rf "$ZIG_WORK_ROOT"
}
trap cleanup_work_root EXIT
ZIG_TAR="${ZIG_WORK_ROOT}/${ZIG_NAME}.tar.xz"
ZIG_SIG="${ZIG_TAR}.minisig"
ZIG_DIR="${ZIG_WORK_ROOT}/${ZIG_NAME}"
ZIG_OFFICIAL_URL="https://ziglang.org/download/${ZIG_REQUIRED}/${ZIG_NAME}.tar.xz"
ZIG_MIRROR_URL="${ZIG_MIRROR_URL:-https://zigmirror.hryx.net/zig/${ZIG_NAME}.tar.xz}"
ZIG_SECONDARY_MIRROR_URL="${ZIG_SECONDARY_MIRROR_URL:-https://pkg.hexops.org/zig/${ZIG_NAME}.tar.xz}"
ZIG_INDEX_ARCH="${ZIG_ARCH}-${ZIG_OS}"

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

download_zig_artifact() {
  local suffix="$1"
  local output="$2"
  if download_file "${ZIG_MIRROR_URL}${suffix}" "$output"; then
    return 0
  fi
  echo "Primary mirror download failed; retrying from ${ZIG_SECONDARY_MIRROR_URL}${suffix}" >&2
  if download_file "${ZIG_SECONDARY_MIRROR_URL}${suffix}" "$output"; then
    return 0
  fi
  echo "Secondary mirror download failed; retrying from ${ZIG_OFFICIAL_URL}${suffix}" >&2
  download_file "${ZIG_OFFICIAL_URL}${suffix}" "$output"
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
  if [ "$ZIG_OS" = "linux" ]; then
    printf '%s  %s\n' "$expected_sha256" "$ZIG_TAR" | sha256sum -c -
  else
    printf '%s  %s\n' "$expected_sha256" "$ZIG_TAR" | shasum -a 256 -c -
  fi
}

install_zig_without_sudo() {
  local install_parent="${RUNNER_TEMP:-/tmp/cmux-zig-ci}"
  local install_root="${ZIG_INSTALL_ROOT:-${install_parent}}"
  local source_root
  local target_root
  local install_lock
  local holder_pid
  local wait_attempts=0
  local ownerless_lock_attempts=0
  local invalid_root
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
  elif [ "${ZIG_LOCAL_INSTALL_ONLY:-0}" = "1" ]; then
    echo "ZIG_LOCAL_INSTALL_ONLY=1; installing zig under ${target_root}"
  else
    echo "sudo unavailable; installing zig under ${target_root}"
  fi
  if [ "$source_root" != "$target_root" ]; then
    install_lock="${target_root}.install-lock"
    while ! (set -o noclobber; printf '%s\n' "$$" > "$install_lock") 2>/dev/null; do
      if zig_has_required_version "${target_root}/zig"; then
        echo "zig ${ZIG_REQUIRED} cache became available at ${target_root}/zig"
        publish_zig_for_later_steps "${target_root}/zig"
        "${target_root}/zig" version
        return
      fi

      if [ -d "$install_lock" ]; then
        holder_pid="$(cat "$install_lock/pid" 2>/dev/null || true)"
      else
        holder_pid="$(cat "$install_lock" 2>/dev/null || true)"
      fi
      if [[ "$holder_pid" =~ ^[0-9]+$ ]]; then
        ownerless_lock_attempts=0
        if ! kill -0 "$holder_pid" 2>/dev/null; then
          if [ -d "$install_lock" ]; then
            rm -f -- "$install_lock/pid"
            rmdir "$install_lock" 2>/dev/null || true
          else
            rm -f -- "$install_lock"
          fi
          continue
        fi
      else
        ownerless_lock_attempts=$((ownerless_lock_attempts + 1))
        if [ "$ownerless_lock_attempts" -ge 10 ]; then
          if [ -d "$install_lock" ]; then
            rm -f -- "$install_lock/pid"
            rmdir "$install_lock" 2>/dev/null || true
          else
            rm -f -- "$install_lock"
          fi
          ownerless_lock_attempts=0
          continue
        fi
      fi

      wait_attempts=$((wait_attempts + 1))
      if [ "$wait_attempts" -ge 600 ]; then
        echo "Timed out waiting for Zig cache lock: ${install_lock}" >&2
        exit 1
      fi
      sleep 0.1
    done
    ZIG_INSTALL_LOCK="$install_lock"

    if zig_has_required_version "${target_root}/zig"; then
      echo "zig ${ZIG_REQUIRED} cache became available at ${target_root}/zig"
    else
      ZIG_INSTALL_STAGING="$(mktemp -d "${target_root}.staging.XXXXXX")"
      rmdir "$ZIG_INSTALL_STAGING"
      mv "$source_root" "$ZIG_INSTALL_STAGING"
      if ! zig_has_required_version "${ZIG_INSTALL_STAGING}/zig"; then
        echo "Refusing to publish incomplete Zig cache: ${ZIG_INSTALL_STAGING}" >&2
        exit 1
      fi
      if [ -e "$target_root" ] || [ -L "$target_root" ]; then
        invalid_root="${target_root}.invalid.$$"
        mv "$target_root" "$invalid_root"
        rm -rf -- "$invalid_root"
      fi
      mv "$ZIG_INSTALL_STAGING" "$target_root"
      ZIG_INSTALL_STAGING=""
    fi

    rm -f -- "$install_lock"
    ZIG_INSTALL_LOCK=""
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
download_zig_artifact "" "$ZIG_TAR"
ZIG_RESOLVED_SHA256="$(resolve_zig_sha256)"
verify_zig_sha256 "$ZIG_RESOLVED_SHA256"

if command -v minisign >/dev/null 2>&1; then
  download_zig_artifact ".minisig" "$ZIG_SIG"
  minisign -Vm "$ZIG_TAR" -x "$ZIG_SIG" -P "$ZIG_MINISIGN_PUBLIC_KEY"
else
  echo "minisign not found; verified Zig tarball with SHA-256 from ${ZIG_INDEX_URL}"
fi

rm -rf "$ZIG_DIR"
tar xf "$ZIG_TAR" -C "$ZIG_WORK_ROOT"
if [ "${ZIG_FORCE_LOCAL_INSTALL:-0}" != "1" ] \
  && [ "${ZIG_LOCAL_INSTALL_ONLY:-0}" != "1" ] \
  && command -v sudo >/dev/null 2>&1 \
  && sudo -n true >/dev/null 2>&1; then
  install_zig_with_sudo
  exit 0
fi
install_zig_without_sudo
