#!/usr/bin/env bash
# The diff tab of a large diff, in the app, at two commits on one Mac: the code view's open, Plain English's first
# paint, and the frame times of a rAF-driven scroll of the Plain English view (scripts/cmux-next/diff-page-frames.py
# has what each number is). Each arm is a tagged bench app (Release optimization with the debug.* control methods)
# built at its commit with that commit's own reload.sh (scripts/measure/app-at-commit.sh), requiring Chromium, the
# default engine of the diff page; this checkout's driver runs against both, interleaved (base, head, head, base,
# ...), each run in a scratch home with the same scratch repository.
#   cmux-ci run --class exclusive --display --label measure --script scripts/measure/diff-page-frames.sh \
#     --ref <a feat-cmux-next commit with this script> --arg=base=<sha> --arg=head=<sha> [--arg=rounds=1] \
#     [--arg=files=90] [--arg=lines=1250] [--arg=frames=600] [--arg=step=120] [--arg=passes=2] [--arg=clip=18] \
#     --artifact artifacts/diff-page-frames.tgz --timeout 14400
#   base=SHA, head=SHA  the two commits (40 hex)
#   rounds=N            runs per arm (default 1, at most 6), in ABBA order
#   files=N, lines=N    the repository: N files of N lines, every 10th line changed (90 x 1250: 11,250 hunks,
#                       101,610 lines of `git diff`)
#   frames=N, step=PX, passes=N  each scroll pass: N animation frames, PX pixels each (default 600, 120, 2 passes)
#   clip=S              a screen recording of S seconds (0: none) from just before the first pass of the head arm's
#                       first run, clip-head.mov in the report
# Prints DIFF-FRAMES lines per run and, at the end:
#   DIFF-FRAMES summary <arm> code_open_ms <ms...> pe_paint_ms <ms...> pass<k> p50/p95/p99/max <...> over50 <n>
# The report artifacts/diff-page-frames.tgz holds each run's JSON (every frame interval), the build logs and the clip.
# Exit 0 every run measured, 1 a run failed, 3 an arm did not build.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
. scripts/measure/app-at-commit.sh
here="$PWD"
base="" head="" rounds=1 files=90 lines=1250 frames=600 step=120 passes=2 clip=18
for arg in "$@"; do
  case "$arg" in
    base=*) base="${arg#base=}" ;;
    head=*) head="${arg#head=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    files=*) files="${arg#files=}" ;;
    lines=*) lines="${arg#lines=}" ;;
    frames=*) frames="${arg#frames=}" ;;
    step=*) step="${arg#step=}" ;;
    passes=*) passes="${arg#passes=}" ;;
    clip=*) clip="${arg#clip=}" ;;
    *) echo "diff-page-frames.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "base= and head= must be 40-hex commits" >&2; exit 2; }
for n in "$rounds" "$files" "$lines" "$frames" "$step" "$passes" "$clip"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "diff-page-frames.sh: numbers only: $n" >&2; exit 2; }
done
(( rounds >= 1 && rounds <= 6 )) || { echo "rounds= must be 1 to 6" >&2; exit 2; }
out="$here/artifacts/diff-page-frames"
report="$here/artifacts/diff-page-frames.tgz"
rm -rf "$out" "$report" && mkdir -p "$out/runs"
scratch="$(mktemp -d)"
app_base="" app_head=""
# shellcheck disable=SC2317,SC2329 # run by the EXIT trap
cleanup() {
  for a in "$app_base" "$app_head"; do
    [ -n "$a" ] && [ -d "$a" ] && python3 scripts/cmux-next/tag_teardown.py "$a" >/dev/null 2>&1
  done
  measure_remove_scratch "$scratch"
}
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
trap cleanup EXIT

# The account's tools after the step's own (steps run with a per-step HOME), as perf-idle-ab.sh.
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin" "$account_home/.cargo/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$PATH:$tool_dir"
done
if [ -n "$account_home" ]; then
  [ -z "${RUSTUP_HOME:-}" ] && [ -d "$account_home/.rustup" ] && export RUSTUP_HOME="$account_home/.rustup"
  [ -z "${CARGO_HOME:-}" ] && [ -d "$account_home/.cargo" ] && export CARGO_HOME="$account_home/.cargo"
fi
# The bun webviews/package.json pins, first on PATH (a host's ~/.bun may hold another).
if RUNNER_TEMP="$scratch" GITHUB_PATH="$scratch/bun-path" ./scripts/cmux-next/private-bun.sh; then
  bun_dir="$(tail -n 1 "$scratch/bun-path")"
  export PATH="$bun_dir:$PATH"
fi

build_arm() {  # build_arm ARM SHA
  local arm="$1" sha="$2" app
  app="$(CMUX_NEXT_REQUIRE_CEF=1 measure_app_at_commit "$sha" "dpf$arm" "$scratch/tree-$arm" --config bench \
    --no-global-cli-links 2> >(tee "$out/build-$arm.log" >&2))" || return 3
  [[ -n "$app" && -d "$app" ]] || return 3
  eval "app_$arm=\"\$app\""
  echo "DIFF-FRAMES built $arm $sha $app"
}
build_arm base "$base" || { echo "DIFF-FRAMES the base arm did not build" >&2; exit 3; }
build_arm head "$head" || { echo "DIFF-FRAMES the head arm did not build" >&2; exit 3; }

status=0
clip_taken=false
run_arm() {  # run_arm ARM ROUND
  local arm="$1" i="$2" app clip_args=()
  if [ "$arm" = base ]; then app="$app_base"; else app="$app_head"; fi
  if [ "$arm" = head ] && ! $clip_taken && (( clip > 0 )); then
    clip_args=(--clip "$out/clip-head.mov" --clip-seconds "$clip")
    clip_taken=true
  fi
  echo "DIFF-FRAMES round $i $arm load $(uptime | sed 's/.*load averages*: //')"
  CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/diff-page-frames.py --app "$app" --label "$arm-$i" \
    --json "$out/runs/$arm-$i.json" --files "$files" --lines "$lines" --frames "$frames" --step "$step" \
    --passes "$passes" ${clip_args[@]+"${clip_args[@]}"} || status=1
  python3 scripts/cmux-next/tag_teardown.py "$app" >/dev/null 2>&1
}
for i in $(seq 1 "$rounds"); do
  if (( i % 2 )); then run_arm base "$i"; run_arm head "$i"; else run_arm head "$i"; run_arm base "$i"; fi
done

python3 -I - "$out/runs" <<'PY' || status=1
import glob, json, os, sys
rows = {}
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    data = json.load(open(path))
    arm = os.path.basename(path).split("-")[0]
    row = rows.setdefault(arm, {"code": [], "paint": [], "passes": {}})
    row["code"].append((data.get("code_view") or {}).get("open_to_first_file_header_ms"))
    row["paint"].append((data.get("plain_english") or {}).get("click_to_paint_ms"))
    for p in data.get("passes") or []:
        row["passes"].setdefault(p.get("index"), []).append(
            "/".join(str(p.get(k)) for k in ("p50", "p95", "p99", "max")) + f" over50 {p.get('over_50ms')}")
for arm, row in sorted(rows.items()):
    passes = " ".join(f"pass{k} {' | '.join(v)}" for k, v in sorted(row["passes"].items()))
    print(f"DIFF-FRAMES summary {arm} code_open_ms {row['code']} pe_paint_ms {row['paint']} {passes}")
PY
echo "DIFF-FRAMES verdict exit $status base $base head $head rounds $rounds"
tar -czf "$scratch/report.tgz" -C "$out" . 2>/dev/null && mv "$scratch/report.tgz" "$report"
exit $status
