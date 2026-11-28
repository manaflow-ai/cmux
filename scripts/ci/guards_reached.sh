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
# The base pass starts beside the head's, niced, over every reached step: it runs on the cores the head's long poles
# leave idle, and a head with no red stops it. Run after the head, it did not fit: cmux#61530 (run 46142803587, 96
# workers) spent 597 s on the head ("Validate fork runner routing" alone 596 s), and the base re-run of its 17 reds
# ran past the step's 900 s, so the step printed no verdict and every red, 15 of them the base's own, went to a merge
# gate with no base run to read. Both passes stop at GUARDS_REACHED_BUDGET seconds (default 840, inside the step's
# 900), so the verdict always prints; a step either pass did not finish is never called the base's.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
base="${1:-HEAD^1}"
base_sha="$(git rev-parse --verify "$base^{commit}" 2>/dev/null)" || {
  echo "no base commit $base: nothing to compare against; the push runs the guards"
  exit 0
}
tmp="$(mktemp -d)"
base_pid=""
cleanup() {
  if [ -n "$base_pid" ]; then
    kill -TERM "$base_pid" 2>/dev/null || true
    wait "$base_pid" 2>/dev/null || true
  fi
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
budget="${GUARDS_REACHED_BUDGET:-840}"
[[ "$budget" =~ ^[0-9]+$ ]] && [ "$budget" -ge 60 ] || budget=840
# guards-local.sh makes its venv on first use: once here, not by both passes at once.
scripts/ci/guards-local.sh --list > /dev/null 2>&1 || true
git worktree add --quiet --detach "$tmp/base" "$base_sha"
nice -n 10 scripts/ci/guards-local.sh --no-stamp --keep-going --all --jobs "$jobs" "${steps[@]}" --root "$tmp/base" \
  --results "$tmp/base.json" --deadline "$budget" > "$tmp/base.log" 2>&1 &
base_pid=$!
scripts/ci/guards-local.sh --no-stamp --keep-going --all --jobs "$jobs" "${steps[@]}" --results "$tmp/head.json" \
  --deadline "$budget" > "$tmp/head.log" 2>&1 || true
tail -1 "$tmp/head.log"

python3 scripts/ci/guards_new_reds.py --red-steps "$tmp/head.json" > "$tmp/red.txt"
if [ ! -s "$tmp/red.txt" ] && python3 scripts/ci/guards_new_reds.py --complete "$tmp/head.json"; then
  kill -TERM "$base_pid" 2>/dev/null || true
  wait "$base_pid" 2>/dev/null || true
  echo "every reached step passed"
  exit 0
fi
cat "$tmp/head.log"
echo "the base $base_sha ran the same $count steps beside the head; waiting for it"
wait "$base_pid" || true
tail -1 "$tmp/base.log"
python3 scripts/ci/guards_new_reds.py "$tmp/head.json" "$tmp/base.json"
