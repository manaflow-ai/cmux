#!/usr/bin/env bash
set -euo pipefail

tag="chief-memory"
out="artifacts/chief-memory"
config="bench"
minutes=10
sample_seconds=60

for arg in "$@"; do
  case "$arg" in
    tag=*) tag="${arg#tag=}" ;;
    out=*) out="${arg#out=}" ;;
    config=*) config="${arg#config=}" ;;
    minutes=*) minutes="${arg#minutes=}" ;;
    sample_seconds=*) sample_seconds="${arg#sample_seconds=}" ;;
    *) echo "chief-memory.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done

[[ "$tag" =~ ^[a-z0-9-]{1,40}$ ]] || { echo "chief-memory.sh: tag must be lowercase letters, digits and dashes" >&2; exit 2; }
[[ "$config" == debug || "$config" == bench ]] || { echo "chief-memory.sh: config must be debug or bench" >&2; exit 2; }
[[ "$minutes" =~ ^[1-9][0-9]*$ ]] || { echo "chief-memory.sh: minutes must be positive" >&2; exit 2; }
[[ "$sample_seconds" =~ ^[1-9][0-9]*$ ]] || { echo "chief-memory.sh: sample_seconds must be positive" >&2; exit 2; }

cd "$(git rev-parse --show-toplevel)"
mkdir -p "$out"
rm -f "$out/report.json" "$out/log.txt"

CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config "$config" 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "chief-memory.sh: reload printed no app path" >&2; exit 1; }

python3 scripts/cmux-next/chief-memory-bench.py \
  --app "$app" \
  --minutes "$minutes" \
  --sample-seconds "$sample_seconds" \
  --out "$out/report.json" \
  2>&1 | tee "$out/log.txt"
