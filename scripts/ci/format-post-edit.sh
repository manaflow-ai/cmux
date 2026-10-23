#!/usr/bin/env bash
# Best-effort format-on-edit for Claude Code and Codex (PostToolUse).
#
# Formats only the files an edit touched, so many agents can share one
# checkout without reformatting each other's work, the way the pre-commit hook
# will at commit time:
# - Rust with the rustfmt of the toolchain its rust-toolchain.toml pins (PATH
#   rustfmt when nothing pins one or that toolchain is missing), with its Cargo package's edition and the
#   nearest rustfmt.toml in the checkout (rustfmt's defaults otherwise).
# - webviews/ and cmux-tui/frontends/web/ files with that package's own vp fmt.
#   Packages that are missing, or older than the lockfile CI installs, are
#   reinstalled from the lockfile first, so the formatter version matches CI.
# Never blocks the edit: a missing formatter or a parse error is a warning on
# stderr, and a clean format is silent. CMUX_SKIP_FORMAT_HOOKS=1 skips it.
set -u

# The checkout this script lives in, whatever directory the agent's shell is in.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)"
[ -n "$ROOT" ] || exit 0

payload="$(cat 2>/dev/null || true)"
# Read the payload first even when skipping, so the agent never writes into a
# closed pipe.
[ "${CMUX_SKIP_FORMAT_HOOKS:-0}" = 1 ] && exit 0
# One line per file:
#   rust<TAB>edition<TAB>toolchain<TAB>path<TAB>config  (toolchain "-" for none; config may be empty)
#   web<TAB>package<TAB>path-inside-package
plan="$(PAYLOAD="$payload" python3 - "$ROOT" <<'PY'
import json
import os
import re
import sys

root = os.path.realpath(sys.argv[1])
raw = os.environ.get("PAYLOAD", "")
try:
    payload = json.loads(raw)
except (TypeError, ValueError):
    payload = {}

paths = set()
keys = {"file_path", "filePath", "path", "filename", "target_file", "targetFile"}
WEB_PACKAGES = ("webviews", "cmux-tui/frontends/web")
TOOLCHAIN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
WEB_FILE = re.compile(r"\.(m?[jt]sx?|c[jt]s|css|scss|html|json|mdx?)$")

def visit(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in keys and isinstance(child, str):
                paths.add(child)
            else:
                visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)

visit(payload)
# apply_patch-style tools carry paths only in the patch text.
for match in re.finditer(r"\*\*\* (?:Add|Update) File: ([^\n\\\"]+)", raw):
    paths.add(match.group(1).strip())

def read(directory, name):
    try:
        with open(os.path.join(root, directory, name), encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return None

def parents(directory):
    while True:
        yield directory
        if not directory:
            return
        directory = os.path.dirname(directory)

def edition(package):
    text = read(package, "Cargo.toml")
    found = re.search(r'^edition\s*=\s*"(\d{4})"', text, re.M)
    if found:
        return found.group(1)
    if re.search(r"^edition\s*(\.\s*workspace\s*=\s*true|=\s*\{\s*workspace\s*=\s*true)", text, re.M):
        for directory in list(parents(package))[1:]:
            workspace = read(directory, "Cargo.toml")
            if workspace and "[workspace.package]" in workspace:
                section = workspace.split("[workspace.package]", 1)[1].split("\n[", 1)[0]
                found = re.search(r'^edition\s*=\s*"(\d{4})"', section, re.M)
                if found:
                    return found.group(1)
    return "2015"

def toolchain(package):
    """The channel the nearest rust-toolchain(.toml) pins, as cargo fmt in CI sees it."""
    for directory in parents(package):
        text = read(directory, "rust-toolchain.toml")
        if text is not None:
            found = re.search(r'^\s*channel\s*=\s*"([^"]+)"', text, re.M)
            channel = found.group(1) if found else ""
        else:
            text = read(directory, "rust-toolchain")
            if text is None:
                continue
            channel = text.strip()
        # A toolchain name, never a path rustup would run a binary from.
        return channel if TOOLCHAIN.fullmatch(channel) else ""
    return ""

# Codex apply_patch paths are relative to the session working directory.
base = payload.get("cwd") if isinstance(payload, dict) else None
base = base if isinstance(base, str) and os.path.isabs(base) else root
for path in sorted(paths):
    if not os.path.isabs(path):
        path = os.path.join(base, path)
    if os.path.isabs(path):
        path = os.path.relpath(os.path.realpath(path), root)
    path = os.path.normpath(path)
    if path.startswith("..") or not os.path.isfile(os.path.join(root, path)):
        continue
    if path.endswith(".rs"):
        package = next((d for d in parents(os.path.dirname(path))
                        if (read(d, "Cargo.toml") or "").count("[package]")), None)
        if package is None:
            continue
        config = next((os.path.join(root, d, name) for d in parents(package)
                       for name in ("rustfmt.toml", ".rustfmt.toml")
                       if os.path.isfile(os.path.join(root, d, name))), "")
        # "-" for no toolchain: read collapses empty tab-separated fields.
        print(f"rust\t{edition(package)}\t{toolchain(package) or '-'}\t{path}\t{config}")
        continue
    package = next((p for p in WEB_PACKAGES if path.startswith(p + "/")), None)
    if package and WEB_FILE.search(path) and "/node_modules/" not in path:
        print(f"web\t{package}\t{path[len(package) + 1:]}")
PY
)"
[ -n "$plan" ] || exit 0

# Temporary files and a held install lock go away however the hook ends; the
# agent's hook timeout sends TERM.
defaults=""
formatted=""
held_lock=""
cleanup() {
  rm -f "${defaults:-}" "${formatted:-}"
  release_install_lock
}
# Removes the lock only while it is still ours: a hook that ran past the
# takeover age must not remove the lock its successor took.
# An empty PID file is ours too: the hook was stopped between mkdir and
# writing its PID.
release_install_lock() {
  if [ -n "$held_lock" ]; then
    case "$(cat "$held_lock/pid" 2>/dev/null || true)" in
      "$$" | "") rm -rf "$held_lock" ;;
    esac
  fi
  held_lock=""
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

rust_lines="$(printf '%s\n' "$plan" | grep '^rust' || true)"
if [ -n "$rust_lines" ]; then
  # An empty config pins rustfmt's defaults, so a stray rustfmt.toml above the
  # checkout never decides the format.
  defaults="$(mktemp "${TMPDIR:-/tmp}/cmux-rustfmt-defaults.XXXXXX")"
  # rustfmt's output, outside the checkout so a killed hook never leaves a file
  # a sibling agent's `git add -A` would commit.
  formatted="$(mktemp "${TMPDIR:-/tmp}/cmux-rustfmt-out.XXXXXX")"
  printf '%s\n' "$rust_lines" | while IFS="$(printf '\t')" read -r _ edition toolchain path config; do
    # The rustfmt of the toolchain CI's cargo fmt uses for this package.
    # rustfmt keeps a stable style across versions, so without that toolchain
    # the PATH rustfmt still formats.
    rustfmt_bin=""
    [ "$toolchain" != - ] || toolchain=""
    if [ -n "$toolchain" ]; then
      rustfmt_bin="$(rustup which --toolchain "$toolchain" rustfmt 2>/dev/null || true)"
      if [ -z "$rustfmt_bin" ] || [ ! -x "$rustfmt_bin" ]; then
        rustfmt_bin=""
        echo "warning: $path pins Rust $toolchain; formatting with the PATH rustfmt (rustup toolchain install $toolchain --component rustfmt)" >&2
      fi
    fi
    [ -n "$rustfmt_bin" ] || rustfmt_bin="$(command -v rustfmt || true)"
    if [ -z "$rustfmt_bin" ]; then
      echo "warning: rustfmt is unavailable; $path is unformatted (the pre-commit hook will refuse an agent commit)" >&2
      continue
    fi
    # Through stdin, so rustfmt formats only this file and never follows its
    # `mod` declarations into child modules another agent may be editing.
    if "$rustfmt_bin" --edition "$edition" --config-path "${config:-$defaults}" <"$ROOT/$path" >"$formatted" 2>/dev/null; then
      cmp -s "$formatted" "$ROOT/$path" || cat "$formatted" >"$ROOT/$path"
    else
      echo "warning: rustfmt could not format $path (a syntax error?)" >&2
    fi
  done
fi

# The version a lockfile pins for a package, or nothing.
locked_version() { # package-dir name
  if [ -f "$1/bun.lock" ]; then
    sed -nE "s/^ *\"$2\": \[\"$2@([^\"]+)\".*/\1/p" "$1/bun.lock" | head -n 1
  elif [ -f "$1/package-lock.json" ]; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["packages"].get("node_modules/"+sys.argv[2], {}).get("version", ""))' \
      "$1/package-lock.json" "$2" 2>/dev/null
  fi
}
installed_version() { # package-dir name
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version", ""))' \
    "$1/node_modules/$2/package.json" 2>/dev/null
}
# vp is missing, or its formatter is older or newer than the lockfile says.
web_packages_stale() { # package-dir
  [ -x "$1/node_modules/.bin/vp" ] || return 0
  for name in vite-plus oxfmt; do
    want="$(locked_version "$1" "$name")"
    [ -z "$want" ] || [ "$want" = "$(installed_version "$1" "$name")" ] || return 0
  done
  return 1
}

# Takes a per-worktree install lock (a directory holding the holder's PID).
# A lock whose holder is gone, or one older than ten minutes, was left by a
# killed hook and is taken over.
# The stale lock is moved aside before mkdir: rename is atomic, so of two hooks
# that both found it stale only one moves it, and a lock that turns out to be
# live once moved (another hook took it meanwhile) is put back.
lock_is_stale() { # lock-dir
  holder="$(cat "$1/pid" 2>/dev/null || true)"
  { [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; } \
    || [ -n "$(find "$1" -maxdepth 0 -mmin +10 2>/dev/null)" ]
}
take_install_lock() { # lock-dir
  if ! mkdir "$1" 2>/dev/null; then
    lock_is_stale "$1" || return 1
    mv "$1" "$1.stale.$$" 2>/dev/null || return 1
    if ! lock_is_stale "$1.stale.$$"; then
      [ -e "$1" ] || mv "$1.stale.$$" "$1" 2>/dev/null || true
      rm -rf "$1.stale.$$"
      return 1
    fi
    rm -rf "$1.stale.$$"
    mkdir "$1" 2>/dev/null || return 1
  fi
  held_lock="$1"
  printf '%s\n' "$$" >"$1/pid"
}

web_packages="$(printf '%s\n' "$plan" | awk -F '\t' '$1 == "web" { print $2 }' | sort -u)"
for package in $web_packages; do
  dir="$ROOT/$package"
  files="$(printf '%s\n' "$plan" | awk -F '\t' -v p="$package" '$1 == "web" && $2 == p { print $3 }')"
  if web_packages_stale "$dir"; then
    # bun install updates node_modules in place. One agent installs into a
    # worktree's node_modules at a time (the others format with what is
    # there); npm ci deletes node_modules first, so npm packages are left to
    # the pre-commit hook.
    lock="$(git -C "$ROOT" rev-parse --git-dir 2>/dev/null || true)"
    case "$lock" in /*) ;; "") lock="$ROOT/.git" ;; *) lock="$ROOT/$lock" ;; esac
    lock="$lock/cmux-format-install-$(printf '%s' "$package" | tr '/' '-').lock"
    if [ ! -f "$dir/bun.lock" ]; then
      echo "warning: $package packages differ from its lockfile; the pre-commit hook reinstalls them" >&2
    elif ! command -v bun >/dev/null 2>&1; then
      :
    elif take_install_lock "$lock"; then
      (cd "$dir" && bun install --frozen-lockfile --ignore-scripts >/dev/null 2>&1) || true
      release_install_lock
    else
      echo "warning: another agent is installing $package packages; formatting with the current ones" >&2
    fi
  fi
  if [ ! -x "$dir/node_modules/.bin/vp" ]; then
    echo "warning: vp is unavailable; edited $package files are unformatted (install its packages)" >&2
    continue
  fi
  # shellcheck disable=SC2086 # one path per word; these packages have no paths with spaces
  (cd "$dir" && "$dir/node_modules/.bin/vp" fmt --no-error-on-unmatched-pattern $files >/dev/null 2>&1) \
    || echo "warning: vp fmt could not format $(printf '%s ' $files)in $package" >&2
done

# A post-edit hook is advisory by design.
exit 0
