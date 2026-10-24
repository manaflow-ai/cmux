#!/usr/bin/env bash
# Run a fleet cmux-next DEV build in disposable macOS 14 / 15 / 26 Tart VMs on the build fleet,
# on demand. A tool for agents, not a CI gate: it submits one cmux-ci step of class vm
# (scripts/fuzz/macos-matrix/vm.sh on a Tart worker), waits, downloads the results and prints
# the verdict per macOS major.
#
# Usage: scripts/cmux-next/os-matrix.sh --build JOB_ID [--os 14,15] [--suite smoke|fuzz|repro:NAME]
#                                       [--seed N] [--minutes N] [--ref SHA] [--out DIR]
#   --build    a done fleet `cmux` build job (cmux-ci build cmux ...). The smoke needs a DEV build
#              (the release socket refuses debug.* calls). The build may be of any commit.
#   --os       macOS majors, comma-separated, from scripts/fuzz/macos-matrix/images.json
#              (14, 15, 26; default 14,15). One VM at a time; about 3 min per major for the smoke.
#   --suite    smoke (default): launch, window, a terminal that echoes, a split, a Chromium and a
#              WebKit tab that load a page served in the guest, Settings, quit.
#              fuzz: the seeded UI fuzz (fuzz.py) for --minutes (default 15) per major.
#              repro:NAME: replay scripts/fuzz/macos-matrix/repros/NAME.jsonl.
#   --seed     fuzz seed (default 1); the same seed and build repeat the same steps.
#   --ref      the feat-cmux-next commit whose vm.sh runs (default: the current tip). The fleet runs
#              a script only in its reviewed (landed) version.
#   --out      results directory (default artifacts/os-matrix/<build>-<suite>-<UTC>).
# Prints one line per major and "MATRIX VERDICT PASS|FAIL"; exits 0 on PASS, 1 on FAIL, 75 when the
# fleet gave no verdict. Results: <out>/<major>/{result.json|summary.json,app.log,shot-*.png,*.ips,
# *.hang,faults.ndjson,smoke.log|fuzz.log}, <out>/matrix.json and <out>/step.log.
# A VM has a paravirtual GPU and no ProMotion: use it for correctness, crashes, hangs, launch and
# OS-behavior differences, never for frame timing. Label any VM timing "VM, not comparable".
# cmux-unit tests inside the guest are not supported (the base images have no Xcode); see MATRIX.md.
set -euo pipefail

BUILD="" OS=14,15 SUITE=smoke SEED=1 MINUTES=15 REF="" OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=$2; shift 2 ;;
    --os) OS=$2; shift 2 ;;
    --suite) SUITE=$2; shift 2 ;;
    --seed) SEED=$2; shift 2 ;;
    --minutes) MINUTES=$2; shift 2 ;;
    --ref) REF=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --tests) echo "--tests: cmux-unit in the guest is not supported yet (the base images have no Xcode; see scripts/fuzz/macos-matrix/MATRIX.md)" >&2; exit 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ "$BUILD" =~ ^[0-9a-f]{24}$ ]] || { echo "--build needs a 24-character fleet build job id" >&2; exit 2; }
[[ "$OS" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "--os takes majors like 14,15" >&2; exit 2; }
[[ "$SEED" =~ ^[0-9]{1,9}$ ]] || { echo "--seed takes a whole number" >&2; exit 2; }
[[ "$MINUTES" =~ ^[0-9]{1,2}$ && "$MINUTES" -ge 1 && "$MINUTES" -le 60 ]] || { echo "--minutes takes 1..60" >&2; exit 2; }
suite_args=(--suite "${SUITE%%:*}")
case "$SUITE" in
  smoke) ;;
  fuzz) suite_args+=(--seed "$SEED" --minutes "$MINUTES") ;;
  repro:*) suite_args+=(--repro "${SUITE#repro:}") ;;
  *) echo "--suite takes smoke, fuzz or repro:NAME" >&2; exit 2 ;;
esac

CI=${CMUX_CI:-$HOME/.local/bin/cmux-ci}
ROOT=$(git rev-parse --show-toplevel)
if [[ -z "$REF" ]]; then
  git -C "$ROOT" fetch -q origin feat-cmux-next
  REF=$(git -C "$ROOT" rev-parse FETCH_HEAD)
fi
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || { echo "--ref needs a 40-character commit" >&2; exit 2; }
images=$(git -C "$ROOT" show "$REF:scripts/fuzz/macos-matrix/images.json") || {
  echo "no scripts/fuzz/macos-matrix/images.json at $REF" >&2; exit 2; }
# One worker label per major: tart-<first 32 hex of the pinned image digest> (the worker labels
# itself with the images in its Tart cache; a step never pulls an image).
labels=$(python3 -I -c 'import json, sys
pins = {i["major"]: i["digest"] for i in json.loads(sys.argv[1])["images"]}
for m in sys.argv[2].split(","):
    if m not in pins: sys.exit("macOS %s has no pinned image in images.json (have %s)" % (m, ",".join(sorted(pins))))
    print("--label=tart-" + pins[m][len("sha256:"):][:32])' "$images" "$OS")
OUT=${OUT:-$ROOT/artifacts/os-matrix/${BUILD:0:12}-${SUITE//:/-}-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$OUT"
key="os-matrix-${BUILD:0:12}-${REF:0:12}-${OS//,/-}-${SUITE//:/-}"
[[ "$SUITE" == fuzz ]] && key+="-s$SEED-m$MINUTES"
args=(--arg=--build-job "--arg=$BUILD" --arg=--majors "--arg=$OS")
for a in "${suite_args[@]}"; do args+=("--arg=$a"); done
echo "os-matrix: build $BUILD, macOS $OS, suite $SUITE, vm.sh at $REF, key $key" >&2
set +e
# shellcheck disable=SC2086
"$CI" run --class vm --script scripts/fuzz/macos-matrix/vm.sh --ref "$REF" "${args[@]}" $labels --key "$key" 2>&1 \
  | tee "$OUT/step.log"
code=${PIPESTATUS[0]}
set -e
step=$(grep -Eo 'cmux-ci: step [0-9a-f]{24}' "$OUT/step.log" | head -1 | awk '{print $3}')
verdict=$(grep -Eo '^MATRIX VERDICT (PASS|FAIL)' "$OUT/step.log" | tail -1 | awk '{print $3}')
if [[ "$code" != 0 || -z "$step" || -z "$verdict" ]]; then
  echo "os-matrix: no verdict (step ${step:-?} exit $code); the step log is $OUT/step.log" >&2
  [[ -n "$step" ]] && echo "os-matrix: a wait timeout leaves the step running: $CI wait $step (never resubmit)" >&2
  exit 75
fi
"$CI" artifact "$step" "$OUT/results.tgz" >/dev/null
tar -xzf "$OUT/results.tgz" -C "$OUT"
grep -E '^[0-9]+ +' "$OUT/step.log" | grep -E ' (PASS|FAIL) ' || true
echo "results: $OUT"
echo "MATRIX VERDICT $verdict"
[[ "$verdict" == PASS ]]
