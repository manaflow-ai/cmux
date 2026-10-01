#!/usr/bin/env bash
# Xcode "Bundle cmux-tui" phase of the cmux-next target: copies a cmux-tui
# binary to <app>/Contents/Resources/bin/cmux-tui, where CmuxNextDaemon's
# DaemonLauncher runs `cmux-tui --session <S> --json server ensure`, and
# records where it came from in Contents/Resources/bin/cmux-tui.version
# (`commit=`, `source=`, `sha256=`, `run=`).
#
# Source order (this phase never downloads anything):
#   1. CMUX_NEXT_TUI_BIN (an explicit local cargo build or hosted artifact),
#   2. the pinned hosted artifact for this branch: scripts/cmux-next/cmux-tui.pin
#      names a commit, its public files.cmux.com url, the publishing run, and
#      the sha256 of cmux-tui/target/hosted/<commit>/cmux-tui.
#      scripts/reload.sh fetches it before building (no GitHub credentials
#      needed); by hand, `scripts/cmux-next/pin-cmux-tui.sh fetch`. Refresh the
#      pin after a daemon change as described in pin-cmux-tui.sh. A present
#      binary with a different sha256 fails the build.
#
# There is deliberately no release-client fallback. Those clients can be
# executable and recent while still lacking cmux-next's daemon CLI, which
# turns a packaging problem into a runtime startup loop.
set -euo pipefail

dest_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="$dest_dir/cmux-tui"

arch="${NATIVE_ARCH_ACTUAL:-$(uname -m)}"
[[ "$arch" == arm64 ]] && arch=aarch64

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
pin_file="$repo_root/scripts/cmux-next/cmux-tui.pin"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

src=""
source_kind=""
pin_commit=""
pin_run=""
pin_url=""
if [[ -n "${CMUX_NEXT_TUI_BIN:-}" ]]; then
  src="$CMUX_NEXT_TUI_BIN"
  source_kind="override"
fi
if [[ -z "$src" ]]; then
  if [[ ! -f "$pin_file" ]]; then
    echo "error: cmux-next cmux-tui pin is missing at $pin_file; set CMUX_NEXT_TUI_BIN for an explicit override" >&2
    exit 1
  fi
  if [[ "$arch" != aarch64 ]]; then
    echo "error: cmux-next's pinned cmux-tui is available for aarch64 only, but Xcode requested $arch; set CMUX_NEXT_TUI_BIN for an explicit override" >&2
    exit 1
  fi
  pin_commit="$(awk -F= '$1=="commit"{print $2}' "$pin_file")"
  pin_run="$(awk -F= '$1=="run"{print $2}' "$pin_file")"
  pin_url="$(awk -F= '$1=="url"{sub(/^[^=]*=/, ""); print}' "$pin_file")"
  pin_sha256="$(awk -F= '$1=="sha256"{print $2}' "$pin_file")"
  if [[ ! "$pin_commit" =~ ^[0-9a-f]{40}$ || ! "$pin_sha256" =~ ^[0-9a-f]{64}$ || "$pin_url" != https://* ]]; then
    echo "error: malformed cmux-next cmux-tui pin at $pin_file" >&2
    exit 1
  fi
  pinned="$repo_root/cmux-tui/target/hosted/$pin_commit/cmux-tui"
  if [[ -f "$pinned" ]]; then
    actual="$(sha256_of "$pinned")"
    if [[ "$actual" != "$pin_sha256" ]]; then
      echo "error: $pinned has sha256 $actual, but $pin_file pins $pin_sha256" >&2
      exit 1
    fi
    src="$pinned"
    source_kind="pinned-hosted"
  else
    echo "error: pinned cmux-tui $pin_commit is not downloaded; run scripts/cmux-next/pin-cmux-tui.sh fetch or set CMUX_NEXT_TUI_BIN for an explicit override" >&2
    exit 1
  fi
fi

if [[ -z "$src" ]]; then
  echo "error: no cmux-tui source configured; set CMUX_NEXT_TUI_BIN or fetch the pinned client" >&2
  exit 1
fi
if [[ ! -f "$src" ]]; then
  echo "error: cmux-tui source $src does not exist" >&2
  exit 1
fi

sha256="$(sha256_of "$src")"
version_line="$("$src" --version 2>/dev/null | head -n 1 || true)"
commit="$(printf '%s' "$version_line" | sed -n 's/.*(\([0-9a-f]\{7,40\}\).*/\1/p')"
if [[ "$source_kind" == pinned-hosted && ( -z "$commit" || "$pin_commit" != "$commit"* ) ]]; then
  echo "error: pinned cmux-tui reports '$version_line', not commit $pin_commit" >&2
  exit 1
fi
version_file="$dest_dir/cmux-tui.version"
version_text="commit=${commit:-unknown}
source=$source_kind
sha256=$sha256
run=${pin_run}
url=${pin_url}
version=$version_line
"

mkdir -p "$dest_dir"
if ! { [[ -x "$dest" ]] && cmp -s "$src" "$dest"; }; then
  # Remove first: overwriting a Mach-O in place invalidates its signature and
  # the kernel SIGKILLs the next launch.
  rm -f "$dest"
  cp "$src" "$dest"
  chmod 755 "$dest"
  echo "bundled cmux-tui ${commit:-unknown} ($source_kind) from $src"
fi
if [[ ! -f "$version_file" ]] || [[ "$(cat "$version_file")" != "${version_text%$'\n'}" ]]; then
  printf '%s' "$version_text" > "$version_file"
fi
