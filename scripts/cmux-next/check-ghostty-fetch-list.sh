#!/usr/bin/env bash
# Proves that no cmux Ghostty build fetches a Zig package it does not use, so
# each source archive equals the real fetch list. Today: no build fetches the
# iTerm2 theme set (iterm2_themes). CI only: it runs zig.
#
#   check-ghostty-fetch-list.sh vt       libghostty-vt as ghostty-vt-sys's build.rs
#                                        builds it (its -D flags, its source and gitlink)
#   check-ghostty-fetch-list.sh helper   bin/ghostty (scripts/build-ghostty-cli-helper.sh)
#
# Each mode builds in a fresh copy with an empty Zig cache, then prints the
# fetch list (every package directory in zig-pkg/ and the cache) and fails
# when a forbidden dependency (iterm2_themes) was fetched.
set -euo pipefail
# zig builds Ghostty: fleet or GitHub runner only.
# shellcheck source-path=SCRIPTDIR source=lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fleet-only.sh"
cmux_next_require_fleet check-ghostty-fetch-list.sh "zig build" "cmux-next source archive (dry run) / archive"
[[ $# -eq 1 && ( "$1" == vt || "$1" == helper ) ]] || { echo "usage: $0 vt|helper" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mode="$1"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/cmux-fetch-list.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export ZIG_GLOBAL_CACHE_DIR="$work/zig-cache"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR/tmp"

# Package directories of a forbidden dependency, by name, from the tree's
# build.zig.zon files (the hash is the directory name zig fetches into).
forbidden_dirs() {
  python3 - "$1" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
for zon in root.rglob("build.zig.zon"):
    if "zig-pkg" in zon.relative_to(root).parts:
        continue
    text = zon.read_text(encoding="utf-8", errors="replace")
    for body in re.findall(r"\.iterm2_themes\s*=\s*\.\{([^{}]*)\}", text):
        found = re.search(r'\.hash\s*=\s*"([^"]+)"', body)
        if found:
            print(found.group(1))
PY
}

fresh_copy() {  # <submodule path> <commit> -> a clean checkout without zig-pkg/
  local source="$ROOT/$1" dest="$work/src"
  git clone -q --shared --no-checkout "$source" "$dest"
  git -C "$dest" checkout -q --detach "$2"
  # Ghostty's build reads `git describe`; a non-vX.Y.Z tag panics it.
  local tag
  for tag in $(git -C "$dest" tag -l); do git -C "$dest" tag -d "$tag" >/dev/null; done
  echo "$dest"
}

case "$mode" in
  vt)
    line="$(python3 "$ROOT/scripts/cmux-next/notices/check_ghostty_vt_notices.py" --repo "$ROOT" --print-source | sed -n 's/^libghostty-vt source: //p')"
    src="$(fresh_copy "${line%% *}" "${line##* }")"
    flags=()
    while IFS= read -r flag; do flags+=("$flag"); done < <(grep -o '\.arg("-D[^"]*")' "$ROOT/cmux-tui/crates/ghostty-vt-sys/build.rs" | sed 's/^\.arg("//; s/")$//')
    [[ " ${flags[*]} " == *" -Demit-lib-vt=true "* ]] || { echo "error: could not read build.rs's zig flags" >&2; exit 1; }
    version="$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$src/build.zig.zon" | head -1)"
    echo "libghostty-vt: ${line} with ${flags[*]}"
    (cd "$src" && zig build "${flags[@]}" "-Dversion-string=$version" --prefix "$work/out")
    ;;
  helper)
    src="$(fresh_copy ghostty "$(git -C "$ROOT" rev-parse HEAD:ghostty)")"
    mkdir -p "$work/repo"
    # Build through the real helper script, pointed at the fresh copy.
    cp -R "$ROOT/scripts" "$work/repo/scripts"
    ln -s "$src" "$work/repo/ghostty"
    target=()
    [[ "$(uname -s)" == Darwin ]] && target=(--target aarch64-macos)
    CMUX_DISABLE_GHOSTTY_HELPER_CACHE=1 "$work/repo/scripts/build-ghostty-cli-helper.sh" ${target[@]+"${target[@]}"} --output "$work/out/ghostty"
    ;;
esac

echo "fetch list:"
fetched="$( { ls "$src/zig-pkg" 2>/dev/null; ls "$ZIG_GLOBAL_CACHE_DIR/p" 2>/dev/null; } | sort -u)"
printf '  %s\n' $fetched
bad=0
for dir in $(forbidden_dirs "$src"); do
  if grep -qxF "$dir" <<<"$fetched"; then
    echo "error: the $mode build fetched iterm2_themes ($dir), which it does not use" >&2
    bad=1
  fi
done
[[ "$bad" == 0 ]] || exit 1
echo "check-ghostty-fetch-list: the $mode build fetched no iterm2_themes"
