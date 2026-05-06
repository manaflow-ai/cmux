#!/usr/bin/env bash
set -euo pipefail

ZIG_REQUIRED="${ZIG_REQUIRED:-0.15.2}"
ZIG_SERIES="${ZIG_SERIES:-0.15}"
ZIG_MINISIGN_PUBLIC_KEY="${ZIG_MINISIGN_PUBLIC_KEY:-RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U}"

append_ci_path() {
  local dir="$1"
  export PATH="$dir:$PATH"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$dir" >> "$GITHUB_PATH"
  fi
  if [[ -n "${BASH_ENV:-}" ]]; then
    printf 'export PATH="%s:$PATH"\n' "$dir" >> "$BASH_ENV"
  fi
}

zig_matches_required() {
  command -v zig >/dev/null 2>&1 && zig version 2>/dev/null | grep -q "^${ZIG_REQUIRED}"
}

install_from_homebrew() {
  if ! command -v brew >/dev/null 2>&1; then
    return 1
  fi

  local formula="zig@${ZIG_SERIES}"
  echo "Installing zig ${ZIG_REQUIRED} with Homebrew formula ${formula}"
  brew install "$formula"

  local prefix
  prefix="$(brew --prefix "$formula")"
  append_ci_path "$prefix/bin"

  if zig_matches_required; then
    zig version
    return 0
  fi

  echo "Homebrew ${formula} did not provide zig ${ZIG_REQUIRED}" >&2
  return 1
}

download_with_retries() {
  local url="$1"
  local output="$2"

  for attempt in 1 2 3 4 5; do
    rm -f "$output"
    echo "Downloading $url (attempt $attempt/5)"
    if curl -fL \
      --retry 2 \
      --retry-all-errors \
      --retry-delay 5 \
      --connect-timeout 20 \
      --max-time 180 \
      --speed-time 45 \
      --speed-limit 8192 \
      "$url" \
      -o "$output"; then
      return 0
    fi
    sleep $((attempt * 5))
  done

  return 1
}

ensure_minisign() {
  if command -v minisign >/dev/null 2>&1; then
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    brew install minisign
  fi
  command -v minisign >/dev/null 2>&1
}

install_from_tarball() {
  local zig_arch
  case "$(uname -m)" in
    arm64) zig_arch="aarch64" ;;
    x86_64) zig_arch="x86_64" ;;
    *)
      echo "Unsupported macOS architecture: $(uname -m)" >&2
      return 1
      ;;
  esac

  local zig_dir="/tmp/zig-${zig_arch}-macos-${ZIG_REQUIRED}"
  local zig_url="https://ziglang.org/download/${ZIG_REQUIRED}/zig-${zig_arch}-macos-${ZIG_REQUIRED}.tar.xz"

  echo "Installing verified zig ${ZIG_REQUIRED} from tarball"
  download_with_retries "$zig_url" /tmp/zig.tar.xz || return 1

  if ensure_minisign; then
    download_with_retries "${zig_url}.minisig" /tmp/zig.tar.xz.minisig || return 1
    minisign -Vm /tmp/zig.tar.xz -x /tmp/zig.tar.xz.minisig -P "$ZIG_MINISIGN_PUBLIC_KEY"
  else
    echo "minisign unavailable, skipping signature verification" >&2
  fi

  rm -rf "$zig_dir"
  tar xf /tmp/zig.tar.xz -C /tmp
  sudo mkdir -p /usr/local/bin /usr/local/lib
  sudo cp -f "${zig_dir}/zig" /usr/local/bin/zig
  sudo rm -rf /usr/local/lib/zig
  sudo mkdir -p /usr/local/lib/zig
  sudo cp -R "${zig_dir}/lib/." /usr/local/lib/zig/

  if ! zig_matches_required; then
    echo "Installed zig does not match required version ${ZIG_REQUIRED}" >&2
    return 1
  fi
  zig version
}

if zig_matches_required; then
  echo "zig ${ZIG_REQUIRED} already installed"
  exit 0
fi

if install_from_homebrew; then
  exit 0
fi

if install_from_tarball; then
  exit 0
fi

echo "Failed to install zig ${ZIG_REQUIRED}" >&2
exit 1
