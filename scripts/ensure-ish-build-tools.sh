#!/usr/bin/env bash
# Provision the small native toolchain used by scripts/build-ish-ios.sh.
#
# iSH's Xcode helper invokes Meson and Ninja from PATH. The tools are commonly
# present on developer Macs, but a clean CI runner cannot rely on that. Prefer
# Homebrew, which is the setup used by the iSH project, and keep a pinned pip
# fallback for machines without Homebrew. A private bin directory is returned
# so callers can use the tools immediately, even when this script runs in a
# child process.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

# These versions are only used by the pip fallback. Homebrew installations use
# the runner's signed formulae. Override them when a runner has a known-good
# local mirror or needs to reproduce an older iSH build.
readonly DEFAULT_MESON_VERSION="1.8.3"
readonly DEFAULT_NINJA_VERSION="1.11.1.4"
MESON_VERSION="${CMUX_ISH_MESON_VERSION:-$DEFAULT_MESON_VERSION}"
NINJA_VERSION="${CMUX_ISH_NINJA_VERSION:-$DEFAULT_NINJA_VERSION}"
TOOLS_ROOT="${CMUX_ISH_TOOLS_DIR:-$ROOT/build/ish-tools}"
BIN_DIR="$TOOLS_ROOT/bin"
VENV_DIR="$TOOLS_ROOT/venv"

usage() {
  cat <<'EOF'
Usage: scripts/ensure-ish-build-tools.sh [--bin-dir]

Ensure that Meson and Ninja are available for scripts/build-ish-ios.sh.
--bin-dir prints a private directory containing both commands. The default
mode prints the same directory and appends it to GITHUB_PATH when available.

Environment:
  CMUX_ISH_TOOLS_DIR       Private tool cache (default: build/ish-tools).
  CMUX_ISH_MESON_VERSION   Meson version for the pip fallback.
  CMUX_ISH_NINJA_VERSION   Ninja version for the pip fallback.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$BIN_DIR"

prepend_path() {
  local path="$1"
  [[ -d "$path" ]] || return 0
  case ":$PATH:" in
    *":$path:"*) ;;
    *) PATH="$path:$PATH"; export PATH ;;
  esac
}

find_homebrew() {
  local candidate
  candidate="$(command -v brew 2>/dev/null || true)"
  if [[ -z "$candidate" && -x /opt/homebrew/bin/brew ]]; then
    candidate=/opt/homebrew/bin/brew
  fi
  if [[ -z "$candidate" && -x /usr/local/bin/brew ]]; then
    candidate=/usr/local/bin/brew
  fi
  [[ -n "$candidate" ]] || return 1
  printf '%s\n' "$candidate"
}

install_with_brew() {
  local brew_bin="$1"
  export HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-1}"
  export HOMEBREW_NO_INSTALL_CLEANUP="${HOMEBREW_NO_INSTALL_CLEANUP:-1}"
  export HOMEBREW_NO_ENV_HINTS="${HOMEBREW_NO_ENV_HINTS:-1}"
  echo "==> Installing iSH build tools with Homebrew" >&2
  # Keep stdout reserved for the machine-readable bin directory. Homebrew
  # writes progress and formula notices to stdout on some versions.
  "$brew_bin" install meson ninja >&2
  prepend_path "$($brew_bin --prefix)/bin"
}

install_with_pip() {
  command -v python3 >/dev/null 2>&1 || {
    echo "error: Meson and Ninja are missing, and neither Homebrew nor Python 3 is available" >&2
    echo "Install them with: brew install meson ninja" >&2
    exit 1
  }
  echo "==> Installing pinned Meson ${MESON_VERSION} and Ninja ${NINJA_VERSION} in ${VENV_DIR}" >&2
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    rm -rf "$VENV_DIR"
    python3 -m venv "$VENV_DIR" >&2
  fi
  "$VENV_DIR/bin/python" -m pip install \
    --disable-pip-version-check \
    --quiet \
    "meson==${MESON_VERSION}" \
    "ninja==${NINJA_VERSION}" >&2
  prepend_path "$VENV_DIR/bin"
}

if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
  if brew_bin="$(find_homebrew)"; then
    # A locked-down runner can expose Homebrew but deny formula writes. Keep
    # the pinned pip path available in that case instead of hiding the real
    # provisioning failure behind a generic command-not-found error.
    install_with_brew "$brew_bin" || install_with_pip
  else
    install_with_pip
  fi
fi

if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
  echo "error: failed to provision Meson and Ninja" >&2
  echo "Install them with: brew install meson ninja" >&2
  exit 1
fi

# Symlinks make the child-process contract explicit and avoid relying on a
# shell's exported PATH. Refuse non-regular targets so a hostile checkout
# cannot replace the tool with a directory or device.
find_external_tool() {
  local tool="$1"
  local saved_path="$PATH"
  local filtered_path=""
  local entry
  local path_entries=()

  # A prior invocation can leave BIN_DIR at the front of PATH (for example
  # when a caller exports the value returned by --bin-dir). Do not resolve our
  # own symlink as the source, or the replacement below creates a self-loop.
  IFS=: read -r -a path_entries <<< "$PATH"
  for entry in "${path_entries[@]}"; do
    [[ "$entry" == "$BIN_DIR" ]] && continue
    if [[ -z "$filtered_path" ]]; then
      filtered_path="$entry"
    else
      filtered_path="$filtered_path:$entry"
    fi
  done
  PATH="$filtered_path"
  local resolved
  resolved="$(command -v "$tool" 2>/dev/null || true)"
  PATH="$saved_path"
  printf '%s\n' "$resolved"
}

for tool in meson ninja; do
  source_path="$(find_external_tool "$tool")"
  [[ -n "$source_path" ]] || {
    echo "error: could not find an external $tool executable" >&2
    exit 1
  }
  # `command -v` may return a relative path when PATH contains a relative
  # entry. Resolve it before creating the symlink, because a relative symlink
  # is interpreted relative to BIN_DIR and would otherwise be broken there.
  if [[ "$source_path" != /* ]]; then
    source_dir="$(cd "$(dirname "$source_path")" 2>/dev/null && pwd)" || {
      echo "error: cannot resolve $tool path: $source_path" >&2
      exit 1
    }
    source_path="$source_dir/$(basename "$source_path")"
  fi
  [[ -f "$source_path" && -x "$source_path" ]] || {
    echo "error: resolved $tool is not a regular executable: $source_path" >&2
    exit 1
  }
  ln -sf "$source_path" "$BIN_DIR/$tool"
done

echo "iSH build tools: meson $("$BIN_DIR/meson" --version), ninja $("$BIN_DIR/ninja" --version)" >&2
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$BIN_DIR" >> "$GITHUB_PATH"
fi
printf '%s\n' "$BIN_DIR"
