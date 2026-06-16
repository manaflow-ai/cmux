#!/usr/bin/env bash
set -euo pipefail

ZIG_REQUIRED="${ZIG_REQUIRED:-0.15.2}"
ZIG_MINISIGN_PUBLIC_KEY="${ZIG_MINISIGN_PUBLIC_KEY:-RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U}"
ZIG_INDEX_URL="${ZIG_INDEX_URL:-https://ziglang.org/download/index.json}"
ZIG_EXPECTED_SHA256="${ZIG_EXPECTED_SHA256:-}"
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

zig_has_required_version() {
  local zig_path="$1"
  [ -x "$zig_path" ] || return 1
  [ "$("$zig_path" version 2>/dev/null || true)" = "$ZIG_REQUIRED" ]
}

use_existing_zig_if_available() {
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
ZIG_TAR="/tmp/${ZIG_NAME}.tar.xz"
ZIG_SIG="${ZIG_TAR}.minisig"
ZIG_INSTALL_ROOT="${ZIG_INSTALL_ROOT:-${RUNNER_TEMP:-/tmp}/cmux-zig}"
ZIG_INSTALL_DIR="${ZIG_INSTALL_ROOT}/${ZIG_NAME}"
ZIG_OFFICIAL_URL="https://ziglang.org/download/${ZIG_REQUIRED}/${ZIG_NAME}.tar.xz"
ZIG_MIRROR_URL="${ZIG_MIRROR_URL:-https://zigmirror.hryx.net/zig/${ZIG_NAME}.tar.xz}"
ZIG_INDEX_ARCH="${ZIG_ARCH}-macos"

if zig_has_required_version "${ZIG_INSTALL_DIR}/zig"; then
  echo "zig ${ZIG_REQUIRED} already installed at ${ZIG_INSTALL_DIR}/zig"
  publish_zig_for_later_steps "${ZIG_INSTALL_DIR}/zig"
  exit 0
fi

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

  local index_file="/tmp/zig-download-index-${ZIG_REQUIRED}-$$.json"
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

ZIG_EXTRACT_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-zig-extract.XXXXXX")"
tar xf "$ZIG_TAR" -C "$ZIG_EXTRACT_PARENT"
mkdir -p "$ZIG_INSTALL_ROOT"
rm -rf "$ZIG_INSTALL_DIR"
mv "${ZIG_EXTRACT_PARENT}/${ZIG_NAME}" "$ZIG_INSTALL_DIR"
rm -rf "$ZIG_EXTRACT_PARENT"

ZIG_BINARY="${ZIG_INSTALL_DIR}/zig"
if ! zig_has_required_version "$ZIG_BINARY"; then
  echo "Installed Zig binary is not ${ZIG_REQUIRED}: $ZIG_BINARY" >&2
  exit 1
fi

echo "zig ${ZIG_REQUIRED} installed at $ZIG_BINARY"
publish_zig_for_later_steps "$ZIG_BINARY"
"$ZIG_BINARY" version
