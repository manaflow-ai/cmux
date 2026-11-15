#!/usr/bin/env bash
# Makes bin/cmux-browser-host and bin/cmux-app-host relative symlinks to
# bin/cmux when that binary runs them by argv[0] (cmux_tui::main, CMUX-570),
# the way bin/cmux-tui and bin/acpmux already are: one Mach-O instead of three,
# each with its own std, serde and QuickJS. The daemon runs both by name
# beside its own executable (cmux-tui-core browser_host.rs, apps/host.rs), so
# a link runs the host. A cmux built before the fold does not answer as the
# browser host; then nothing changes and the caller keeps their own binaries.
#
#   scripts/cmux-next/link-folded-hosts.sh --probe <cmux binary>
#   scripts/cmux-next/link-folded-hosts.sh <bin dir> [<name>...]
#
# --probe exits 0 when the binary runs the hosts by argv[0], else 1.
# <name>: the hosts to link (default: cmux-browser-host cmux-app-host). Prints
# `folded <name>` per host linked, or a note that bin/cmux has no folded hosts
# (exit 0 either way; 1 when <bin dir>/cmux is not a regular file).
set -euo pipefail

FOLDED=(cmux-browser-host cmux-app-host)

# folds <binary>: run it through a link named cmux-browser-host in a private
# folder; only a binary that carries the hosts answers `cmux-browser-host <version>
# (<sha>)`. A binary for another architecture cannot run here and counts as none.
folds() {
  local binary probe_dir answer
  binary="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-folded-hosts.XXXXXX")"
  ln -s "$binary" "$probe_dir/cmux-browser-host"
  answer="$("$probe_dir/cmux-browser-host" version 2>/dev/null </dev/null | head -n 1 || true)"
  rm -rf "$probe_dir"
  [[ "$answer" == cmux-browser-host\ * ]]
}

if [[ "${1:-}" == --probe ]]; then
  [[ -f "${2:-}" ]] || { echo "usage: link-folded-hosts.sh --probe <cmux binary>" >&2; exit 2; }
  folds "$2"
  exit
fi

bin_dir="${1:?usage: link-folded-hosts.sh <bin dir> [<name>...]}"
shift
names=("$@")
(( ${#names[@]} )) || names=("${FOLDED[@]}")
cmux="$bin_dir/cmux"
[[ -f "$cmux" && ! -L "$cmux" ]] || { echo "error: link-folded-hosts: $cmux is not the regular cmux binary" >&2; exit 1; }
if ! folds "$cmux"; then
  echo "note: link-folded-hosts: bin/cmux does not run the hosts by argv[0]; keeping their own binaries"
  exit 0
fi
for name in "${names[@]}"; do
  [[ " ${FOLDED[*]} " == *" $name "* ]] || { echo "error: link-folded-hosts: $name is not a folded host" >&2; exit 2; }
  if [[ "$(readlink "$bin_dir/$name" 2>/dev/null || true)" != cmux ]]; then
    # Remove first: never write through a placed Mach-O (its signature).
    rm -rf "${bin_dir:?}/$name"
    ln -s cmux "$bin_dir/$name"
  fi
  echo "folded $name"
done
