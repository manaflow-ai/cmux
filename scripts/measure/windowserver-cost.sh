#!/usr/bin/env bash
# One reproducible WindowServer/GPU bench for CMUX-887. It builds one tagged optimized app and runs
# idle, typing, spinner, requested native blur materials and many-pane scenarios against fresh launches.
# Reuse this exact checkout for a paired run:
#   ... --app=/path/baseline.app --app-source-sha=FULLSHA --out=/tmp/ws-before
#   ... --app=/path/fixed.app --app-source-sha=FULLSHA --out=/tmp/ws-after
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
scenarios="idle,typing,spinner,glass-blur,many-panes" rounds=1 idle_s=20 tabs=5 samples=40
app="" source_sha="" out="$PWD/artifacts/windowserver-cost"
for arg in "$@"; do
  case "$arg" in
    --scenarios=*) scenarios="${arg#--scenarios=}" ;;
    --rounds=*) rounds="${arg#--rounds=}" ;;
    --idle-s=*) idle_s="${arg#--idle-s=}" ;;
    --tabs=*) tabs="${arg#--tabs=}" ;;
    --samples=*) samples="${arg#--samples=}" ;;
    --app=*) app="${arg#--app=}" ;;
    --app-source-sha=*) source_sha="${arg#--app-source-sha=}" ;;
    --out=*) out="${arg#--out=}" ;;
    *) echo "windowserver-cost: unknown argument $arg" >&2; exit 2 ;;
  esac
done
mkdir -p "$out"
if [[ -z "$app" ]]; then
  tag="windowserver-887"
  source_sha="$(git rev-parse HEAD)"
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config bench --no-global-cli-links 2>&1 | tee "$out/reload.log"
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
elif [[ ! "$source_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "windowserver-cost: --app requires --app-source-sha=FULLSHA from its build receipt" >&2
  exit 2
fi
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "windowserver-cost: app bundle does not exist: $app" >&2
  exit 1
fi
python3 scripts/cmux-next/windowserver-bench.py --app "$app" --app-source-sha "$source_sha" --out "$out/runs" --json "$out/report.json" \
  --scenarios "$scenarios" --rounds "$rounds" --idle-s "$idle_s" --tabs "$tabs" --samples "$samples" --transport-envelope
test -s "$out/report.json" || { echo "windowserver-cost: harness produced no report" >&2; exit 1; }
# Exit success only for artifact transport. The report verdict and failures
# remain authoritative; bench ingestion rejects a failed verdict.
