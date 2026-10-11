#!/usr/bin/env bash
# Usage: scripts/blacksmith-testbox-release.sh <tbx_id> [wait-seconds]
#
# Ends your Testbox so its warm cmux-tui target dir is committed as the shared
# sticky disk `cmux-tui-target-v1` for the next box. Use it instead of
# `blacksmith testbox stop`: stop destroys the VM before the warmup job's post
# steps run, so nothing is committed on that path.
#
# It writes the keepalive's release marker on the box, then waits for the
# warmup run to finish (prune, then the sticky disk commit). If the run is not
# finished after [wait-seconds] (default 600), it falls back to
# `blacksmith testbox stop`, so a box never outlives this command.
# Run it from the same cmux worktree root as your other `testbox run` commands.
set -euo pipefail

tbx="${1:?usage: $0 <tbx_id> [wait-seconds]}"
wait_seconds="${2:-600}"
[[ "$tbx" =~ ^tbx_[A-Za-z0-9_-]+$ ]] || { echo "malformed Testbox ID: $tbx" >&2; exit 2; }
[[ "$wait_seconds" =~ ^[0-9]+$ ]] || { echo "wait-seconds must be an integer" >&2; exit 2; }

run_url="$(blacksmith testbox status --id "$tbx" 2>/dev/null | grep -Eo 'https://github.com/[^ ]+/actions/runs/[0-9]+' | head -n 1 || true)"
run_id="${run_url##*/}"

stop_box() {
  echo "release: falling back to blacksmith testbox stop --id $tbx (no sticky disk commit)" >&2
  blacksmith testbox stop --id "$tbx"
}

# shellcheck disable=SC2016 # $HOME expands on the box, not here.
if ! blacksmith testbox run --id "$tbx" 'touch "$HOME/.testbox-release"'; then
  echo "release: could not write the release marker on $tbx" >&2
  stop_box
  exit 1
fi
echo "release: marker written on $tbx; the keepalive prunes target/ and exits within ~30 s"

if [[ ! "$run_id" =~ ^[0-9]+$ ]]; then
  echo "release: no warmup run URL for $tbx; not waiting for the commit" >&2
  exit 0
fi
deadline=$((SECONDS + wait_seconds))
while (( SECONDS < deadline )); do
  state="$(gh run view "$run_id" --repo manaflow-ai/cmux --json status,conclusion --jq '.status + " " + .conclusion' 2>/dev/null || true)"
  case "$state" in
    "completed success")
      echo "release: run $run_id succeeded; the warm target dir commit is requested and lands when the VM shuts down"
      exit 0
      ;;
    completed*)
      echo "release: run $run_id ended ($state); nothing was committed" >&2
      exit 1
      ;;
  esac
  sleep 15
done
echo "release: run $run_id did not finish within ${wait_seconds}s" >&2
stop_box
exit 1
