#!/usr/bin/env bash
# CLI storm bench (plans/cmux-next/architecture.md sections 5a and 6).
#
# Fires mixed control-socket requests (reads, creates, sends, renames,
# closes) from many concurrent clients at a running tagged cmux-next build
# while one visible terminal streams output through the daemon, then checks
# the section 5a pass criteria:
#   - 0 main-thread stalls > 50 ms (debug.hangs)
#   - p99 frame interval < 16.7 ms (debug.frames, display-link timestamps)
#   - every request answered or failed fast (none waits past the 2 s deadline)
#   - app RSS back within 10% of baseline after cleanup
#
# Usage:
#   scripts/cmux-next/bench-cli-storm.sh <tag> [--socket PATH] [--clients 32]
#       [--requests 2000] [--stream-bytes 52428800] [--seed 1] [--out DIR]
#       [--prewarm-tabs 16] [--max-creates 96] [--measure-seconds 10]
#       [--label NAME] [--profile next|legacy] [--no-fail]
#
# Launch the tagged app first with a clean environment, for example:
#   env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin CMUX_NEXT_NO_ACTIVATE=1 \
#     CMUX_NEXT_SOCKET_MODE=automation open -g "<tagged app>"
#
# Writes artifacts/cmux-next-bench/<sha>-<label>.json and exits 1 when a
# criterion fails (unless --no-fail). `--profile legacy` drives the old
# app's v2 socket for a before/after comparison (no stall/frame data there).
set -euo pipefail
if [[ $# -lt 1 || "$1" == -* ]]; then
  sed -n '2,26p' "$0"
  exit 2
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
sha="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
exec python3 "$repo_root/scripts/cmux-next/bench_cli_storm.py" --repo-root "$repo_root" --sha "$sha" --tag "$@"
