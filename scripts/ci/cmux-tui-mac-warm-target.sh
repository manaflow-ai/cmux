#!/usr/bin/env bash
# Warm cargo target for the cmux-tui leg built natively on an owned Mac ("Build cmux-tui
# (native)" in .github/workflows/cmux-tui-build-package.yml): the macOS fallback build of
# cmux-tui-artifacts.yml, and a feat-cmux-next push leg placed on a free mini.
#
# usage: scripts/ci/cmux-tui-mac-warm-target.sh restore|record TRIPLE
#
# Why: the native leg built into cmux-tui/target inside the workspace, which actions/checkout's
# `clean: true` (git clean -ffdx) empties at the start of every job, and nothing else on a Mac
# kept a cmux-tui release target. Every native leg compiled all ~680 units cold. Run 44947539922
# (2026-11-21, a lane's macOS fallback): "Build cmux-tui (native)" took 2h01m (cargo group 1
# 7249 s, group 6 7051 s; cmux-tui-core alone 6398 s), and the 120 min job timeout then
# cancelled "Build cmux-cloud app server", so the fallback shipped nothing. The Linux legs start
# from a sticky disk feat-cmux-next keeps warm (scripts/ci/machine-channel-warm-target.sh); a
# Mac cannot mount one.
#
# restore (before the build, owned Mac only): this runner's tree under ROOT/KEY becomes an APFS
# clone (cp -c: copy on write, no data copied) of the base tree feat-cmux-next builds keep
# there, cmux-tui/target links to it, and every source file whose content equals the one the
# base built gets its recorded mtime back (scripts/blacksmith-testbox-source-mtimes.py), so
# cargo rebuilds only what the commit changed. A changed file keeps its fresh mtime:
# correctness never depends on the base tree. With no base tree yet it builds cold, as before.
#
# record (after "Stage binary", feat-cmux-next only, never a pull request): record the source mtimes and the
# commit next to the build output, then clone this runner's tree as the new base and swap it in.
# A lane never writes the base.
#
# KEY: the pinned toolchain, the selected Xcode and SDK (build scripts' C compiler, which
# cargo's fingerprints do not see), the triple and LTO (fat and thin objects never mix).
# ROOT is ~/Library/Caches/cmux-next-ci/cmux-tui-package, where HQ's disk-pressure pass
# already bounds per-runner build trees (build-fleet/disk-pressure.sh: idle 12 h, it goes).
# tests/test_ci_cmux_tui_mac_warm_target.py.
set -euo pipefail

if (($# != 2)) || [[ "$1" != restore && "$1" != record ]]; then
  echo "usage: $0 restore|record TRIPLE" >&2
  exit 2
fi
command=$1 triple=$2
[[ "$triple" =~ ^[a-z0-9_]+-[a-z0-9_-]+$ ]] || { echo "invalid triple: $triple" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
link="$repo/cmux-tui/target"

if [[ "${RUNNER_NAME:-}" != *-glaeda* ]]; then
  echo "mac warm target: not an owned Mac (${RUNNER_NAME:-no runner name}); cold build in $link"
  exit 0
fi

sha() { if command -v shasum >/dev/null; then shasum -a 256; else sha256sum; fi | cut -c1-16; }
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo none)}"
xcode_version="$(xcodebuild -version 2>/dev/null || echo none)"
sdk_build="$(xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || echo none)"
key="$( { cat "$repo/cmux-tui/rust-toolchain.toml"; uname -m; echo "$developer_dir"; echo "$xcode_version";
  echo "$sdk_build"; echo "$triple"; echo "lto=${LTO:-}"; } | sha)"
root="${CMUX_TUI_MAC_WARM_ROOT:-${HOME:?}/Library/Caches/cmux-next-ci/cmux-tui-package}/$key"
base="$root/base"
# One runner runs one job at a time, so no other job writes this runner's tree.
mine="$root/runner-$(printf '%s\n' "$RUNNER_NAME" | sha)"
manifest_name=.cmux-testbox-source-mtimes.tsv
source_name=.cmux-tui-mac-warm-source

# ghostty-vt-sys builds for zig's native CPU: the mtimes helper drops that output when the base
# was built on another CPU model (another mini generation), so cargo reruns its build script.
cpuinfo="${RUNNER_TEMP:-/tmp}/cmux-tui-mac-warm-cpu-$triple"
cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
printf 'model name\t: %s\nflags\t: %s\n' "$cpu" "$cpu" > "$cpuinfo"
export CMUX_TESTBOX_CPUINFO="$cpuinfo"

# APFS clonefile on a Mac; a plain copy elsewhere (the tests run on Linux).
clone() { if [[ "$(uname -s)" == Darwin ]]; then cp -c -R -p "$1" "$2"; else cp -a "$1" "$2"; fi; }

restore() {
  if [[ -e "$link" || -L "$link" ]]; then
    echo "mac warm target: miss ($link already exists); building in it"
    return 0
  fi
  mkdir -p "$root"
  rm -rf -- "$mine"
  if [[ -f "$base/$source_name" && ! -L "$base/$source_name" ]]; then
    local from started=$SECONDS
    from="$(head -c 40 "$base/$source_name" | tr -cd '0-9a-f')"
    if clone "$base" "$mine"; then
      echo "mac warm target: hit, feat-cmux-next's target built from $from (cloned in $((SECONDS - started)) s)"
    else
      echo "warning: mac warm target: cloning the base failed; cold build" >&2
      rm -rf -- "$mine"
    fi
  else
    echo "mac warm target: miss (no feat-cmux-next target kept under $root yet); cold build"
  fi
  mkdir -p "$mine"
  ln -s "$mine" "$link"
  if [[ -f "$mine/$manifest_name" ]]; then
    python3 -I "$repo/scripts/blacksmith-testbox-source-mtimes.py" restore "$repo" "$mine/$manifest_name"
  fi
}

record() {
  if [[ "$(readlink "$link" 2>/dev/null || true)" != "$mine" ]]; then
    echo "mac warm target: $link is not this runner's kept tree; nothing to record"
    return 0
  fi
  rm -f "$mine/$source_name"
  python3 -I "$repo/scripts/blacksmith-testbox-source-mtimes.py" record "$repo" "$mine/$manifest_name"
  git -C "$repo" rev-parse HEAD > "$mine/$source_name"
  local next="$root/base.next.$$" old="$root/base.old.$$"
  rm -rf -- "$next" "$old"
  clone "$mine" "$next"
  if [[ -d "$base" ]]; then mv "$base" "$old"; fi
  mv "$next" "$base"
  rm -rf -- "$old"
  echo "mac warm target: kept as feat-cmux-next's base, built from $(cat "$base/$source_name")"
}

"$command"
