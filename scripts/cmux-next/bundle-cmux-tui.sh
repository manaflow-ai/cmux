#!/usr/bin/env bash
# Xcode "Bundle cmux-tui" phase of the cmux-next target: copies a cmux-tui
# binary to <app>/Contents/Resources/bin/cmux, the cmux CLI
# (plans/cmux-next/cli.md), with `cmux-tui` and `acpmux` as relative
# symlinks to it: one Mach-O, one version. CmuxNextDaemon's DaemonLauncher
# runs `bin/cmux-tui --session <S> --json server ensure`; the binary picks
# its program from argv[0]. Records where it came from in
# Contents/Resources/bin/cmux-tui.version (`mode=`, `key=`, `commit=`,
# `source=`, `sha256=`, `run=`, `url=`, `version=`).
#
# This phase never downloads anything. Mode: CMUX_NEXT_TUI_MODE (tree or
# pin), else pin for the Release configuration and tree for every other one.
#
# Source order:
#   1. CMUX_NEXT_TUI_BIN (a local cargo build or any hosted artifact),
#   2. tree mode (dev, tagged and fleet builds): a cmux-tui the fleet compiled
#      from this source (CMUX_TUI_CLIENT_LOCAL whose build commit has this
#      checkout's key, source=tree-local-build), else the hosted build of this
#      checkout's own cmux-tui tree, cmux-tui/target/hosted/tree/<key>/cmux-tui
#      (`scripts/cmux-next/pin-cmux-tui.sh path`). scripts/reload.sh fetches it
#      before building; by hand, `scripts/cmux-next/pin-cmux-tui.sh fetch`.
#      Missing, or a sha256 other than the published one, fails the build.
#   3. pin mode (Release; release jobs then install the pinned commit's
#      universal client): scripts/cmux-next/cmux-tui.pin, as fetched by
#      `pin-cmux-tui.sh fetch --pin`; then CMUX_TUI_CLIENT_LOCAL and the newest
#      release installer cache slice, with a warning. With none of these it
#      keeps an existing bundled copy, or warns and exits 0.
#
# Every non-Release bundle then runs scripts/cmux-next/check-daemon-capabilities.sh
# on the bundled binary: a capability the app relies on that it does not serve
# fails the build.
set -euo pipefail

dest_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="$dest_dir/cmux"
aliases=(cmux-tui acpmux)

# Names other than the real file point at it, relative so the bundle stays
# relocatable and codesign treats them as links, not second copies.
link_aliases() {
  local name
  for name in "${aliases[@]}"; do
    if [[ "$(readlink "$dest_dir/$name" 2>/dev/null || true)" != cmux ]]; then
      rm -rf "${dest_dir:?}/$name"
      ln -s cmux "$dest_dir/$name"
    fi
  done
}

arch="${NATIVE_ARCH_ACTUAL:-$(uname -m)}"
[[ "$arch" == arm64 ]] && arch=aarch64

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
pin_script="$repo_root/scripts/cmux-next/pin-cmux-tui.sh"
pin_file="$repo_root/scripts/cmux-next/cmux-tui.pin"

mode="${CMUX_NEXT_TUI_MODE:-}"
if [[ -z "$mode" ]]; then
  if [[ "${CONFIGURATION:-Debug}" == Release ]]; then mode=pin; else mode=tree; fi
fi
[[ "$mode" == tree || "$mode" == pin ]] || { echo "error: CMUX_NEXT_TUI_MODE must be tree or pin, not '$mode'" >&2; exit 1; }

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

src=""
source_kind=""
key=""
expected_commit=""
run_id=""
url=""
if [[ -n "${CMUX_NEXT_TUI_BIN:-}" ]]; then
  src="$CMUX_NEXT_TUI_BIN"
  source_kind="override"
elif [[ "$mode" == tree ]]; then
  [[ "$arch" == aarch64 ]] || { echo "error: same-tree cmux-tui is published for arm64 only; set CMUX_NEXT_TUI_BIN on $arch" >&2; exit 1; }
  key="$("$pin_script" key)"
  tree_binary="$("$pin_script" path --tree)"
fi
if [[ -z "$src" && "$mode" == tree ]] && "$pin_script" local-build "${CMUX_TUI_CLIENT_LOCAL:-}"; then
  src="$CMUX_TUI_CLIENT_LOCAL"
  source_kind="tree-local-build"
elif [[ -z "$src" && "$mode" == tree ]]; then
  tree_dir="$(dirname "$tree_binary")"
  if [[ ! -f "$tree_binary" || ! -f "$tree_dir/cmux-tui.sha256" ]]; then
    echo "error: the same-tree cmux-tui $key is not downloaded; run scripts/cmux-next/pin-cmux-tui.sh fetch (or set CMUX_NEXT_TUI_BIN)" >&2
    exit 1
  fi
  actual="$(sha256_of "$tree_binary")"
  if [[ "$actual" != "$(cat "$tree_dir/cmux-tui.sha256")" ]]; then
    echo "error: $tree_binary has sha256 $actual, not the published $(cat "$tree_dir/cmux-tui.sha256")" >&2
    exit 1
  fi
  src="$tree_binary"
  source_kind="tree-hosted"
  url="https://files.cmux.com/cmux-tui/tree/$key/cmux-tui-aarch64-apple-darwin"
  if [[ -f "$tree_dir/source.json" ]]; then
    read -r expected_commit run_id < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("commit") or "-", d.get("run") or "-")' "$tree_dir/source.json")
    [[ "$expected_commit" == - ]] && expected_commit=""
    [[ "$run_id" == - ]] && run_id=""
  fi
elif [[ -z "$src" ]]; then
  if [[ -f "$pin_file" && "$arch" == aarch64 ]]; then
    expected_commit="$(awk -F= '$1=="commit"{print $2}' "$pin_file")"
    run_id="$(awk -F= '$1=="run"{print $2}' "$pin_file")"
    url="$(awk -F= '$1=="url"{sub(/^[^=]*=/, ""); print}' "$pin_file")"
    pin_sha256="$(awk -F= '$1=="sha256"{print $2}' "$pin_file")"
    pinned="$repo_root/cmux-tui/target/hosted/$expected_commit/cmux-tui"
    if [[ -f "$pinned" ]]; then
      actual="$(sha256_of "$pinned")"
      if [[ "$actual" != "$pin_sha256" ]]; then
        echo "error: $pinned has sha256 $actual, but $pin_file pins $pin_sha256" >&2
        exit 1
      fi
      src="$pinned"
      source_kind="pinned-hosted"
    else
      echo "warning: pinned cmux-tui $expected_commit is not downloaded; run scripts/cmux-next/pin-cmux-tui.sh fetch --pin"
      expected_commit=""
    fi
  fi
  if [[ -z "$src" && -n "${CMUX_TUI_CLIENT_LOCAL:-}" ]]; then
    src="$CMUX_TUI_CLIENT_LOCAL"
    source_kind="client-local"
  fi
  if [[ -z "$src" ]]; then
    cache="${CMUX_TUI_CLIENT_CACHE:-$HOME/Library/Caches/cmux/cmux-tui-client}"
    if [[ -d "$cache" ]]; then
      # Newest cached slice by mtime.
      # shellcheck disable=SC2012 # cache paths are commit hashes
      src="$(ls -t "$cache"/*/"cmux-tui-$arch-apple-darwin" 2>/dev/null | head -n 1 || true)"
      [[ -n "$src" ]] && source_kind="release-cache"
    fi
  fi
  if [[ "$source_kind" == client-local || "$source_kind" == release-cache ]]; then
    echo "warning: bundling release cmux-tui $src, which lacks the cmux-next daemon capabilities"
  fi
  if [[ -z "$src" ]]; then
    if [[ -x "$dest" && ! -L "$dest" ]]; then
      echo "note: no cmux-tui source configured; keeping bundled $dest"
      link_aliases
      exit 0
    fi
    echo "warning: no cmux-tui binary to bundle. Run scripts/cmux-next/pin-cmux-tui.sh fetch --pin, or set CMUX_NEXT_TUI_BIN."
    exit 0
  fi
fi
if [[ ! -f "$src" ]]; then
  echo "error: cmux-tui source $src does not exist" >&2
  exit 1
fi

sha256="$(sha256_of "$src")"
version_line="$("$src" --version 2>/dev/null | head -n 1 || true)"
commit="$(printf '%s' "$version_line" | sed -n 's/.*(\([0-9a-f]\{7,40\}\).*/\1/p')"
if [[ -z "$commit" && "$source_kind" == release-cache ]]; then
  # Cached slices are not executable; the cache directory is the commit.
  commit="$(basename "$(dirname "$src")")"
fi
if [[ -n "$expected_commit" && ( -z "$commit" || "$expected_commit" != "$commit"* ) ]]; then
  echo "error: $source_kind cmux-tui reports '$version_line', not commit $expected_commit" >&2
  exit 1
fi
version_file="$dest_dir/cmux-tui.version"
version_text="mode=$mode
key=$key
commit=${commit:-unknown}
source=$source_kind
sha256=$sha256
run=$run_id
url=$url
version=$version_line
"

mkdir -p "$dest_dir"
if ! { [[ -x "$dest" && ! -L "$dest" ]] && cmp -s "$src" "$dest"; }; then
  # Remove first: overwriting a Mach-O in place invalidates its signature and
  # the kernel SIGKILLs the next launch.
  rm -f "$dest"
  cp "$src" "$dest"
  chmod 755 "$dest"
  echo "bundled cmux-tui ${commit:-unknown} ($source_kind${key:+, tree $key}) as bin/cmux from $src"
fi
link_aliases
if [[ ! -f "$version_file" ]] || [[ "$(cat "$version_file")" != "${version_text%$'\n'}" ]]; then
  printf '%s' "$version_text" > "$version_file"
fi

if [[ "${CONFIGURATION:-Debug}" != Release ]]; then
  "$repo_root/scripts/cmux-next/check-daemon-capabilities.sh" --binary "$dest_dir/cmux-tui"
fi
