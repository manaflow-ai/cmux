#!/usr/bin/env bash
# Xcode "Bundle acpmux" phase of the cmux-next target: copies an acpmux
# binary to <app>/Contents/Resources/bin/acpmux, where CmuxNextAcpmux's
# supervisor runs `acpmux daemon run --exit-with-parent <pid> --no-web` for
# the agent GUI, and records its origin in bin/acpmux.version.
#
# Source order (this phase never downloads anything):
#   1. CMUX_NEXT_ACPMUX_BIN (a local cargo build of manaflow-ai/acpmux),
#   2. the pinned hosted artifact: scripts/cmux-next/acpmux.pin names a commit,
#      its public files.cmux.com url and the sha256 of
#      .build/acpmux/<commit>/acpmux, which `pin-acpmux.sh fetch` downloads
#      (scripts/reload.sh runs it). A present binary with another sha256 fails.
# With neither, it keeps an existing bundled copy, or warns and exits 0: the
# app then reports the agent GUI unavailable.
set -euo pipefail

dest_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="$dest_dir/acpmux"
repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
pin_file="$repo_root/scripts/cmux-next/acpmux.pin"
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

src=""
source_kind=""
pin_commit=""
pin_url=""
if [[ -n "${CMUX_NEXT_ACPMUX_BIN:-}" ]]; then
  src="$CMUX_NEXT_ACPMUX_BIN"
  source_kind="override"
elif [[ -f "$pin_file" ]]; then
  pin_commit="$(awk -F= '$1=="commit"{print $2}' "$pin_file")"
  pin_url="$(awk -F= '$1=="url"{sub(/^[^=]*=/, ""); print}' "$pin_file")"
  pin_sha256="$(awk -F= '$1=="sha256"{print $2}' "$pin_file")"
  pinned="$repo_root/.build/acpmux/$pin_commit/acpmux"
  if [[ -f "$pinned" ]]; then
    actual="$(sha256_of "$pinned")"
    if [[ "$actual" != "$pin_sha256" ]]; then
      echo "error: $pinned has sha256 $actual, but $pin_file pins $pin_sha256" >&2
      exit 1
    fi
    src="$pinned"
    source_kind="pinned-hosted"
  else
    echo "warning: pinned acpmux $pin_commit is not downloaded; run scripts/cmux-next/pin-acpmux.sh fetch"
  fi
fi

if [[ -z "$src" ]]; then
  if [[ -x "$dest" ]]; then
    echo "note: no acpmux source configured; keeping bundled $dest"
    exit 0
  fi
  echo "warning: no acpmux binary to bundle (set CMUX_NEXT_ACPMUX_BIN or add scripts/cmux-next/acpmux.pin); the agent GUI will be unavailable."
  exit 0
fi
if [[ ! -f "$src" ]]; then
  echo "error: acpmux source $src does not exist" >&2
  exit 1
fi

sha256="$(sha256_of "$src")"
version_line="$("$src" --version 2>/dev/null | head -n 1 || true)"
version_text="commit=${pin_commit:-unknown}
source=$source_kind
sha256=$sha256
url=${pin_url}
version=$version_line
"
mkdir -p "$dest_dir"
if ! { [[ -x "$dest" ]] && cmp -s "$src" "$dest"; }; then
  # Remove first: overwriting a Mach-O in place invalidates its signature.
  rm -f "$dest"
  cp "$src" "$dest"
  chmod 755 "$dest"
  echo "bundled acpmux ($source_kind) from $src"
fi
version_file="$dest_dir/acpmux.version"
if [[ ! -f "$version_file" ]] || [[ "$(cat "$version_file")" != "${version_text%$'\n'}" ]]; then
  printf '%s' "$version_text" > "$version_file"
fi
