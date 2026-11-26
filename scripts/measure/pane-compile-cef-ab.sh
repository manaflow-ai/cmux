#!/usr/bin/env bash
# Both arms of a pane-compile A/B in one fleet step, so one Mac and one harness measure both: builds the app at
# --before=SHA and at --after=SHA (scripts/measure/app-at-commit.sh), runs pane-compile-cef.py on each in turn
# (after, before, after, before when --rounds=2), and writes artifacts/pane-compile-cef-ab/ab.json with each arm's
# medians. Two separate pane-compile-cef.sh steps can land on two Macs, whose numbers do not compare.
#   cmux-ci run --class exclusive --measurement --label measure --display --script scripts/measure/pane-compile-cef-ab.sh \
#     --ref <sha> --arg=--before=<sha> --arg=--after=<sha> [--arg=--runs=5] [--arg=--rounds=2] \
#     --artifact artifacts/pane-compile-cef-ab/ab.json
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/measure/app-at-commit.sh
out="$(pwd)/artifacts/pane-compile-cef-ab"
mkdir -p "$out"
scratch="$(mktemp -d)"
trap 'measure_remove_scratch "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
before="" after="" rounds=1 bench_args=()
for arg in "$@"; do
  case "$arg" in
    --before=*) before="${arg#--before=}" ;;
    --after=*) after="${arg#--after=}" ;;
    --rounds=*) rounds="${arg#--rounds=}" ;;
    *) bench_args+=("$arg") ;;
  esac
done
if [[ -z "$before" || -z "$after" ]]; then
  echo "pane-compile-cef-ab: needs --before=SHA and --after=SHA" >&2
  exit 2
fi
# Both apps are built first, so the measured rounds run back to back on a Mac no build is loading.
app_before="$(CMUX_NEXT_REQUIRE_CEF=1 measure_app_at_commit "$before" panecompa "$scratch/before")"
app_after="$(CMUX_NEXT_REQUIRE_CEF=1 measure_app_at_commit "$after" panecompb "$scratch/after")"
for app in "$app_before" "$app_after"; do
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "pane-compile-cef-ab: a build printed no app path" >&2
    exit 1
  fi
done
for ((round = 0; round < rounds; round++)); do
  for arm in after before; do
    app="$app_before"
    [[ "$arm" == after ]] && app="$app_after"
    python3 scripts/measure/pane-compile-cef.py --app "$app" --out "$out/$arm-$round" \
      ${bench_args[@]+"${bench_args[@]}"}
  done
done
python3 - "$out" "$before" "$after" <<'PY'
import glob, json, os, statistics, sys
out, before, after = sys.argv[1:4]
summary = {"before": {"sha": before}, "after": {"sha": after}, "host": os.uname().nodename}
for arm in ("before", "after"):
    runs = []
    for path in sorted(glob.glob(os.path.join(out, f"{arm}-*", "runs.json"))):
        with open(path) as f:
            runs.extend(json.load(f))
    summary[arm]["n"] = len(runs)
    keys = sorted({k for r in runs for k, v in r.items() if isinstance(v, (int, float)) and not isinstance(v, bool)})
    summary[arm]["median"] = {k: statistics.median(r[k] for r in runs if isinstance(r.get(k), (int, float))) for k in keys}
    summary[arm]["runs"] = runs
with open(os.path.join(out, "ab.json"), "w") as f:
    json.dump(summary, f, indent=1)
for arm in ("before", "after"):
    print(f"PANE-COMPILE-AB {arm} {summary[arm]['sha'][:12]} n={summary[arm]['n']} {json.dumps(summary[arm]['median'])}")
PY
