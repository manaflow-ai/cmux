#!/usr/bin/env bash
# Makes the programs bin/cmux runs by argv[0] (cmux_tui::main FOLDED_HOSTS,
# CMUX-570) relative symlinks to bin/cmux, the way bin/cmux-tui and bin/acpmux
# already are: one Mach-O instead of one per program, each with its own std,
# serde and the crates they share. The daemon runs each by name beside its own
# executable (cmux-tui-core browser_host.rs, apps/host.rs and apps/servers.rs,
# cmux-tui agent_plugin_config.rs), so a link runs the program. A cmux built
# before a program was folded does not answer as it; then nothing changes for
# that program and the caller keeps its own binary.
#
#   scripts/cmux-next/link-folded-hosts.sh --list <cmux binary>
#   scripts/cmux-next/link-folded-hosts.sh --probe <cmux binary>
#   scripts/cmux-next/link-folded-hosts.sh <bin dir> [<name>...]
#
# --list prints the names the binary runs by argv[0], one per line (none for a
# binary from before the fold). --probe exits 0 when it runs any, else 1.
# <name>: the programs to link (default: every name --list prints). Prints
# `folded <name>` per program linked, or a note that bin/cmux has no folded
# programs (exit 0 either way; 1 when <bin dir>/cmux is not a regular file,
# 2 when a named program is not one bin/cmux runs).
set -euo pipefail

# The first fold (cmux#43340): a binary that answers as the browser host but
# does not print its list carries exactly these two.
FIRST_FOLD=(cmux-browser-host cmux-app-host)

# folded_names <binary>: run it through a link named cmux-browser-host in a
# private folder with CMUX_FOLDED_HOSTS_PROBE=1. A binary with the list prints
# `folded-hosts: <name>...`; one from the first fold ignores the variable and
# answers `cmux-browser-host <version> (<sha>)`; any other carries none. A
# binary for another architecture cannot run here and counts as none.
folded_names() {
  local binary probe_dir answer
  binary="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-folded-hosts.XXXXXX")"
  ln -s "$binary" "$probe_dir/cmux-browser-host"
  answer="$(CMUX_FOLDED_HOSTS_PROBE=1 "$probe_dir/cmux-browser-host" version 2>/dev/null </dev/null | head -n 1 || true)"
  rm -rf "$probe_dir"
  case "$answer" in
    "folded-hosts: "*) printf '%s\n' ${answer#folded-hosts: } ;;
    "cmux-browser-host "*) printf '%s\n' "${FIRST_FOLD[@]}" ;;
  esac
}

case "${1:-}" in
  --list|--probe)
    [[ -f "${2:-}" ]] || { echo "usage: link-folded-hosts.sh $1 <cmux binary>" >&2; exit 2; }
    names="$(folded_names "$2")"
    if [[ "$1" == --list ]]; then
      [[ -z "$names" ]] || printf '%s\n' "$names"
      exit 0
    fi
    [[ -n "$names" ]]
    exit
    ;;
esac

bin_dir="${1:?usage: link-folded-hosts.sh <bin dir> [<name>...]}"
shift
cmux="$bin_dir/cmux"
[[ -f "$cmux" && ! -L "$cmux" ]] || { echo "error: link-folded-hosts: $cmux is not the regular cmux binary" >&2; exit 1; }
folded=()
while IFS= read -r name; do [[ -n "$name" ]] && folded+=("$name"); done < <(folded_names "$cmux")
if (( ! ${#folded[@]} )); then
  echo "note: link-folded-hosts: bin/cmux does not run the hosts by argv[0]; keeping their own binaries"
  exit 0
fi
names=("$@")
(( ${#names[@]} )) || names=("${folded[@]}")
for name in "${names[@]}"; do
  [[ " ${folded[*]} " == *" $name "* ]] || { echo "error: link-folded-hosts: bin/cmux does not run $name" >&2; exit 2; }
done
for name in "${names[@]}"; do
  if [[ "$(readlink "$bin_dir/$name" 2>/dev/null || true)" != cmux ]]; then
    # Remove first: never write through a placed Mach-O (its signature).
    rm -rf "${bin_dir:?}/$name"
    ln -s cmux "$bin_dir/$name"
  fi
  echo "folded $name"
done
