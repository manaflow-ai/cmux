#!/usr/bin/env bash
# Run a fleet cmux-next DEV build in disposable macOS 14 / 15 / 26 Tart VMs on the build fleet,
# on demand. A tool for agents, not a CI gate: it submits one cmux-ci step of class vm
# (scripts/fuzz/macos-matrix/vm.sh on a Tart worker), waits, downloads the results and prints
# the verdict per macOS major.
#
# Usage: scripts/cmux-next/os-matrix.sh --build JOB_ID [--os 14,15] [--suite smoke|threads|fuzz|chaos|repro:NAME|exec:NAME]
#                                       [--seed N] [--minutes N] [--diag NAME] [--ref SHA] [--attempt N]
#                                       [--out DIR] [--parallel]
#   --build    a done fleet `cmux` build job (cmux-ci build cmux ...). The smoke needs a DEV build
#              (the release socket refuses debug.* calls). The build may be of any commit.
#   --os       macOS majors, comma-separated, from scripts/fuzz/macos-matrix/images.json
#              (14, 15, 26; default 14,15). One VM at a time; about 3 min per major for the smoke.
#   --suite    smoke (default): launch, window, a terminal that echoes, a split, a Chromium and a
#              WebKit tab that load a page served in the guest, Settings, quit.
#              threads: launch, then debug.pool_context: a Task.detached and a DispatchQueue.global seam
#              call are classified pool, .files and .cpu lane items lane and cpu-lane, debug.blocking lists
#              the pool and cpu-lane sites, a WorkHandle.raise lifts a running item's thread priority; and
#              debug.threads reads every thread (chrome-parity p02-threads RUN-10: run it with --os 14,15).
#              A DEV build of perf/chrome-parity or later; result.json's "labels" has each case's queue label.
#              fuzz: the seeded UI fuzz (fuzz.py) for --minutes (default 15) per major.
#              chaos: one fault at a time during a typing and split tour (chaos.py; DEV build),
#              one result.json row per fault with its expected outcome and ok/FAIL/skip.
#              repro:NAME: replay scripts/fuzz/macos-matrix/repros/NAME.jsonl.
#              exec:NAME: an OS probe, scripts/fuzz/macos-matrix/probes/NAME.swift, compiled on the
#              Tart host from the runner ref and run in each guest (exit 0 PASS, 1 FAIL, else no
#              verdict; its output is in <out>/<major>/result.json). It tests the OS, not the build.
#   --seed     fuzz seed (default 1); the same seed and build repeat the same steps.
#   --diag     fuzz and repro: run the app under a check (gmalloc, scribble, probguard, mtc, coop-strict,
#              asan, tsan, ubsan; scripts/fuzz/macos-matrix/diag.py). summary.json's "diag" records it.
#   --ref      the feat-cmux-next commit whose vm.sh runs (default: the current tip). The fleet runs
#              a script only in its reviewed (landed) version.
#   --attempt  a new step for the same build, ref, majors and suite (default 1): the step key holds
#              it, so the same command re-attaches to its step and --attempt 2 runs it again.
#   --out      results directory (default artifacts/os-matrix/<build>-<suite>-<UTC>).
#   --parallel one step per major, all submitted at once, so each major takes a VM on any Tart host that
#              caches its image (hosts: images.json "hosts"). 27 always needs its own step: no host holds
#              a 14/15/26 image and the 27 image. Per major: <out>/step-<major>/ and <out>/step-<major>.log;
#              <out>/parallel.json has each major's step, exit code and verdict. The same command re-attaches.
# Prints one line per major and "MATRIX VERDICT PASS|FAIL|NO-VERDICT"; exits 0 on PASS, 1 on FAIL, 2 on a
# usage error and 75 when there is no verdict (a refused, failed or unfinished step, or a major without
# one: a VM that did not boot, an exec probe that crashed, timed out or did not compile). Results: <out>/<major>/{result.json|summary.json,app.log,shot-*.png,*.ips,
# *.hang,faults.ndjson,smoke.log|threads.log|fuzz.log}, <out>/matrix.json and <out>/step.log.
# A VM has a paravirtual GPU and no ProMotion: use it for correctness, crashes, hangs, launch and
# OS-behavior differences, never for frame timing. Label any VM timing "VM, not comparable".
# cmux-unit tests inside the guest are not supported (the base images have no Xcode); see MATRIX.md.
set -euo pipefail

BUILD="" OS=14,15 SUITE=smoke SEED=1 MINUTES=15 REF="" OUT="" ATTEMPT=1 DIAG="" PARALLEL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=$2; shift 2 ;;
    --os) OS=$2; shift 2 ;;
    --suite) SUITE=$2; shift 2 ;;
    --seed) SEED=$2; shift 2 ;;
    --minutes) MINUTES=$2; shift 2 ;;
    --diag) DIAG=$2; shift 2 ;;
    --ref) REF=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --attempt) ATTEMPT=$2; shift 2 ;;
    --parallel) PARALLEL=1; shift ;;
    --tests) echo "--tests: cmux-unit in the guest is not supported yet (the base images have no Xcode; see scripts/fuzz/macos-matrix/MATRIX.md)" >&2; exit 2 ;;
    -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
    *) echo "unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ "$BUILD" =~ ^[0-9a-f]{24}$ ]] || { echo "--build needs a 24-character fleet build job id" >&2; exit 2; }
[[ "$OS" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "--os takes majors like 14,15" >&2; exit 2; }
# The controller's grammar: no leading zeros.
[[ "$SEED" =~ ^(0|[1-9][0-9]{0,8})$ ]] || { echo "--seed takes a whole number" >&2; exit 2; }
[[ "$MINUTES" =~ ^([1-9]|[1-5][0-9]|60)$ ]] || { echo "--minutes takes 1..60" >&2; exit 2; }
[[ "$ATTEMPT" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "--attempt takes 1..999" >&2; exit 2; }
suite_args=(--suite "${SUITE%%:*}")
case "$SUITE" in
  smoke|threads|chaos) ;;
  fuzz) suite_args+=(--seed "$SEED" --minutes "$MINUTES") ;;
  repro:*) suite_args+=(--repro "${SUITE#repro:}") ;;
  exec:*) suite_args+=(--probe "${SUITE#exec:}") ;;
  *) echo "--suite takes smoke, threads, fuzz, chaos, repro:NAME or exec:NAME" >&2; exit 2 ;;
esac
if [[ -n "$DIAG" ]]; then
  # vm.sh checks the name against diag.py; this keeps the step key and arguments plain.
  [[ "$DIAG" =~ ^[a-z][a-z-]{1,19}$ ]] || { echo "--diag takes a check name like gmalloc or asan" >&2; exit 2; }
  [[ "$SUITE" == fuzz || "$SUITE" == repro:* ]] || { echo "--diag needs --suite fuzz or repro:NAME" >&2; exit 2; }
  suite_args+=(--diag "$DIAG")
fi

CI=${CMUX_CI:-$HOME/.local/bin/cmux-ci}
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "run os-matrix.sh from a cmux worktree" >&2; exit 2; }
if [[ -z "$REF" ]]; then
  git -C "$ROOT" fetch -q origin feat-cmux-next || { echo "os-matrix: git fetch failed" >&2; exit 75; }
  REF=$(git -C "$ROOT" rev-parse FETCH_HEAD)
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
OUT=${OUT:-$ROOT/artifacts/os-matrix/${BUILD:0:12}-${SUITE//:/-}-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$OUT"
if [[ "$PARALLEL" == 1 && "$OS" == *,* ]]; then
  # One child run per major: each is a plain single-major os-matrix.sh, so its step key is the one
  # `--os <major>` gives and a re-run re-attaches to the same steps.
  IFS=, read -ra majors <<<"$OS"
  pids=()
  for m in "${majors[@]}"; do
    child=(--build "$BUILD" --os "$m" --suite "$SUITE" --seed "$SEED" --minutes "$MINUTES" --ref "$REF"
      --attempt "$ATTEMPT" --out "$OUT/step-$m")
    [[ -z "$DIAG" ]] || child+=(--diag "$DIAG")
    CMUX_CI=$CI bash "${BASH_SOURCE[0]}" "${child[@]}" >"$OUT/step-$m.log" 2>&1 &
    pids+=("$!")
  done
  echo "os-matrix: build $BUILD, macOS $OS, suite $SUITE: ${#majors[@]} steps submitted at once" >&2
  codes=()
  for i in "${!majors[@]}"; do
    code=0
    wait "${pids[$i]}" || code=$?
    codes+=("$code")
  done
  verdict=$(python3 -I -c 'import json, re, sys
out, majors, codes = sys.argv[1], sys.argv[2].split(","), [int(c) for c in sys.argv[3].split(",")]
rows = []
for major, code in zip(majors, codes):
    log = open("%s/step-%s.log" % (out, major), errors="replace").read()
    step = re.search(r"cmux-ci: step ([0-9a-f]{24})", log)
    rows.append({"major": major, "exit": code, "step": step.group(1) if step else "",
                 "verdict": {0: "PASS", 1: "FAIL"}.get(code, "NO-VERDICT"), "results": "step-" + major})
    print("macOS %-3s %-10s step %-24s %s/step-%s.log" % (major, rows[-1]["verdict"], rows[-1]["step"] or "-", out, major),
          file=sys.stderr)
verdicts = [r["verdict"] for r in rows]
overall = "FAIL" if "FAIL" in verdicts else ("NO-VERDICT" if "NO-VERDICT" in verdicts else "PASS")
json.dump({"majors": rows, "verdict": overall}, open(out + "/parallel.json", "w"), indent=1)
print(overall)' "$OUT" "$OS" "$(IFS=,; echo "${codes[*]}")")
  echo "results: $OUT"
  echo "MATRIX VERDICT $verdict"
  case "$verdict" in
    PASS) exit 0 ;;
    FAIL) exit 1 ;;
    *) echo "os-matrix: some major gave no verdict; its step-<major>.log says whether to wait or use --attempt" >&2; exit 75 ;;
  esac
fi
key="os-matrix-${BUILD:0:12}-${REF:0:12}-${OS//,/-}-${SUITE//:/-}-a$ATTEMPT"
[[ "$SUITE" == fuzz ]] && key+="-s$SEED-m$MINUTES"
[[ -z "$DIAG" ]] || key+="-d$DIAG"
args=(--arg=--build-job "--arg=$BUILD" --arg=--majors "--arg=$OS")
for a in "${suite_args[@]}"; do args+=("--arg=$a"); done
echo "os-matrix: build $BUILD, macOS $OS, suite $SUITE, vm.sh at $REF, key $key" >&2
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
