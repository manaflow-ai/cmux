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
# This phase never downloads anything. Mode: CMUX_NEXT_TUI_MODE (tree, pin or
# deferred), else pin for the Release configuration and tree for every other one.
# No mode ever falls back to another cmux-tui (a CMUX_TUI_CLIENT_LOCAL of
# another tree, or a release installer cache slice): an old client runs an old
# daemon in the new app.
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
#   3. pin mode (Release): scripts/cmux-next/cmux-tui.pin, as fetched by
#      `pin-cmux-tui.sh fetch --pin`. A missing or malformed pin, a host other
#      than arm64, or a pin that is not downloaded fails the build.
#   4. deferred mode (release, nightly and CI Release jobs, which replace the
#      client with the universal one of their own tree after the build,
#      install-cmux-tui-client.sh): bundles none. It clears every output this
#      phase owns and exits 0, so no client from another build is left behind.
#
# It then writes bin/daemon-capabilities.json from the placed binary
# (write-daemon-capabilities.sh): the cmux-tui and acpmux capabilities the web
# pages check before they rely on a daemon surface.
#
# Every non-Release bundle then runs scripts/cmux-next/check-daemon-capabilities.sh
# on the bundled binary: a capability the app relies on that it does not serve
# fails the build.
#
# The app host (cmux-app-host, apps-v1) goes next to it as bin/cmux-app-host,
# from the same build: CMUX_NEXT_APP_HOST_BIN, else a cmux-app-host beside
# CMUX_NEXT_TUI_BIN or CMUX_TUI_CLIENT_LOCAL, else the one pin-cmux-tui.sh
# fetch put beside the tree or pinned binary (checked against its sha256).
# Without one, any bundled app host is removed, so a daemon never runs an app
# host from another build; the daemon then does not serve apps-v1 and the app
# reports that it needs a newer cmux-tui. The first-party Cloud app server goes
# beside it as bin/cmux-cloud by the same rules (CMUX_NEXT_CLOUD_SERVER_BIN; pin
# fields cloud_server_*; tree state cmux-cloud.sha256), where the app supervisor
# looks for first-party native servers. The browser host goes beside bin/cmux as
# bin/cmux-browser-host by the same rules (CMUX_NEXT_BROWSER_HOST_BIN; pin fields
# browser_host_*; tree state cmux-browser-host.sha256): the daemon runs the
# sibling of its own executable. The agent screen-detection plugin goes beside
# bin/cmux as bin/cmux-agent-screen-detection by the same rules
# (CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN; tree state
# cmux-agent-screen-detection.sha256), in tree mode only for now: the daemon
# runs that sibling by default (cmux-tui spec/plugins.md, "Bundled default"); a
# build without it bundles none and the daemon runs no default. The slim
# terminal host goes beside bin/cmux as bin/cmux-tui-host by the same rules
# (CMUX_NEXT_TERMINAL_HOST_BIN; tree state cmux-tui-host.sha256; the pin has no
# fields for it, so pin mode bundles none): a macOS daemon runs every terminal
# host from it when it reports the daemon's build, else from a copy of bin/cmux.
# The terminal holder goes beside bin/cmux as bin/cmux-holder by the same rules
# (CMUX_NEXT_HOLDER_BIN; tree state cmux-holder.sha256; no pin fields, so pin
# mode bundles none): the daemon starts every holder from a content-addressed
# copy of it when it answers --version with a wire range the daemon speaks, else
# runs the holder built into bin/cmux-tui-host.
# Release signing (sign-cmux-bundle-helpers.sh)
# signs every Mach-O in bin/ the same way as bin/cmux, and
# check-bundled-browser-host.sh checks the placed copy.
set -euo pipefail

dest_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="$dest_dir/cmux"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/bundle-cmux-tui.stamp"
on_exit() {
  status=$?
  if (( status == 0 )); then
    mkdir -p "$(dirname "$stamp")"
    printf 'completed\n' > "$stamp"
  fi
  exit "$status"
}
trap on_exit EXIT
rm -f "$stamp"
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
[[ "$mode" == tree || "$mode" == pin || "$mode" == deferred ]] || { echo "error: CMUX_NEXT_TUI_MODE must be tree, pin or deferred, not '$mode'" >&2; exit 1; }

# Every output this phase owns. A failed or deferred run removes them all:
# keeping a prior binary would let a successful dependency stamp preserve
# companions from a different tree, architecture, or mode.
clear_outputs() {
  rm -f "$dest" "$dest_dir/cmux-tui" "$dest_dir/acpmux" \
    "$dest_dir/cmux-app-host" "$dest_dir/cmux-cloud" "$dest_dir/cmux-browser-host" \
    "$dest_dir/cmux-tui-host" "$dest_dir/cmux-holder" "$dest_dir/cmux-agent-screen-detection" \
    "$dest_dir/cmux-tui.version" "$dest_dir/daemon-capabilities.json"
}
# pin_error <message>: a pin-mode build without its pinned cmux-tui fails, the
# way tree mode does, and leaves no bundled client behind.
pin_error() {
  clear_outputs
  echo "error: $1" >&2
  echo "error: pin mode (the Release default) bundles only the pinned cmux-tui, never another client: run scripts/cmux-next/pin-cmux-tui.sh fetch --pin, set CMUX_NEXT_TUI_BIN, or build with CMUX_NEXT_TUI_MODE=tree (deferred when install-cmux-tui-client.sh installs the client after the build)" >&2
  exit 1
}

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
    read -r expected_commit run_id published_key < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("commit") or "-", d.get("run") or "-", d.get("key") or "-")' "$tree_dir/source.json")
    [[ "$expected_commit" == - ]] && expected_commit=""
    [[ "$run_id" == - ]] && run_id=""
    # A tree fetched through its v1 publication (CMUX-TUI-TREE-KEY-V2) records that key.
    [[ "$published_key" =~ ^[0-9a-f]{40}$ ]] && url="https://files.cmux.com/cmux-tui/tree/$published_key/cmux-tui-aarch64-apple-darwin"
  fi
elif [[ -z "$src" && "$mode" == pin ]]; then
  [[ -f "$pin_file" ]] || pin_error "no cmux-tui pin at $pin_file"
  [[ "$arch" == aarch64 ]] || pin_error "the pinned cmux-tui is published for arm64 only, not $arch"
  expected_commit="$(awk -F= '$1=="commit"{print $2}' "$pin_file")"
  run_id="$(awk -F= '$1=="run"{print $2}' "$pin_file")"
  url="$(awk -F= '$1=="url"{sub(/^[^=]*=/, ""); print}' "$pin_file")"
  pin_sha256="$(awk -F= '$1=="sha256"{print $2}' "$pin_file")"
  if [[ ! "$expected_commit" =~ ^[0-9a-f]{40}$ || ! "$pin_sha256" =~ ^[0-9a-f]{64}$ || "$url" != https://* ]]; then
    pin_error "$pin_file is malformed: it needs a 40-hex commit=, a 64-hex sha256= and an https:// url="
  fi
  pinned="$repo_root/cmux-tui/target/hosted/$expected_commit/cmux-tui"
  [[ -f "$pinned" ]] || pin_error "the pinned cmux-tui $expected_commit is not downloaded ($pinned)"
  actual="$(sha256_of "$pinned")"
  [[ "$actual" == "$pin_sha256" ]] || pin_error "$pinned has sha256 $actual, but $pin_file pins $pin_sha256"
  src="$pinned"
  source_kind="pinned-hosted"
elif [[ -z "$src" ]]; then
  clear_outputs
  echo "note: CMUX_NEXT_TUI_MODE=deferred: bundled no cmux-tui; install-cmux-tui-client.sh must install this tree's client after the build"
  exit 0
fi
if [[ ! -f "$src" ]]; then
  echo "error: cmux-tui source $src does not exist" >&2
  exit 1
fi

sha256="$(sha256_of "$src")"
version_line="$("$src" --version 2>/dev/null | head -n 1 || true)"
commit="$(printf '%s' "$version_line" | sed -n 's/.*(\([0-9a-f]\{7,40\}\).*/\1/p')"
if [[ -n "$expected_commit" && ( -z "$commit" || "$expected_commit" != "$commit"* ) ]]; then
  echo "error: $source_kind cmux-tui reports '$version_line', not commit $expected_commit" >&2
  exit 1
fi
# The app host and the first-party app servers of the same build, if there are
# any (see the header). companion_source <file> <override env value> <pin field>
# sets companion_src and companion_want.
companion_source() {
  local file="$1" override="$2" pin_field="$3" state pin_sha
  companion_src=""
  companion_want=""
  if [[ -n "$override" ]]; then
    companion_src="$override"
  elif [[ "$source_kind" == override || "$source_kind" == tree-local-build ]]; then
    [[ -f "$(dirname "$src")/$file" ]] && companion_src="$(dirname "$src")/$file"
  elif [[ "$source_kind" == tree-hosted ]]; then
    state="$tree_dir/$file.sha256"
    if [[ ! -f "$state" ]]; then
      echo "warning: the $file of tree $key is not fetched; run scripts/cmux-next/pin-cmux-tui.sh fetch. Bundling none."
    elif [[ "$(cat "$state")" != none ]]; then
      companion_src="$tree_dir/$file"
      companion_want="$(cat "$state")"
    fi
  elif [[ "$source_kind" == pinned-hosted ]]; then
    pin_sha="$(awk -F= -v f="$pin_field" '$1==f{print $2}' "$pin_file")"
    if [[ -n "$pin_sha" ]]; then
      companion_src="$(dirname "$src")/$file"
      companion_want="$pin_sha"
    fi
  fi
  if [[ -n "$companion_src" && ! -f "$companion_src" ]]; then
    echo "error: $file $companion_src does not exist; run scripts/cmux-next/pin-cmux-tui.sh fetch" >&2
    exit 1
  fi
  if [[ -n "$companion_want" ]]; then
    local actual
    actual="$(sha256_of "$companion_src")"
    if [[ "$actual" != "$companion_want" ]]; then
      echo "error: $companion_src has sha256 $actual, not the published $companion_want" >&2
      exit 1
    fi
  fi
}
companion_source cmux-app-host "${CMUX_NEXT_APP_HOST_BIN:-}" app_host_sha256
app_host_src="$companion_src"
companion_source cmux-cloud "${CMUX_NEXT_CLOUD_SERVER_BIN:-}" cloud_server_sha256
cloud_server_src="$companion_src"
companion_source cmux-browser-host "${CMUX_NEXT_BROWSER_HOST_BIN:-}" browser_host_sha256
browser_host_src="$companion_src"
companion_source cmux-tui-host "${CMUX_NEXT_TERMINAL_HOST_BIN:-}" terminal_host_sha256
terminal_host_src="$companion_src"
companion_source cmux-holder "${CMUX_NEXT_HOLDER_BIN:-}" holder_sha256
holder_src="$companion_src"
# Pin mode (Release) bundles no screen detector until its third-party notices
# are mapped (notices/bundle-map.json; check_bundle_notices.py fails a release
# on an unmapped Mach-O) and the pin carries agent_screen_detection_* fields.
agent_screen_detection_src=""
if [[ "$mode" == tree ]]; then
  companion_source cmux-agent-screen-detection "${CMUX_NEXT_AGENT_SCREEN_DETECTION_BIN:-}" agent_screen_detection_sha256
  agent_screen_detection_src="$companion_src"
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
app_host_sha256=${app_host_src:+$(sha256_of "$app_host_src")}
cloud_server_sha256=${cloud_server_src:+$(sha256_of "$cloud_server_src")}
browser_host_sha256=${browser_host_src:+$(sha256_of "$browser_host_src")}
terminal_host_sha256=${terminal_host_src:+$(sha256_of "$terminal_host_src")}
holder_sha256=${holder_src:+$(sha256_of "$holder_src")}
agent_screen_detection_sha256=${agent_screen_detection_src:+$(sha256_of "$agent_screen_detection_src")}
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
# place_companion <source or empty> <file>: copy beside bin/cmux, or remove a copy
# from another build when this build has none.
place_companion() {
  local from="$1" file="$2" to="$dest_dir/$2"
  if [[ -z "$from" ]]; then
    if [[ -e "$to" ]]; then
      rm -f "$to"
      echo "removed bundled $file: this cmux-tui build has none"
    fi
  elif ! { [[ -x "$to" ]] && cmp -s "$from" "$to"; }; then
    # Remove first, like cmux-tui: an in-place overwrite breaks the signature.
    rm -f "$to"
    cp "$from" "$to"
    chmod 755 "$to"
    echo "bundled $file from $from"
  fi
}
place_companion "$app_host_src" cmux-app-host
place_companion "$cloud_server_src" cmux-cloud
place_companion "$browser_host_src" cmux-browser-host
place_companion "$terminal_host_src" cmux-tui-host
place_companion "$holder_src" cmux-holder
place_companion "$agent_screen_detection_src" cmux-agent-screen-detection
if [[ ! -f "$version_file" ]] || [[ "$(cat "$version_file")" != "${version_text%$'\n'}" ]]; then
  printf '%s' "$version_text" > "$version_file"
fi
# bin/daemon-capabilities.json, from the binary just placed. A build of this
# checkout must print its list; an override or pin binary, or a pull
# request's fallback tree (CMUX_TUI_TREE_KEY, an older published tree), may
# predate the command.
require_capabilities=""
if [[ "$source_kind" == tree-local-build ]] || { [[ "$source_kind" == tree-hosted ]] &&
    { [[ -z "${CMUX_TUI_TREE_KEY:-}" ]] || [[ "$CMUX_TUI_TREE_KEY" == "$("$pin_script" key --rev HEAD)" ]]; }; }; then
  require_capabilities="--require"
fi
"$repo_root/scripts/cmux-next/write-daemon-capabilities.sh" ${require_capabilities:+"$require_capabilities"} "$dest_dir"

if [[ "${CONFIGURATION:-Debug}" != Release ]]; then
  "$repo_root/scripts/cmux-next/check-daemon-capabilities.sh" --binary "$dest_dir/cmux-tui"
fi
