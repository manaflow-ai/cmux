#!/bin/bash
# Build a smoke-gate candidate of any commit on the fleet, with the debug.* control surface the gate drives.
#
#   scripts/journeys/build-smoke-candidate.sh SHA [--tag TAG] [--worktree DIR] [--dry-run]
#
# cmux-ad 2026-10-31 08:15Z: a plain Release build has no debug.* socket, so the dogfood smoke gate (and the
# journeys) cannot drive it (every round stops at step 1: debug.windows method_not_found). Every smoke candidate is
# built like the dogfood lines instead: `cmux-ci build cmux --release` of a tag that
# Resources/build/cmux-next.dogfood.conf names, which scripts/reload.sh builds as the bench configuration (Release
# optimization, -O whole module, no DEBUG, plus CMUX_BENCH_HOOKS: the debug.* commands). A bench build never ships:
# reload.sh checks its marker and the release and nightly pipelines refuse it.
#
# What it does:
#   1. a detached worktree of SHA (default: a sibling of this checkout, smoke-candidate-<sha12>);
#   2. if SHA has no dogfood bench mapping (Resources/build/cmux-next.dogfood.conf + reload.sh's RELEASE_FLAG),
#      cherry-picks the mapping commit BENCH_MAPPING (no app source change) onto it;
#   3. pushes that as branch cp/smoke-candidate-<sha12> (a dogfood line: never merge it), through the normal hooks:
#      when SHA is already on origin, the branch is first made at SHA (gh api git/refs), so the hook judges only the
#      mapping commit (fleet rules "Cutting a dogfood line"; never --no-verify);
#   4. submits `cmux-ci build cmux --ref <that commit> --tag TAG --release --backend-mode local` and prints the job id.
# The tag defaults to feat-tip-fixes-<sha10> (a release_bench_tags glob). A dogfood line's commit already has the
# mapping, for its own globs only (chrome-parity-*): pass --tag chrome-parity-<name>. Then:
#   scripts/journeys/smoke-gate.py --build JOB [--diagnostic | --whole-host cmux17]
set -euo pipefail

BENCH_MAPPING=c6d35671018fdc1724ac929315c293354b668750  # cp/dogfood-feat-tip-fixes: dogfood conf + reload.sh mapping
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
sha="" tag="" worktree="" dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) tag="$2"; shift 2 ;;
    --worktree) worktree="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) [ -z "$sha" ] || { echo "usage: $0 SHA [--tag TAG] [--worktree DIR] [--dry-run]" >&2; exit 2; }; sha="$1"; shift ;;
  esac
done
[ -n "$sha" ] || { echo "usage: $0 SHA [--tag TAG] [--worktree DIR] [--dry-run]" >&2; exit 2; }
git -C "$root" fetch -q origin "$sha" feat-cmux-next 2>/dev/null || git -C "$root" fetch -q origin "$sha" 2>/dev/null || true
full="$(git -C "$root" rev-parse --verify "$sha^{commit}")" || { echo "unknown commit $sha (push it first)" >&2; exit 2; }
short="${full:0:12}"
tag="${tag:-feat-tip-fixes-${full:0:10}}"
worktree="${worktree:-$(dirname "$root")/smoke-candidate-$short}"
branch="cp/smoke-candidate-$short"

if [ -e "$worktree" ]; then
  echo "worktree $worktree exists: remove it or pass --worktree" >&2; exit 2
fi
git -C "$root" worktree add -q --detach "$worktree" "$full"
# The worktree is only for this candidate: removed on every exit (the pushed branch keeps the commit).
trap 'cd "$root" && git worktree remove --force "$worktree" >/dev/null 2>&1 || true' EXIT
cd "$worktree"
conf=Resources/build/cmux-next.dogfood.conf
if [ -f "$conf" ] && grep -q 'RELEASE_FLAG' scripts/reload.sh; then
  echo "==> $short already has the dogfood bench mapping"
else
  git -C "$root" fetch -q origin "$BENCH_MAPPING" 2>/dev/null || true
  git cherry-pick "$BENCH_MAPPING" >/dev/null || {
    git cherry-pick --abort 2>/dev/null || true
    echo "the bench mapping $BENCH_MAPPING does not apply to $short (scripts/reload.sh changed): port it by hand" >&2
    exit 3
  }
  echo "==> added the dogfood bench mapping on $short: $(git rev-parse --short HEAD)"
fi
# The tag must be one the conf builds as bench.
matched=0
read -r -a globs <<<"$(sed -n 's/^release_bench_tags=//p' "$conf" | tail -1)"
[ "${#globs[@]}" -gt 0 ] || { echo "$conf names no release_bench_tags: nothing would build as bench" >&2; exit 2; }
for glob in "${globs[@]}"; do
  # shellcheck disable=SC2053
  if [[ "$tag" == $glob ]]; then matched=1; fi
done
[ "$matched" = 1 ] || { echo "tag $tag matches no release_bench_tags glob (${globs[*]}) in $conf" >&2; exit 2; }
head="$(git rev-parse HEAD)"
if [ "$dry" = 1 ]; then
  echo "dry run: would push $head as $branch and run:"
  echo "  cmux-ci build cmux --ref $head --tag $tag --workspace $branch --release --backend-mode local"
  exit 0
fi
# A second run for the same SHA: reuse the pushed candidate when it holds the same tree (a new cherry-pick has
# another commit id); a different tree on that branch is refused, never overwritten.
remote="$(git ls-remote origin "refs/heads/$branch" | cut -f1)"
if [ -n "$remote" ]; then
  git fetch -q origin "$remote"
  if [ "$(git rev-parse "$remote^{tree}")" = "$(git rev-parse "HEAD^{tree}")" ]; then
    head="$remote"
    echo "==> $branch already holds this candidate ($head): reusing it"
  else
    echo "$branch exists with another tree ($remote): not overwritten; remove it or build from it" >&2
    exit 2
  fi
else
  # The base is already on origin (a feat or dogfood commit): make the branch there first, so the pre-push hook
  # judges only the candidate's own mapping commit (fleet rules, "Cutting a dogfood line"; never --no-verify).
  if [ "$head" != "$full" ] && git branch -r --contains "$full" 2>/dev/null | grep -q .; then
    gh api "repos/manaflow-ai/cmux/git/refs" -f ref="refs/heads/$branch" -f sha="$full" >/dev/null
  fi
  git push -q origin "HEAD:refs/heads/$branch"
fi
receipt="${TMPDIR:-/tmp}/smoke-candidate-$short-submit.json"
cmux-ci build cmux --ref "$head" --tag "$tag" --workspace "$branch" --release --backend-mode local --receipt "$receipt" >/dev/null
job="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$receipt")"
echo "smoke candidate of $short: job $job (tag $tag, commit $head, branch $branch: a dogfood line, never merge)"
echo "then: scripts/journeys/smoke-gate.py --build $job [--diagnostic | --whole-host cmux17]"
