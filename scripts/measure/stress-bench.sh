#!/usr/bin/env bash
# One-command multi-angle cmux NEXT stress bench on an exclusive GUI fleet Mac.
#
#   cmux-ci run --class exclusive --measurement --display \
#     --script scripts/measure/stress-bench.sh --ref SHA \
#     --artifact artifacts/stress-bench/stress-bench.json
#
# The app is built once with the bench configuration. The Python driver launches
# that tagged app, runs every short ramp, and writes one JSON file per ramp plus
# stress-bench.json and stress-bench.md.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

tag="stress-bench"; config="bench"; duration="1"; scenarios=""
for arg in "$@"; do
  case "$arg" in
    --tag=*) tag="${arg#--tag=}" ;;
    --config=*) config="${arg#--config=}" ;;
    --duration=*) duration="${arg#--duration=}" ;;
    --scenarios=*) scenarios="${arg#--scenarios=}" ;;
    --scenario=*) scenarios="${arg#--scenario=}" ;;
    --*) echo "stress-bench: unknown option $arg" >&2; exit 2 ;;
  esac
done

out="$(pwd)/artifacts/stress-bench"
mkdir -p "$out"
scratch="$(mktemp -d)"
reload_log="$scratch/reload.log"
cleanup() {
  python3 scripts/cmux-next/tag_teardown.py "$app" >/dev/null 2>&1 || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT INT TERM HUP
app=""

for sub in ghostty ghostty-next; do
  [[ -e "$sub/.git" ]] || git submodule update --init --depth 1 "$sub"
done
if [[ ! -f GhosttyKit.xcframework/Info.plist ]]; then
  ./scripts/download-prebuilt-ghosttykit.sh
fi
echo "stress-bench: building tagged app ($tag, $config)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config "$config" >"$reload_log" 2>&1
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$reload_log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  tail -n 80 "$reload_log" >&2
  exit 1
fi

args=(--app "$app" --out "$out" --duration "$duration")
[[ -n "$scenarios" ]] && args+=(--scenarios "$scenarios")
python3 scripts/cmux-next/stress-bench.py "${args[@]}"
echo "stress-bench: report $out/stress-bench.json"
cat "$out/stress-bench.md"
