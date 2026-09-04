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
ZIG_DOWNLOAD_ATTEMPTS="${ZIG_DOWNLOAD_ATTEMPTS:-2}"
ZIG_DOWNLOAD_RETRY_DELAY="${ZIG_DOWNLOAD_RETRY_DELAY:-10}"
# Keep the default short enough for the 20-minute Depot job even when a job
# invokes this installer twice. Dedicated release jobs can set a larger value,
# up to ZIG_DOWNLOAD_BUDGET_MAX_SECONDS, when their job timeout allows it.
ZIG_DOWNLOAD_BUDGET_SECONDS="${ZIG_DOWNLOAD_BUDGET_SECONDS:-480}"
ZIG_DOWNLOAD_BUDGET_MAX_SECONDS=3600
ZIG_DOWNLOAD_ATTEMPTS_MAX=8
ZIG_DOWNLOAD_RETRY_DELAY_MAX_SECONDS=60
export HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-1}"
export HOMEBREW_NO_INSTALL_CLEANUP="${HOMEBREW_NO_INSTALL_CLEANUP:-1}"
export HOMEBREW_NO_ENV_HINTS="${HOMEBREW_NO_ENV_HINTS:-1}"

normalize_bounded_integer() {
  local name="$1"
  local raw="$2"
  local minimum="$3"
  local maximum="$4"
  local normalized

  case "$raw" in
    ''|*[!0-9]*)
      echo "Invalid ${name}: ${raw}" >&2
      return 1
      ;;
  esac

  # Strip leading zeroes before comparing. This avoids overflowing Bash's
  # integer parser when an untrusted value contains many digits.
  normalized="${raw#"${raw%%[!0]*}"}"
  [ -n "$normalized" ] || normalized=0
  if [ "${#normalized}" -gt "${#maximum}" ] || {
    [ "${#normalized}" -eq "${#maximum}" ] && [ "$normalized" -gt "$maximum" ]
  }; then
    echo "${name}=${raw} exceeds maximum ${maximum}; using ${maximum}" >&2
    normalized="$maximum"
  fi
  if [ "$normalized" -lt "$minimum" ]; then
    echo "${name} must be at least ${minimum}: ${raw}" >&2
    return 1
  fi
  printf '%s\n' "$normalized"
}

ZIG_DOWNLOAD_ATTEMPTS="$(normalize_bounded_integer \
  ZIG_DOWNLOAD_ATTEMPTS "$ZIG_DOWNLOAD_ATTEMPTS" 1 "$ZIG_DOWNLOAD_ATTEMPTS_MAX")"
ZIG_DOWNLOAD_RETRY_DELAY="$(normalize_bounded_integer \
  ZIG_DOWNLOAD_RETRY_DELAY "$ZIG_DOWNLOAD_RETRY_DELAY" 0 "$ZIG_DOWNLOAD_RETRY_DELAY_MAX_SECONDS")"
ZIG_DOWNLOAD_BUDGET_SECONDS="$(normalize_bounded_integer \
  ZIG_DOWNLOAD_BUDGET_SECONDS "$ZIG_DOWNLOAD_BUDGET_SECONDS" 1 "$ZIG_DOWNLOAD_BUDGET_MAX_SECONDS")"

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
# The Tsimnet mirror is the reliable first hop for CI. Keep the previous
# mirrors as configurable secondary/tertiary fallbacks before the official
# endpoint.
ZIG_MIRROR_URL="${ZIG_MIRROR_URL:-https://zig-mirror.tsimnet.eu/zig/${ZIG_NAME}.tar.xz}"
ZIG_SECONDARY_MIRROR_URL="${ZIG_SECONDARY_MIRROR_URL:-https://zigmirror.hryx.net/zig/${ZIG_NAME}.tar.xz}"
ZIG_TERTIARY_MIRROR_URL="${ZIG_TERTIARY_MIRROR_URL:-https://pkg.hexops.org/zig/${ZIG_NAME}.tar.xz}"
ZIG_INDEX_ARCH="${ZIG_ARCH}-${ZIG_OS}"
ZIG_DOWNLOAD_DEADLINE_SECONDS=0

download_now_seconds() {
  # Tests may provide a monotonic clock file so retry/deadline behavior can be
  # exercised without waiting on wall-clock time. Production uses Bash's
  # monotonic SECONDS counter.
  if [ -n "${ZIG_DOWNLOAD_TEST_CLOCK_FILE:-}" ]; then
    cat "$ZIG_DOWNLOAD_TEST_CLOCK_FILE"
  else
    printf '%s\n' "$SECONDS"
  fi
}

download_seconds_remaining() {
  local now
  now="$(download_now_seconds)"
  case "$now" in
    ''|*[!0-9]*)
      echo "Invalid download clock value: ${now}" >&2
      return 1
      ;;
  esac
  local remaining=$((ZIG_DOWNLOAD_DEADLINE_SECONDS - now))
  if [ "$remaining" -le 0 ]; then
    echo "Zig download deadline exceeded (${ZIG_DOWNLOAD_BUDGET_SECONDS}s budget)" >&2
    return 1
  fi
  printf '%s\n' "$remaining"
}

download_sleep() {
  local delay="$1"
  if [ -n "${ZIG_DOWNLOAD_TEST_CLOCK_FILE:-}" ]; then
    local now
    now="$(download_now_seconds)"
    printf '%s\n' "$((now + delay))" > "$ZIG_DOWNLOAD_TEST_CLOCK_FILE"
  else
    sleep "$delay"
  fi
}

download_file() {
  local url="$1"
  local output="$2"
  local partial_output="${3:-${output}.part}"
  local attempt=1
  local curl_status=1
  local remaining
  local attempt_timeout
  local connect_timeout

  # Keep retries outside curl. Each curl process receives a timeout no larger
  # than the remaining invocation budget, while the mirror-specific partial
  # file carries progress into the next process.
  while [ "$attempt" -le "$ZIG_DOWNLOAD_ATTEMPTS" ]; do
    if ! remaining="$(download_seconds_remaining)"; then
      return "$curl_status"
    fi
    attempt_timeout="$remaining"
    if [ "$attempt_timeout" -gt 300 ]; then
      attempt_timeout=300
    fi
    connect_timeout=20
    if [ "$connect_timeout" -gt "$attempt_timeout" ]; then
      connect_timeout="$attempt_timeout"
    fi
    if curl \
        --fail \
        --location \
        --show-error \
        --continue-at - \
        --connect-timeout "$connect_timeout" \
        --max-time "$attempt_timeout" \
        "$url" \
        --output "$partial_output"; then
      if ! mv -f "$partial_output" "$output"; then
        return 1
      fi
      return 0
    else
      curl_status="$?"
    fi

    # A server that cannot honor Range cannot resume this partial file. Curl
    # reports that condition as CURLE_RANGE_ERROR (33); only then is it safe
    # to discard the bytes and restart from zero. Preserve partial bytes for
    # every other failure so the next attempt resumes this same mirror.
    if [ "$curl_status" -eq 33 ]; then
      rm -f "$partial_output"
    fi
    if [ "$attempt" -lt "$ZIG_DOWNLOAD_ATTEMPTS" ] && [ "$ZIG_DOWNLOAD_RETRY_DELAY" -gt 0 ]; then
      if ! remaining="$(download_seconds_remaining)"; then
        return "$curl_status"
      fi
      if [ "$remaining" -le "$ZIG_DOWNLOAD_RETRY_DELAY" ]; then
        echo "Zig download deadline leaves no time for another retry" >&2
        return "$curl_status"
      fi
      download_sleep "$ZIG_DOWNLOAD_RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
  done
  return "$curl_status"
}

download_zig_artifact() {
  local suffix="$1"
  local output="$2"
  local mirror_name
  local mirror_url
  local partial_output

  # Each mirror gets its own resumable file. A failed transfer can therefore
  # resume from the same mirror, while a fallback starts with that mirror's
  # own bytes instead of appending to a partial response from another source.
  rm -f "$output"
  for mirror_name in primary secondary tertiary official; do
    case "$mirror_name" in
      primary) mirror_url="$ZIG_MIRROR_URL" ;;
      secondary) mirror_url="$ZIG_SECONDARY_MIRROR_URL" ;;
      tertiary) mirror_url="$ZIG_TERTIARY_MIRROR_URL" ;;
      official) mirror_url="$ZIG_OFFICIAL_URL" ;;
    esac
    partial_output="${output}.${mirror_name}.part"
    if download_file "${mirror_url}${suffix}" "$output" "$partial_output"; then
      return 0
    fi
    case "$mirror_name" in
      primary)
        echo "Primary mirror download failed; retrying from ${ZIG_SECONDARY_MIRROR_URL}${suffix}" >&2
        ;;
      secondary)
        echo "Secondary mirror download failed; retrying from ${ZIG_TERTIARY_MIRROR_URL}${suffix}" >&2
        ;;
      tertiary)
        echo "Tertiary mirror download failed; retrying from ${ZIG_OFFICIAL_URL}${suffix}" >&2
        ;;
      official)
        echo "Official Zig download failed: ${mirror_url}${suffix}" >&2
        ;;
    esac
  done
  return 1
}

resolve_zig_sha256() {
  if [ -n "$ZIG_EXPECTED_SHA256" ]; then
    printf '%s\n' "$ZIG_EXPECTED_SHA256"
    return 0
  fi

  local index_file="${ZIG_WORK_ROOT}/zig-download-index-${ZIG_REQUIRED}.json"
  download_file "$ZIG_INDEX_URL" "$index_file" "${index_file}.part"
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
ZIG_DOWNLOAD_START_SECONDS="$(download_now_seconds)"
case "$ZIG_DOWNLOAD_START_SECONDS" in
  ''|*[!0-9]*)
    echo "Invalid download clock value: ${ZIG_DOWNLOAD_START_SECONDS}" >&2
    exit 1
    ;;
esac
ZIG_DOWNLOAD_DEADLINE_SECONDS=$((ZIG_DOWNLOAD_START_SECONDS + ZIG_DOWNLOAD_BUDGET_SECONDS))
echo "Zig download budget: ${ZIG_DOWNLOAD_BUDGET_SECONDS}s"
ZIG_MINISIGN_AVAILABLE=0
if command -v minisign >/dev/null 2>&1; then
  ZIG_MINISIGN_AVAILABLE=1
fi
download_zig_artifact "" "$ZIG_TAR"
ZIG_RESOLVED_SHA256="$(resolve_zig_sha256)"
verify_zig_sha256 "$ZIG_RESOLVED_SHA256"

if [ "$ZIG_MINISIGN_AVAILABLE" -eq 1 ]; then
  download_zig_artifact ".minisig" "$ZIG_SIG"
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
