#!/usr/bin/env bash
# Tab and workspace switch benchmark for a tagged cmux-next build
# (plans/cmux-next/tab-lifecycle.md): Ctrl-Tab held at key-repeat speed
# across mixed terminal and Chromium tabs, terminal/Chromium toggling,
# back-and-forth, and workspace switching. Reports display frame intervals,
# main-thread stalls, footprint and the content invariant (the selected tab
# of every visible pane shows its content; a Chromium page is visible).
#
# Usage:
#   scripts/cmux-next/bench-tab-switch.sh <tag> [--app PATH] [--tabs 20]
#       [--workspaces 6] [--seconds 10] [--interval 33]
#       [--scenarios tab-repeat,tab-mixed,tab-back-forth,workspace-repeat]
#       [--label NAME] [--out DIR] [--keep-running]
#
# Writes artifacts/cmux-next-bench/<sha>-tabswitch-<label>.json. The tagged
# app must not be running; the bench launches and quits it.
set -euo pipefail
if [[ $# -lt 1 || "$1" == -* ]]; then
  sed -n '2,16p' "$0"
  exit 2
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
sha="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
exec python3 "$repo_root/scripts/cmux-next/bench_tab_switch.py" --repo-root "$repo_root" --sha "$sha" --tag "$@"
