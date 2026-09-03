#!/usr/bin/env bash
# Provision the small native toolchain used by scripts/build-ish-ios.sh.
#
# iSH's Xcode helper invokes Meson and Ninja from PATH. The tools are commonly
# present on developer Macs, but a clean CI runner cannot rely on that. Prefer
# Homebrew, which is the setup used by the iSH project, and keep a pinned pip
# fallback for machines without Homebrew. The iSH VDSO also needs an LLVM
# clang/lld pair because Apple's clang does not support the i386 ELF linker
# mode. A private bin directory is returned so callers can use every tool
# immediately, even when this script runs in a child process.
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
TOOLS_LOCK_FILE="$TOOLS_ROOT/.provision.lock"
TOOLS_LOCK_WAIT_SECONDS="${CMUX_ISH_TOOLS_LOCK_WAIT_SECONDS:-${CMUX_ISH_LOCK_WAIT_SECONDS:-1800}}"
LLVM_PREFIX="${CMUX_ISH_LLVM_PREFIX:-}"
LLVM_CLANG=""
LLVM_LLD=""
BREW_BIN=""

if [[ ! "$TOOLS_LOCK_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "error: CMUX_ISH_TOOLS_LOCK_WAIT_SECONDS must be a non-negative integer" >&2
  exit 2
fi

usage() {
  cat <<'EOF'
Usage: scripts/ensure-ish-build-tools.sh [--bin-dir]

Ensure that Meson, Ninja, and an LLVM VDSO compiler are available for
scripts/build-ish-ios.sh.
--bin-dir prints a private directory containing all commands. The default
mode prints the same directory and appends it to GITHUB_PATH when available.

Environment:
  CMUX_ISH_TOOLS_DIR       Private tool cache (default: build/ish-tools).
  CMUX_ISH_TOOLS_LOCK_WAIT_SECONDS
                           Lock wait timeout (default: 1800 seconds).
  CMUX_ISH_MESON_VERSION   Meson version for the pip fallback.
  CMUX_ISH_NINJA_VERSION   Ninja version for the pip fallback.
  CMUX_ISH_LLVM_PREFIX      LLVM prefix when Homebrew LLVM is not in a standard path.
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

mkdir -p "$TOOLS_ROOT"

if ! command -v lockf >/dev/null 2>&1; then
  echo "error: missing required command 'lockf' (provided by macOS)" >&2
  exit 1
fi
if [[ -L "$TOOLS_LOCK_FILE" ]]; then
  echo "error: tool provisioning lock is a symlink, refusing to follow it: $TOOLS_LOCK_FILE" >&2
  exit 1
fi
if [[ -e "$TOOLS_LOCK_FILE" && ! -f "$TOOLS_LOCK_FILE" ]]; then
  echo "error: tool provisioning lock is not a regular file: $TOOLS_LOCK_FILE" >&2
  exit 1
fi

TOOLS_LOCK_FD_OPEN=0
tools_cleanup() {
  local exit_status=$?
  set +e
  if [[ "$TOOLS_LOCK_FD_OPEN" == 1 ]]; then
    # Keep the inode persistent. Unlinking it while another helper waits can
    # split the advisory lock across two files.
    exec 8>&-
    TOOLS_LOCK_FD_OPEN=0
  fi
  set -e
  exit "$exit_status"
}
trap tools_cleanup EXIT
trap 'exit 130' INT TERM

# lockf locks the inode, not the pathname. FD 8 stays open until cleanup, so
# every venv and symlink mutation below is serialized without a stale-owner
# PID protocol.
if ! exec 8>>"$TOOLS_LOCK_FILE"; then
  echo "error: could not open tool provisioning lock: $TOOLS_LOCK_FILE" >&2
  exit 1
fi
TOOLS_LOCK_FD_OPEN=1
if ! lockf -s -t "$TOOLS_LOCK_WAIT_SECONDS" 8; then
  exec 8>&-
  TOOLS_LOCK_FD_OPEN=0
  echo "error: another iSH tool provisioning process is still running after ${TOOLS_LOCK_WAIT_SECONDS}s" >&2
  exit 1
fi

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

# Resolve a command or an explicitly supplied path to a regular executable.
# `command -v` can return a bare command name for shell functions and aliases,
# so only accept an absolute result when resolving a PATH lookup.
resolve_executable() {
  local path="$1"
  local directory
  local resolved

  [[ -n "$path" ]] || return 1
  if [[ "$path" != /* ]]; then
    if [[ "$path" == */* ]]; then
      directory="$(cd "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
      path="$directory/$(basename "$path")"
    else
      resolved="$(command -v "$path" 2>/dev/null || true)"
      [[ "$resolved" == /* ]] || return 1
      path="$resolved"
    fi
  fi
  [[ -f "$path" && -x "$path" ]] || return 1
  printf '%s\n' "$path"
}

find_lld_for_clang() {
  local clang_path="$1"
  local clang_dir
  local candidate
  local resolved
  local brew_lld_prefix

  clang_dir="$(cd "$(dirname "$clang_path")" 2>/dev/null && pwd)" || return 1
  # Homebrew and the LLVM project keep ld.lld beside clang. The parent bin
  # check covers distributions that put clang in a nested libexec directory.
  for candidate in "$clang_dir/ld.lld" "$clang_dir/../bin/ld.lld"; do
    if resolved="$(resolve_executable "$candidate" 2>/dev/null)"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done

  # Keep the common keg-only linker locations available even when `brew` is
  # not on PATH. This also supports a machine that has a preinstalled LLVM
  # toolchain but deliberately omits Homebrew from the build environment.
  for candidate in \
    /opt/homebrew/opt/lld/bin/ld.lld \
    /usr/local/opt/lld/bin/ld.lld \
    /opt/local/bin/ld.lld; do
    if resolved="$(resolve_executable "$candidate" 2>/dev/null)"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done

  # Homebrew ships LLVM's compiler and linker as separate formulae. The lld
  # keg is not required to be linked, so inspect its canonical prefix before
  # falling back to PATH.
  if [[ -n "$BREW_BIN" ]]; then
    brew_lld_prefix="$("$BREW_BIN" --prefix lld 2>/dev/null || true)"
    if [[ -n "$brew_lld_prefix" ]] && resolved="$(resolve_executable "$brew_lld_prefix/bin/ld.lld" 2>/dev/null)"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  # A custom LLVM prefix can keep the linker in a sibling directory. Search
  # PATH only after the compiler and Homebrew prefixes, so an unrelated linker
  # cannot be paired accidentally with a different compiler.
  resolved="$(PATH="$clang_dir:$PATH" command -v ld.lld 2>/dev/null || true)"
  if [[ "$resolved" == /* ]] && resolved="$(resolve_executable "$resolved" 2>/dev/null)"; then
    printf '%s\n' "$resolved"
    return 0
  fi
  return 1
}

probe_vdso_compiler() {
  local clang_path="$1"
  local lld_path="$2"
  local clang_dir
  local lld_dir
  local probe_dir
  local probe_source

  clang_dir="$(cd "$(dirname "$clang_path")" 2>/dev/null && pwd)" || return 1
  lld_dir="$(cd "$(dirname "$lld_path")" 2>/dev/null && pwd)" || return 1
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ish-vdso.XXXXXX")" || return 1
  probe_source="$probe_dir/probe.c"
  # Keep this source identical to vendor/ish/vdso/check-cc.sh. It catches the
  # exact target and ELF linker mode that Meson tests before configuring VDSO.
  if ! printf '%s\n' \
    '#if !defined(__i386__) && !defined(__ELF__)' \
    '#error "__i386__ or __ELF__ is not defined"' \
    '#endif' > "$probe_source"; then
    rm -f "$probe_source"
    rmdir "$probe_dir" 2>/dev/null || true
    return 1
  fi

  if PATH="$clang_dir:$lld_dir:$PATH" "$clang_path" \
    -target i386-linux \
    -fuse-ld=lld \
    -shared \
    -nostdlib \
    -x c \
    "$probe_source" \
    -o /dev/null >/dev/null 2>&1; then
    rm -f "$probe_source"
    rmdir "$probe_dir" 2>/dev/null || true
    return 0
  fi

  rm -f "$probe_source"
  rmdir "$probe_dir" 2>/dev/null || true
  return 1
}

try_llvm_candidate() {
  local candidate="$1"
  local clang_path
  local lld_path

  clang_path="$(resolve_executable "$candidate" 2>/dev/null || true)"
  [[ -n "$clang_path" ]] || return 1
  lld_path="$(find_lld_for_clang "$clang_path" 2>/dev/null || true)"
  [[ -n "$lld_path" ]] || return 1
  probe_vdso_compiler "$clang_path" "$lld_path" || return 1
  LLVM_CLANG="$clang_path"
  LLVM_LLD="$lld_path"
  return 0
}

find_usable_llvm() {
  local candidate
  local brew_llvm_prefix
  local path_clang

  LLVM_CLANG=""
  LLVM_LLD=""

  if [[ -n "$LLVM_PREFIX" ]] && try_llvm_candidate "$LLVM_PREFIX/bin/clang"; then
    return 0
  fi
  # These are the keg-only Homebrew and MacPorts locations searched by iSH's
  # own Meson file. Check them before PATH, which usually points to Xcode.
  for candidate in \
    /opt/homebrew/opt/llvm/bin/clang \
    /usr/local/opt/llvm/bin/clang \
    /opt/local/bin/clang; do
    if try_llvm_candidate "$candidate"; then
      return 0
    fi
  done

  if [[ -n "$BREW_BIN" ]]; then
    brew_llvm_prefix="$("$BREW_BIN" --prefix llvm 2>/dev/null || true)"
    if [[ -n "$brew_llvm_prefix" ]] && try_llvm_candidate "$brew_llvm_prefix/bin/clang"; then
      return 0
    fi
  fi

  path_clang="$(command -v clang 2>/dev/null || true)"
  # A prior invocation may have placed our own stale symlink first in PATH.
  if [[ -n "$path_clang" && "$path_clang" != "$BIN_DIR/clang" ]] && try_llvm_candidate "$path_clang"; then
    return 0
  fi
  return 1
}

install_llvm_with_brew() {
  local brew_bin="$1"
  export HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-1}"
  export HOMEBREW_NO_INSTALL_CLEANUP="${HOMEBREW_NO_INSTALL_CLEANUP:-1}"
  export HOMEBREW_NO_ENV_HINTS="${HOMEBREW_NO_ENV_HINTS:-1}"
  echo "==> Installing LLVM clang/lld for the iSH VDSO with Homebrew" >&2
  # Keep stdout reserved for the machine-readable bin directory.
  # Homebrew distributes the compiler and linker as separate formulae. Keep
  # both explicit so a fresh runner never falls back to Apple's clang or ld.
  "$brew_bin" install llvm lld >&2
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

BREW_BIN="$(find_homebrew 2>/dev/null || true)"
if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
  if [[ -n "$BREW_BIN" ]]; then
    # A locked-down runner can expose Homebrew but deny formula writes. Keep
    # the pinned pip path available in that case instead of hiding the real
    # provisioning failure behind a generic command-not-found error.
    install_with_brew "$BREW_BIN" || install_with_pip
  else
    install_with_pip
  fi
fi

if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
  echo "error: failed to provision Meson and Ninja" >&2
  echo "Install them with: brew install meson ninja" >&2
  exit 1
fi

# Apple's clang accepts many normal C flags, but it cannot produce the i386
# ELF shared object used by iSH's VDSO because it has no lld linker. Probe the
# exact command from vendor/ish/vdso/check-cc.sh before configuring Meson. If
# Homebrew is available, install its keg-only LLVM formula and retry. This
# keeps local builds and CI on the same compiler contract.
if ! find_usable_llvm; then
  if [[ -n "$BREW_BIN" ]]; then
    if ! install_llvm_with_brew "$BREW_BIN" || ! find_usable_llvm; then
      echo "error: could not provision a usable LLVM clang/lld pair for the iSH VDSO" >&2
      echo "The compiler must support: clang -target i386-linux -fuse-ld=lld" >&2
      echo "Install it with: brew install llvm lld, or set CMUX_ISH_LLVM_PREFIX to an LLVM prefix" >&2
      exit 1
    fi
  else
    echo "error: could not find a usable LLVM clang/lld pair for the iSH VDSO" >&2
    echo "The compiler must support: clang -target i386-linux -fuse-ld=lld" >&2
    echo "Install it with: brew install llvm lld, or set CMUX_ISH_LLVM_PREFIX to an LLVM prefix" >&2
    exit 1
  fi
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

link_tool() {
  local tool="$1"
  local source_path="$2"
  local target_path="$BIN_DIR/$tool"

  [[ -f "$source_path" && -x "$source_path" ]] || {
    echo "error: resolved $tool is not a regular executable: $source_path" >&2
    exit 1
  }
  # A custom prefix can point directly at the private cache. Avoid replacing
  # that path with a self-referential symlink on repeated invocations.
  if [[ "$source_path" != "$target_path" ]]; then
    ln -sf "$source_path" "$target_path"
  fi
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
  link_tool "$tool" "$source_path"
done

# The private links ensure xcodebuild's child shell sees LLVM even though the
# Homebrew formula is keg-only and iSH's Meson file otherwise falls back to
# Apple's clang from /usr/bin.
link_tool clang "$LLVM_CLANG"
link_tool ld.lld "$LLVM_LLD"

echo "iSH build tools: meson $("$BIN_DIR/meson" --version), ninja $("$BIN_DIR/ninja" --version), LLVM clang $LLVM_CLANG, lld $LLVM_LLD" >&2
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$BIN_DIR" >> "$GITHUB_PATH"
fi
printf '%s\n' "$BIN_DIR"
