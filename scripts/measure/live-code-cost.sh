#!/usr/bin/env bash
# What a live code build costs while it runs (docs/cmux-next/live-code.md), on one fleet Mac: the same
# commit built twice in the bench configuration, A a regular build (scripts/reload.sh) and B a live code
# build (scripts/live-code/build.sh: CmuxNextApp at -Onone, a file at a time, its calls through
# interposable pointers), each in its own tag and DerivedData. Then the instant-create bench
# (scripts/cmux-next/instant-new-surfaces-bench.py: key to visible frame, idle and under load) runs
# against each app in turn, A B / B A / ..., one launch per run, so both arms see the same Mac state.
# Neither app watches a live folder: this is the build's own cost, which Labs > Live Code off does not
# remove (cmux#36505).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/live-code-cost.sh \
#     --ref SHA --artifact artifacts/live-code-cost/result.json [--arg=rounds=4] [--arg=--runs=12] ...
# rounds=N (default 4) pairs of runs; every other argument goes to the bench. Output in
# artifacts/live-code-cost: each run's JSON (bench_ab.py's names: before = regular, after = live code),
# result.json (build seconds, sizes, the bench_ab comparison) and REPORT.md, also printed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
rounds=4 bench_args=()
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    *) bench_args+=("$arg") ;;
  esac
done
# A fleet checkout has no submodules or GhosttyKit yet (as scripts/measure/live-code-app.sh).
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
sha="$(git rev-parse HEAD)"
out="artifacts/live-code-cost"
work="$(mktemp -d)"
rm -rf "$out" && mkdir -p "$out"
regular_tag="livecost-regular" live_tag="livecost-live"

start=$SECONDS
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$regular_tag" --config bench 2>&1 | tee "$work/regular.log" >&2 || true
regular_s=$((SECONDS - start))
regular_app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/regular.log" | tail -n 1)"
if [[ -z "$regular_app" || ! -d "$regular_app" ]]; then
  echo "live-code-cost: the regular build printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$work/regular.log" | head -n 60 >&2 || true
  exit 1
fi
start=$SECONDS
live_app="$(scripts/live-code/build.sh "$work/live" "$live_tag" bench CMUX_DEV_BACKEND_MODE=local | tail -n 1)"
live_s=$((SECONDS - start))
[[ -n "$live_app" && -d "$live_app" ]] || { echo "live-code-cost: the live code build printed no app path" >&2; exit 1; }

bench() { # TAG APP ARM ROUND
  local json="$out/bench-instant-r$4-$3-${sha:0:8}.json"
  python3 scripts/cmux-next/instant-new-surfaces-bench.py --tag "$1" --app "$2" --out "$work" --json "$json" \
    ${bench_args[@]+"${bench_args[@]}"} || echo "live-code-cost: round $4 $3 exited non-zero" >&2
}
for ((round = 1; round <= rounds; round++)); do
  if ((round % 2)); then
    bench "$regular_tag" "$regular_app" before "$round"; bench "$live_tag" "$live_app" after "$round"
  else
    bench "$live_tag" "$live_app" after "$round"; bench "$regular_tag" "$regular_app" before "$round"
  fi
done
python3 scripts/measure/live-code-cost.py --out "$out" --sha "$sha" \
  --regular-app "$regular_app" --regular-build-s "$regular_s" --live-app "$live_app" --live-build-s "$live_s"
