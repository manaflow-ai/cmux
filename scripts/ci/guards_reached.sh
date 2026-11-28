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
rerun=()
while IFS= read -r step; do
  [ -n "$step" ] && rerun+=(--step "$step")
done < "$tmp/red.txt"
echo "re-running the head's $(grep -c . "$tmp/red.txt") red steps on the base $base_sha"
git worktree add --quiet --detach "$tmp/base" "$base_sha"
base_deadline=$(( budget - (SECONDS - started) ))
[ "$base_deadline" -lt 60 ] && base_deadline=60
scripts/ci/guards-local.sh --no-stamp --keep-going --all --jobs "$jobs" "${rerun[@]}" --root "$tmp/base" \
  --results "$tmp/base.json" --deadline "$base_deadline" > "$tmp/base.log" 2>&1 || true
tail -1 "$tmp/base.log"
grep '^cmux guards: still running' "$tmp/base.log" || true
python3 scripts/ci/guards_new_reds.py "$tmp/head.json" "$tmp/base.json"
