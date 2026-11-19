#!/usr/bin/env bash
# Makes bin/optchat-chief a relative symlink to bin/cmux when that binary runs
# the Home Chief by argv[0] (cmux_tui::main, CMUX-570), the way
# link-folded-hosts.sh links the browser host and the app host: one Mach-O
# instead of two, about 15 MB less in the bundle. The app starts the Chief by
# its bundle path (HomeBrainHost.swift), so argv[0] names it, and the Chief's
# re-runs take the link (optchat-chief self_exe.rs).
#
#   scripts/cmux-next/link-optchat-chief.sh --probe <cmux binary>
#   scripts/cmux-next/link-optchat-chief.sh <bin dir>
#
# --probe exits 0 when the binary runs the Chief by argv[0], else 1.
# <bin dir>: replaces a placed bin/optchat-chief copy with the link when
# bin/cmux carries the Chief; prints `folded optchat-chief`, or a note when
# bin/cmux does not (the copy stays). No copy, no link: a build that bundles no
# Chief gets none. Exit 1 when <bin dir>/cmux is not a regular file.
# CMUX_NEXT_OPTCHAT_CHIEF_KEEP_COPY=1 keeps the copy.
set -euo pipefail

# folds <binary>: run it through a link named optchat-chief in a private
# folder; only a binary that carries the Chief prints the Chief's usage
# (`optchat-chief host ...`) for `help`. One for another architecture cannot
# run here and counts as none.
folds() {
  local binary probe_dir answer
  binary="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-folded-chief.XXXXXX")"
  ln -s "$binary" "$probe_dir/optchat-chief"
  answer="$("$probe_dir/optchat-chief" help 2>/dev/null </dev/null | head -n 1 || true)"
  rm -rf "$probe_dir"
  [[ "$answer" == "optchat-chief host "* ]]
}

if [[ "${1:-}" == --probe ]]; then
  [[ -f "${2:-}" ]] || { echo "usage: link-optchat-chief.sh --probe <cmux binary>" >&2; exit 2; }
  folds "$2"
  exit
fi

bin_dir="${1:?usage: link-optchat-chief.sh <bin dir>}"
cmux="$bin_dir/cmux"
chief="$bin_dir/optchat-chief"
[[ -f "$cmux" && ! -L "$cmux" ]] || { echo "error: link-optchat-chief: $cmux is not the regular cmux binary" >&2; exit 1; }
if [[ "$(readlink "$chief" 2>/dev/null || true)" == cmux ]]; then
  folds "$cmux" && { echo "folded optchat-chief"; exit 0; }
  # A link to a cmux that no longer carries the Chief would start the cmux CLI.
  rm -f "$chief"
  echo "warning: link-optchat-chief: bin/cmux no longer runs the Chief; removed the bin/optchat-chief link" >&2
  exit 0
fi
[[ -f "$chief" ]] || exit 0
if [[ "${CMUX_NEXT_OPTCHAT_CHIEF_KEEP_COPY:-}" == 1 ]]; then
  echo "note: link-optchat-chief: CMUX_NEXT_OPTCHAT_CHIEF_KEEP_COPY=1; keeping bin/optchat-chief"
  exit 0
fi
if ! folds "$cmux"; then
  echo "note: link-optchat-chief: bin/cmux does not run the Chief by argv[0]; keeping bin/optchat-chief"
  exit 0
fi
# Remove first: never write through a placed Mach-O (its signature).
rm -f "$chief"
ln -s cmux "$chief"
echo "folded optchat-chief"
