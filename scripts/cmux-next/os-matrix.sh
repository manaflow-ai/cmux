#!/usr/bin/env bash
# Run a fleet cmux-next DEV build in disposable macOS 14 / 15 / 26 Tart VMs on the build fleet,
# on demand. A tool for agents, not a CI gate: it submits one cmux-ci step of class vm
# (scripts/fuzz/macos-matrix/vm.sh on a Tart worker), waits, downloads the results and prints
# the verdict per macOS major.
#
# Usage: scripts/cmux-next/os-matrix.sh --build JOB_ID [--os 14,15] [--suite smoke|fuzz|repro:NAME|exec:NAME]
#                                       [--seed N] [--minutes N] [--ref SHA] [--attempt N] [--out DIR]
#   --build    a done fleet `cmux` build job (cmux-ci build cmux ...). The smoke needs a DEV build
#              (the release socket refuses debug.* calls). The build may be of any commit.
#   --nightly  newest or a NIGHTLY feed build number, in place of --build: the onboarding suite only
#              (vm.sh downloads that DMG from the feed on the Tart host).
#   --os       macOS majors, comma-separated, from scripts/fuzz/macos-matrix/images.json
#              (14, 15, 26; default 14,15). One VM at a time; about 3 min per major for the smoke.
#   --suite    smoke (default): launch, window, a terminal that echoes, a split, a Chromium and a
#              WebKit tab that load a page served in the guest, Settings, quit.
#              fuzz: the seeded UI fuzz (fuzz.py) for --minutes (default 15) per major.
#              repro:NAME: replay scripts/fuzz/macos-matrix/repros/NAME.jsonl.
#              onboarding: scoreboard row ON1 (cmuxterm-hq#7146): install the NIGHTLY from its DMG and
#              turn on Computer Use through cmux's own window and System Settings, over VNC only,
#              then a scripted agent clicks, types and drags in background apps; a video and a still
#              per step (onboarding.mp4, shot-*.png) and the person's action count against the reference.
#              exec:NAME: an OS probe, scripts/fuzz/macos-matrix/probes/NAME.swift, compiled on the
#              Tart host from the runner ref and run in each guest (exit 0 PASS, 1 FAIL, else no
#              verdict; its output is in <out>/<major>/result.json). It tests the OS, not the build.
#   --seed     fuzz seed (default 1); the same seed and build repeat the same steps.
#   --ref      the feat-cmux-next commit whose vm.sh runs (default: the current tip). The fleet runs
#              a script only in its reviewed (landed) version.
#   --attempt  a new step for the same build, ref, majors and suite (default 1): the step key holds
#              it, so the same command re-attaches to its step and --attempt 2 runs it again.
#   --out      results directory (default artifacts/os-matrix/<build>-<suite>-<UTC>).
# Prints one line per major and "MATRIX VERDICT PASS|FAIL|NO-VERDICT"; exits 0 on PASS, 1 on FAIL, 2 on a
# usage error and 75 when there is no verdict (a refused, failed or unfinished step, or a major without
# one: a VM that did not boot, an exec probe that crashed, timed out or did not compile). Results: <out>/<major>/{result.json|summary.json,app.log,shot-*.png,*.ips,
# *.hang,faults.ndjson,smoke.log|fuzz.log}, <out>/matrix.json and <out>/step.log.
# A VM has a paravirtual GPU and no ProMotion: use it for correctness, crashes, hangs, launch and
# OS-behavior differences, never for frame timing. Label any VM timing "VM, not comparable".
# cmux-unit tests inside the guest are not supported (the base images have no Xcode); see MATRIX.md.
set -euo pipefail

BUILD="" NIGHTLY="" OS=14,15 SUITE=smoke SEED=1 MINUTES=15 REF="" OUT="" ATTEMPT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=$2; shift 2 ;;
    --nightly) NIGHTLY=$2; shift 2 ;;
    --os) OS=$2; shift 2 ;;
    --suite) SUITE=$2; shift 2 ;;
    --seed) SEED=$2; shift 2 ;;
    --minutes) MINUTES=$2; shift 2 ;;
    --ref) REF=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --attempt) ATTEMPT=$2; shift 2 ;;
    --tests) echo "--tests: cmux-unit in the guest is not supported yet (the base images have no Xcode; see scripts/fuzz/macos-matrix/MATRIX.md)" >&2; exit 2 ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
if [[ "$SUITE" == onboarding ]]; then
  [[ -z "$BUILD" && "$NIGHTLY" =~ ^(newest|[0-9]{1,20})$ ]] || { echo "--suite onboarding takes --nightly newest|BUILD, not --build" >&2; exit 2; }
else
  [[ -z "$NIGHTLY" ]] || { echo "--nightly goes only with --suite onboarding" >&2; exit 2; }
  [[ "$BUILD" =~ ^[0-9a-f]{24}$ ]] || { echo "--build needs a 24-character fleet build job id" >&2; exit 2; }
fi
[[ "$OS" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "--os takes majors like 14,15" >&2; exit 2; }
# The controller's grammar: no leading zeros.
[[ "$SEED" =~ ^(0|[1-9][0-9]{0,8})$ ]] || { echo "--seed takes a whole number" >&2; exit 2; }
[[ "$MINUTES" =~ ^([1-9]|[1-5][0-9]|60)$ ]] || { echo "--minutes takes 1..60" >&2; exit 2; }
[[ "$ATTEMPT" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "--attempt takes 1..999" >&2; exit 2; }
suite_args=(--suite "${SUITE%%:*}")
case "$SUITE" in
  smoke|onboarding) ;;
  fuzz) suite_args+=(--seed "$SEED" --minutes "$MINUTES") ;;
  repro:*) suite_args+=(--repro "${SUITE#repro:}") ;;
  exec:*) suite_args+=(--probe "${SUITE#exec:}") ;;
  *) echo "--suite takes smoke, fuzz, repro:NAME, exec:NAME or onboarding" >&2; exit 2 ;;
esac

CI=${CMUX_CI:-$HOME/.local/bin/cmux-ci}
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "run os-matrix.sh from a cmux worktree" >&2; exit 2; }
if [[ -z "$REF" ]]; then
  # The tip without a write to the clone: other runs and agents share it, and a ref, FETCH_HEAD or
  # maintenance lock held by their fetch failed a `git fetch origin feat-cmux-next` here (exit 75),
  # and a FETCH_HEAD read after it could name their commit. ls-remote reads the sha only; the fetch
  # of that exact sha, only when its commit is missing, writes objects and no ref or FETCH_HEAD. It
  # does not go into submodules (on-demand recursion fetches there and writes their refs when the
  # tip moves a submodule pointer) or follow tags (a tagOpt=--tags config would write refs/tags).
  REF=$(git -C "$ROOT" ls-remote --heads origin feat-cmux-next \
    | awk '$2 == "refs/heads/feat-cmux-next" {print $1; exit}') || REF=""
  [[ "$REF" =~ ^[0-9a-f]{40}$ ]] || { echo "os-matrix: cannot read the feat-cmux-next tip from origin" >&2; exit 75; }
  git -C "$ROOT" cat-file -e "$REF^{commit}" 2>/dev/null \
    || git -C "$ROOT" fetch -q --no-write-fetch-head --no-auto-maintenance --no-recurse-submodules --no-tags \
      origin "$REF" \
    || { echo "os-matrix: cannot fetch $REF from origin" >&2; exit 75; }
fi
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || { echo "--ref needs a 40-character commit" >&2; exit 2; }
images=$(git -C "$ROOT" show "$REF:scripts/fuzz/macos-matrix/images.json") || {
  echo "no scripts/fuzz/macos-matrix/images.json at $REF" >&2; exit 2; }
# One worker label per major: tart-<first 32 hex of the pinned image digest> (the worker labels
# itself with the images in its Tart cache; a step never pulls an image).
labels=$(python3 -I -c 'import json, sys
pins = {i["major"]: i["digest"] for i in json.loads(sys.argv[1])["images"]}
majors = sys.argv[2].split(",")
if len(set(majors)) != len(majors): sys.exit("--os names a major twice")
for m in majors:
    if m not in pins: sys.exit("macOS %s has no pinned image in images.json (have %s)" % (m, ",".join(sorted(pins))))
    print("--label=tart-" + pins[m][len("sha256:"):][:32])' "$images" "$OS") || exit 2
if [[ "$NIGHTLY" == newest ]]; then
  # The step key names the build: a key for "newest" would return yesterday's step tomorrow.
  NIGHTLY=$(python3 -I "$ROOT/scripts/fuzz/macos-matrix/onboarding/nightly.py" --resolve) || { echo "os-matrix: cannot read the NIGHTLY feed" >&2; exit 75; }
fi
what=${BUILD:0:12}; [[ -n "$NIGHTLY" ]] && what="nightly-$NIGHTLY"
OUT=${OUT:-$ROOT/artifacts/os-matrix/$what-${SUITE//:/-}-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$OUT"
key="os-matrix-$what-${REF:0:12}-${OS//,/-}-${SUITE//:/-}-a$ATTEMPT"
[[ "$SUITE" == fuzz ]] && key+="-s$SEED-m$MINUTES"
if [[ -n "$NIGHTLY" ]]; then args=(--arg=--nightly "--arg=$NIGHTLY"); else args=(--arg=--build-job "--arg=$BUILD"); fi
args+=(--arg=--majors "--arg=$OS")
for a in "${suite_args[@]}"; do args+=("--arg=$a"); done
echo "os-matrix: build ${BUILD:-NIGHTLY $NIGHTLY}, macOS $OS, suite $SUITE, vm.sh at $REF, key $key" >&2
set +e
# shellcheck disable=SC2086
"$CI" run --class vm --script scripts/fuzz/macos-matrix/vm.sh --ref "$REF" "${args[@]}" $labels --key "$key" 2>&1 \
  | tee "$OUT/step.log"
code=${PIPESTATUS[0]}
set -e
# grep finds nothing in exactly the no-verdict cases: never let that end the script under set -e.
step=$(grep -Eo 'cmux-ci: step [0-9a-f]{24}' "$OUT/step.log" | head -1 | awk '{print $3}' || true)
verdict=$(grep -Eo '^MATRIX VERDICT (PASS|FAIL|NO-VERDICT)' "$OUT/step.log" | tail -1 | awk '{print $3}' || true)
if [[ "$code" != 0 || -z "$step" || -z "$verdict" ]]; then
  echo "os-matrix: no verdict (step ${step:-not created}, cmux-ci exit $code); the log is $OUT/step.log" >&2
  if [[ -n "$step" ]]; then
    echo "os-matrix: if the step still runs, wait for it: $CI wait $step (never resubmit); to run it again: --attempt $((ATTEMPT + 1))" >&2
  fi
  exit 75
fi
if ! "$CI" artifact "$step" "$OUT/results.tgz" >/dev/null || ! tar -xzf "$OUT/results.tgz" -C "$OUT"; then
  echo "os-matrix: step $step gave MATRIX VERDICT $verdict, but its results did not download: $CI artifact $step OUT.tgz" >&2
  exit 75
fi
grep -E '^EXEC |^[0-9]+ +[0-9.?]+ +[a-z]+ +(PASS|FAIL|NO-VERDICT)' "$OUT/step.log" || true
echo "results: $OUT"
echo "MATRIX VERDICT $verdict"
case "$verdict" in
  PASS) exit 0 ;;
  FAIL) exit 1 ;;
  *) echo "os-matrix: some major gave no verdict (see <out>/<major>/failure and result.json)" >&2; exit 75 ;;
esac
