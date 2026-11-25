#!/usr/bin/env bash
# Prints the acpmux a build of a checkout bundles, and never runs Cargo where that is not allowed.
#
# In order: the commit-addressed cache (build-acpmux.sh --cached-only); on a build host (CI, a fleet
# build, nx-remote: build-acpmux.sh --check-build-allowed) a Cargo build; anywhere else the acpmux the
# cmux-tui artifacts workflow published for this checkout's tree (pin-cmux-tui.sh fetch-acpmux, checksum-
# verified against the attested manifest), which build-acpmux.sh then seeds its cache from. Before that
# fetch, a fleet Mac that never runs Cargo stopped every dmg=build launch measurement with "no cached acpmux
# for this checkout" (launch-ready.sh base 2a9cba42 on a fleet Mac, 2026-11-16).
#
# Usage: resolve-acpmux.sh [--repo DIR]
#   --repo DIR  the checkout (default: this script's). Only DIR's own build-acpmux.sh and pin-cmux-tui.sh run,
#               so a copy of this script resolves an older commit's checkout too (launch-ready.sh base=SHA).
# Environment: CMUX_TUI_TREE_WAIT_SECONDS (default 0 here: look once; a tree nobody published yet fails now
#   instead of waiting 45 minutes). Prints the path on stdout and what it did on stderr; exit 1 when nothing has it.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$(cd "${2:?missing DIR after --repo}" && pwd)"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
# Each run names its script's path literally: the cmux-next route follows what the app build runs
# (reload.sh, this, build-acpmux.sh, tailnet-go.sh) to keep those scripts on the Mac compile tiers.
[[ -x "$repo/scripts/cmux-next/build-acpmux.sh" ]] || { echo "error: $repo/scripts/cmux-next/build-acpmux.sh is missing" >&2; exit 1; }

cached() { (cd "$repo" && "$repo/scripts/cmux-next/build-acpmux.sh" --cached-only --print-path 2>/dev/null); }

if path="$(cached)"; then
  echo "acpmux: cached $path" >&2
  printf '%s\n' "$path"
  exit 0
fi
if (cd "$repo" && "$repo/scripts/cmux-next/build-acpmux.sh" --check-build-allowed); then
  (cd "$repo" && "$repo/scripts/cmux-next/build-acpmux.sh") >&2
  path="$(cached)" || { echo "error: build-acpmux.sh finished without a cached acpmux" >&2; exit 1; }
  echo "acpmux: built on this host $path" >&2
  printf '%s\n' "$path"
  exit 0
fi
if [[ -x "$repo/scripts/cmux-next/pin-cmux-tui.sh" ]]; then
  if (cd "$repo" && CMUX_TUI_TREE_WAIT_SECONDS="${CMUX_TUI_TREE_WAIT_SECONDS:-0}" "$repo/scripts/cmux-next/pin-cmux-tui.sh" fetch-acpmux) >&2; then
    if path="$(cached)"; then
      echo "acpmux: the published acpmux of this checkout's cmux-tui tree $path" >&2
      printf '%s\n' "$path"
      exit 0
    fi
  fi
fi
echo "error: no cached acpmux for this checkout, this machine never runs Cargo, and no published acpmux of its cmux-tui tree could be fetched; build through nx-remote or the fleet, or set CMUX_NEXT_ACPMUX_BIN" >&2
exit 1
