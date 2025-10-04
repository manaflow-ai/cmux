#!/usr/bin/env bash
set -euo pipefail

# cmux-env install script
# Installs envctl and envd from GitHub Releases for Linux x86_64/aarch64.

REPO="lawrencecchen/cmux-env"
RAW_INSTALL_URL="https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh"

usage() {
  cat <<EOF
cmux-env installer

Usage:
  curl -fsSL ${RAW_INSTALL_URL} | bash

Options (env vars):
  CMUX_ENV_VERSION  Version to install (e.g. 0.0.1). Default: latest release
  CMUX_ENV_BIN_DIR  Install dir (default: /usr/local/bin if writable, else ~/.local/bin)
  CMUX_ENV_FORCE    Overwrite existing binaries if set to 1
  CMUX_ENV_NO_SUDO  Disable sudo; fall back to ~/.local/bin if needed

This script downloads a prebuilt tarball and installs 'envctl' and 'envd'.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 1; }
}

uname_s=$(uname -s 2>/dev/null || echo unknown)
uname_m=$(uname -m 2>/dev/null || echo unknown)
if [[ "$uname_s" != "Linux" ]]; then
  echo "error: Only Linux is supported (detected: $uname_s)" >&2
  exit 1
fi

case "$uname_m" in
  x86_64|amd64) target="x86_64-unknown-linux-musl" ;;
  aarch64|arm64) target="aarch64-unknown-linux-musl" ;;
  *) echo "error: Unsupported architecture: $uname_m" >&2; exit 1 ;;
esac

VERSION="${CMUX_ENV_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  # fetch latest release tag from GitHub API without jq
  require_cmd curl
  # shellcheck disable=SC2312
  tag=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/' || true)
  if [[ -z "$tag" ]]; then
    echo "error: Could not determine latest release from GitHub API" >&2
    exit 1
  fi
  VERSION="$tag"
fi

echo "cmux-env: installing version $VERSION for target $target"

# Decide bin dir
BIN_DIR="${CMUX_ENV_BIN_DIR:-}"
if [[ -z "$BIN_DIR" ]]; then
  if [[ -w "/usr/local/bin" && "${CMUX_ENV_NO_SUDO:-}" != "1" ]]; then
    BIN_DIR="/usr/local/bin"
  else
    BIN_DIR="$HOME/.local/bin"
  fi
fi

mkdir -p "$BIN_DIR"

asset="cmux-env-${VERSION}-${target}.tar.gz"
url="https://github.com/${REPO}/releases/download/v${VERSION}/${asset}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

echo "- Downloading: $url"
curl -fL "$url" -o "$tmpdir/$asset"

echo "- Extracting"
tar -C "$tmpdir" -xzf "$tmpdir/$asset"

# Find extracted dir
exdir=$(find "$tmpdir" -maxdepth 1 -type d -name "cmux-env-*-${target}" | head -n1)
if [[ -z "$exdir" ]]; then
  echo "error: extracted directory not found in archive" >&2
  exit 1
fi

install_file() {
  local src="$1" dst="$2" name="$3"
  if [[ -e "$dst" && "${CMUX_ENV_FORCE:-0}" != "1" ]]; then
    echo "- Skipping $name (already exists). Set CMUX_ENV_FORCE=1 to overwrite." >&2
    return 0
  fi
  if [[ -w "$(dirname "$dst")" ]]; then
    if command -v install >/dev/null 2>&1; then
      install -m 0755 "$src" "$dst"
    else
      cp "$src" "$dst"
      chmod 0755 "$dst"
    fi
  else
    if [[ "${CMUX_ENV_NO_SUDO:-}" == "1" ]]; then
      echo "error: $dst not writable and CMUX_ENV_NO_SUDO=1" >&2
      exit 1
    fi
    if command -v sudo >/dev/null 2>&1; then
      if sudo command -v install >/dev/null 2>&1; then
        sudo install -m 0755 "$src" "$dst"
      else
        sudo cp "$src" "$dst"
        sudo chmod 0755 "$dst"
      fi
    else
      echo "error: $dst not writable and sudo not available" >&2
      exit 1
    fi
  fi
}

install_file "$exdir/envctl" "$BIN_DIR/envctl" envctl
install_file "$exdir/envd" "$BIN_DIR/envd" envd

echo "- Installed to $BIN_DIR"

case ":$PATH:" in
  *:"$BIN_DIR":*) : ;; 
  *) echo "note: $BIN_DIR is not in PATH. Consider adding it:"; echo "      export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

echo
echo "Next steps:"
echo "  1) Install the shell hook: 'envctl install-hook bash|zsh|fish'"
echo "  2) Try: 'envctl set FOO=bar' then open a new prompt"
