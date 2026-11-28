#!/usr/bin/env bash
# A pull request's ci-guards.yml steps that its paths reach, judged against the base: ci/steps.toml's
# `guard-steps-reached` step (pr-pipeline.yml's linux job, on the merge commit).
#
#   scripts/ci/guards_reached.sh [BASE]     BASE defaults to HEAD^1 (the merge commit's first parent)
#
# cmux-next-guards.yml's guard jobs (CI guard group, release-notary guards at the tip, tooling-tests) skip a pull
# request into feat-cmux-next: the land tier, the cheap draft tier and CI_GUARD_GROUP_ON_FULL_CI (#59722, 28,593
# runner-min in four days) leave them to the push. So a pull request that broke a guard merged green and the push
# after it went red: 58 + 9 + 2 steps on run 46134168061 (11-28), e.g. #64245 (bench-baselines-nightly.yml),
# #64168 and #63625 (cmux-next-hot-verify.yml), #63940, all four with every guard job skipped.
#
# This runs only the steps guard_step_inputs.py finds the diff reaching through the files they name ("reached by
# ..."), not the steps whose inputs it cannot read ("always: ...", about 470 of 630): those stay with the push and
# the hourly full tier, so a pull request pays for the guards its change can turn red and no more. A step red on
# the head is run again on the base (a worktree of BASE, the head's runner: --root), and only a red the base passes
# fails (guards_new_reds.py), so a base red is never the change's.
#
# Both passes run under --deadline inside GUARDS_REACHED_BUDGET (default 780 s, under ci/steps.toml's 900 s
# timeout): #64828 (93 steps) and #65237 (132 steps) ran past 900 s and the step runner killed the whole step with
# no verdict and no name for the slow guard (11-28). Cut at the deadline, the steps that finished are judged, the
# ones still running are named, and the unfinished ones stay with the push like the "always:" steps.
set -euo pipefail
budget="${GUARDS_REACHED_BUDGET:-780}"
started=$SECONDS

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
base="${1:-HEAD^1}"
base_sha="$(git rev-parse --verify "$base^{commit}" 2>/dev/null)" || {
  echo "no base commit $base: nothing to compare against; the push runs the guards"
  exit 0
}
tmp="$(mktemp -d)"
cleanup() {
  git worktree remove --force "$tmp/base" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

python3 scripts/ci/guard_step_inputs.py --base "$base_sha" --head HEAD --json > "$tmp/plan.json"
python3 - "$tmp/plan.json" > "$tmp/reached.txt" <<'EOF'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
for step, why in plan["run"].items():
    if why.startswith("reached by "):
        print(step)
EOF
count="$(grep -c . "$tmp/reached.txt" || true)"
if [ "$count" -eq 0 ]; then
  echo "the change reaches no ci-guards.yml step by the files it names; the push runs the rest"
  exit 0
fi
echo "the change reaches $count ci-guards.yml steps by the files they name:"
sed 's/^/  /' "$tmp/reached.txt"

steps=()
while IFS= read -r step; do
  [ -n "$step" ] && steps+=(--step "$step")
done < "$tmp/reached.txt"
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
# The head pass gets two thirds of what is left; a base re-run needs the rest.
head_deadline=$(( (budget - (SECONDS - started)) * 2 / 3 ))
[ "$head_deadline" -lt 60 ] && head_deadline=60
head_rc=0
scripts/ci/guards-local.sh --no-stamp --keep-going --all --jobs "$jobs" "${steps[@]}" --results "$tmp/head.json" \
  --deadline "$head_deadline" > "$tmp/head.log" 2>&1 || head_rc=$?
tail -1 "$tmp/head.log"
if [ "$head_rc" -eq 124 ]; then
  grep '^cmux guards: still running' "$tmp/head.log" || true
  echo "::warning title=guard-steps-reached::the head pass hit its ${head_deadline}s deadline; the reached steps without a result are left to the push"
fi

python3 scripts/ci/guards_new_reds.py --red-steps "$tmp/head.json" > "$tmp/red.txt"
if [ ! -s "$tmp/red.txt" ]; then
  echo "every reached step passed"
  exit 0
fi
cat "$tmp/head.log"
red_count="$(grep -c . "$tmp/red.txt")"
git worktree add --quiet --detach "$tmp/base" "$base_sha"
# CI_GUARDS_REACHED_BASE_VERDICTS=1 (pr-pipeline.yml, from the repository variable; default 0, as before): a red
# step's base verdict is first read from feat-cmux-next's own push run of the base (or of its nearest ancestor, for
# the steps the commits between cannot reach), as cmux-next-guards.yml's guard job does (guard_base_verdicts.py).
# Only the steps with no recorded verdict re-run on the base. The re-run was about half of this step: 201 s of a
# 7.7 min job on job 141030054441 (5 reds, all red on the base too). A failed read re-runs every red step.
reuse=0
[ "${CI_GUARDS_REACHED_BASE_VERDICTS:-0}" = 1 ] && [ -n "${GITHUB_REPOSITORY:-}" ] && reuse=1
echo '{"_cmux_complete": false}' > "$tmp/base-recorded.json"
if [ "$reuse" = 1 ]; then
  python3 scripts/ci/guard_base_verdicts.py --repo "$GITHUB_REPOSITORY" --base "$base_sha" --root "$tmp/base" \
    --steps "$tmp/red.txt" --out "$tmp/base-recorded.json" > "$tmp/rerun.txt" \
    || cp "$tmp/red.txt" "$tmp/rerun.txt"
else
  cp "$tmp/red.txt" "$tmp/rerun.txt"
fi
rerun=()
while IFS= read -r step; do
  [ -n "$step" ] && rerun+=(--step "$step")
done < "$tmp/rerun.txt"
if [ "${#rerun[@]}" -gt 0 ]; then
  echo "re-running $(( ${#rerun[@]} / 2 )) of the head's $red_count red steps on the base $base_sha"
  base_deadline=$(( budget - (SECONDS - started) ))
  [ "$base_deadline" -lt 60 ] && base_deadline=60
  scripts/ci/guards-local.sh --no-stamp --keep-going --all --jobs "$jobs" "${rerun[@]}" --root "$tmp/base" \
    --results "$tmp/base-run.json" --deadline "$base_deadline" > "$tmp/base.log" 2>&1 || true
  tail -1 "$tmp/base.log"
  grep '^cmux guards: still running' "$tmp/base.log" || true
  if [ "$reuse" = 1 ]; then
    python3 scripts/ci/guard_base_verdicts.py --merge "$tmp/base-recorded.json" "$tmp/base-run.json" "$tmp/base.json"
  else
    # Off (the default): the base's own results, read as before.
    # guards_new_reds.py compares each red's failures from <results>.failures.json, so that file moves with it.
    mv "$tmp/base-run.json" "$tmp/base.json" 2>/dev/null || true
    mv "$tmp/base-run.json.failures.json" "$tmp/base.json.failures.json" 2>/dev/null || true
  fi
else
  echo "every one of the head's $red_count red steps has a recorded base verdict; the base is not re-run"
  python3 scripts/ci/guard_base_verdicts.py --merge "$tmp/base-recorded.json" - "$tmp/base.json"
fi
python3 scripts/ci/guards_new_reds.py "$tmp/head.json" "$tmp/base.json"
