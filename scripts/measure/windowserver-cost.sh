#!/usr/bin/env bash
# One reproducible WindowServer/GPU bench for CMUX-887. It builds one tagged optimized app and runs
# idle, typing, spinner, see-through glass/blur and many-pane scenarios against fresh launches.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
scenarios="idle,typing,spinner,glass-blur,many-panes" rounds=1 idle_s=20 tabs=5 samples=40
for arg in "$@"; do
  case "$arg" in
    --scenarios=*) scenarios="${arg#--scenarios=}" ;;
    --rounds=*) rounds="${arg#--rounds=}" ;;
    --idle-s=*) idle_s="${arg#--idle-s=}" ;;
    --tabs=*) tabs="${arg#--tabs=}" ;;
    --samples=*) samples="${arg#--samples=}" ;;
    *) echo "windowserver-cost: unknown argument $arg" >&2; exit 2 ;;
  esac
done
out="$PWD/artifacts/windowserver-cost"
mkdir -p "$out"
tag="windowserver-887"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config bench --no-global-cli-links 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "windowserver-cost: the tagged reload printed no app path" >&2
  exit 1
fi
status=0
python3 scripts/cmux-next/windowserver-bench.py --app "$app" --out "$out/runs" --json "$out/report.json" \
  --scenarios "$scenarios" --rounds "$rounds" --idle-s "$idle_s" --tabs "$tabs" --samples "$samples" || status=$?
test -s "$out/report.json" || { echo "windowserver-cost: harness produced no report" >&2; exit 1; }
exit "$status"
