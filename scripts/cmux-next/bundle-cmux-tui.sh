#!/usr/bin/env bash
# Xcode "Bundle cmux-tui" phase of the cmux-next target: copies a cmux-tui
# binary to <app>/Contents/Resources/bin/cmux-tui, where CmuxNextDaemon's
# DaemonLauncher runs `cmux-tui --session <S> --json server ensure`, and
# records where it came from in Contents/Resources/bin/cmux-tui.version
# (`commit=`, `source=`, `sha256=`, `run=`).
#
# Source order (this phase never downloads anything):
#   1. CMUX_NEXT_TUI_BIN (a local cargo build or any hosted artifact),
#   2. the pinned hosted artifact for this branch: scripts/cmux-next/cmux-tui.pin
#      names a commit, its public files.cmux.com url, the publishing run, and
#      the sha256 of cmux-tui/target/hosted/<commit>/cmux-tui.
#      scripts/reload.sh fetches it before building (no GitHub credentials
#      needed); by hand, `scripts/cmux-next/pin-cmux-tui.sh fetch`. Refresh the
#      pin after a daemon change as described in pin-cmux-tui.sh. A present
#      binary with a different sha256 fails the build.
#   3. CMUX_TUI_CLIENT_LOCAL (the release installer's local override),
#   4. the newest slice in the release installer cache
#      (~/Library/Caches/cmux/cmux-tui-client/<commit>/cmux-tui-<arch>-apple-darwin).
#      Release clients lack the cmux-next daemon capabilities, so 3 and 4
#      warn. With none of these it keeps an existing bundled copy, or warns
#      and exits 0 (the app reports "cmux-tui binary not found" at launch).
#
# The app host (cmux-app-host, apps-v1) goes next to it, from the same build:
# CMUX_NEXT_APP_HOST_BIN, else a cmux-app-host beside CMUX_NEXT_TUI_BIN /
# CMUX_TUI_CLIENT_LOCAL, else the pinned cmux-tui/target/hosted/<commit>/
# cmux-app-host when the pin has app_host_sha256= (checked like cmux-tui).
# Without one, any bundled app host is removed, so a daemon never runs an app
# host from another build; the daemon then does not advertise apps-v1 and the
# app reports that it needs a newer cmux-tui.
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
if [[ -z "$src" && -f "$pin_file" && "$arch" == aarch64 ]]; then
  pin_commit="$(awk -F= '$1=="commit"{print $2}' "$pin_file")"
  pin_run="$(awk -F= '$1=="run"{print $2}' "$pin_file")"
  pin_url="$(awk -F= '$1=="url"{sub(/^[^=]*=/, ""); print}' "$pin_file")"
  pin_sha256="$(awk -F= '$1=="sha256"{print $2}' "$pin_file")"
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
    echo "warning: pinned cmux-tui $pin_commit is not downloaded; run scripts/cmux-next/pin-cmux-tui.sh fetch"
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
    src="$(ls -t "$cache"/*/"cmux-tui-$arch-apple-darwin" 2>/dev/null | head -n 1 || true)"
    [[ -n "$src" ]] && source_kind="release-cache"
  fi
fi
if [[ "$source_kind" == client-local || "$source_kind" == release-cache ]]; then
  echo "warning: bundling release cmux-tui $src, which lacks the cmux-next daemon capabilities"
fi

if [[ -z "$src" ]]; then
  if [[ -x "$dest" ]]; then
    echo "note: no cmux-tui source configured; keeping bundled $dest"
    exit 0
  fi
  echo "warning: no cmux-tui binary to bundle. Set CMUX_NEXT_TUI_BIN, or run scripts/reload.sh (installs it via scripts/install-cmux-tui-client.sh)."
  exit 0
fi
if [[ ! -f "$src" ]]; then
  echo "error: cmux-tui source $src does not exist" >&2
  exit 1
fi

# The app host of the same build, if there is one (see the header).
app_host_src=""
if [[ -n "${CMUX_NEXT_APP_HOST_BIN:-}" ]]; then
  app_host_src="$CMUX_NEXT_APP_HOST_BIN"
elif [[ "$source_kind" == override || "$source_kind" == client-local ]]; then
  [[ -f "$(dirname "$src")/cmux-app-host" ]] && app_host_src="$(dirname "$src")/cmux-app-host"
elif [[ "$source_kind" == pinned-hosted ]]; then
  pin_app_host_sha256="$(awk -F= '$1=="app_host_sha256"{print $2}' "$pin_file")"
  if [[ -n "$pin_app_host_sha256" ]]; then
    pinned_app_host="$repo_root/cmux-tui/target/hosted/$pin_commit/cmux-app-host"
    if [[ ! -f "$pinned_app_host" ]]; then
      echo "error: pinned cmux-app-host $pin_commit is not downloaded; run scripts/cmux-next/pin-cmux-tui.sh fetch" >&2
      exit 1
    fi
    actual="$(sha256_of "$pinned_app_host")"
    if [[ "$actual" != "$pin_app_host_sha256" ]]; then
      echo "error: $pinned_app_host has sha256 $actual, but $pin_file pins $pin_app_host_sha256" >&2
      exit 1
    fi
    app_host_src="$pinned_app_host"
  fi
fi
if [[ -n "$app_host_src" && ! -f "$app_host_src" ]]; then
  echo "error: cmux-app-host source $app_host_src does not exist" >&2
  exit 1
fi

sha256="$(sha256_of "$src")"
version_line="$("$src" --version 2>/dev/null | head -n 1 || true)"
commit="$(printf '%s' "$version_line" | sed -n 's/.*(\([0-9a-f]\{7,40\}\).*/\1/p')"
if [[ -z "$commit" && "$source_kind" == release-cache ]]; then
  # Cached slices are not executable; the cache directory is the commit.
  commit="$(basename "$(dirname "$src")")"
fi
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
app_host_sha256=${app_host_src:+$(sha256_of "$app_host_src")}
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
app_host_dest="$dest_dir/cmux-app-host"
if [[ -z "$app_host_src" ]]; then
  if [[ -e "$app_host_dest" ]]; then
    rm -f "$app_host_dest"
    echo "removed bundled cmux-app-host: this cmux-tui build has none"
  fi
elif ! { [[ -x "$app_host_dest" ]] && cmp -s "$app_host_src" "$app_host_dest"; }; then
  # Remove first, like cmux-tui: an in-place overwrite breaks the signature.
  rm -f "$app_host_dest"
  cp "$app_host_src" "$app_host_dest"
  chmod 755 "$app_host_dest"
  echo "bundled cmux-app-host from $app_host_src"
fi
if [[ ! -f "$version_file" ]] || [[ "$(cat "$version_file")" != "${version_text%$'\n'}" ]]; then
  printf '%s' "$version_text" > "$version_file"
fi
