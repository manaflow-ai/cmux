#!/usr/bin/env bash
# The visual expectation gate for one pull request, end to end, from a lane:
#   1. renders the PR merged into its base on the fleet (fleet-capture.sh under `cmux-ci test`),
#   2. judges the pictures against the base's baselines, keep regions and the PR body's
#      "## Visual changes" block (gate.ts, here: pixel math only, no browser),
#   3. uploads each changed state's before | after | diff sheet to pr-media (privacy-checked by
#      scripts/pr-media.py) and posts the review page as one PR comment.
#
#   scripts/gallery-matrix/expectations/review.sh 43019 [--no-post] [--artifact DIR]
#
# Run it from a checkout whose own PR is open (`cmux-ci test` runs at that PR's head). Exit 1 when the
# gate fails (a keep region changed without a justification, or a baselined state stopped rendering).
set -euo pipefail

pr=${1:?usage: review.sh PR [--no-post] [--artifact DIR]}
shift
post=1
art=
while [ $# -gt 0 ]; do
  case "$1" in
    --no-post) post=0 ;;
    --artifact) art=$2; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
repo=$(git rev-parse --show-toplevel)
gate="$repo/scripts/gallery-matrix/expectations"
work=$(mktemp -d)

if [ -z "$art" ]; then
  art="$work/artifact"
  (cd "$repo" && cmux-ci test --setup webviews --timeout 2400 --artifact "$art" -- \
    bash scripts/gallery-matrix/expectations/fleet-capture.sh pr "$pr")
fi
# The artifact may hold the run's FAST_CHECKS_OUT directly or one folder down.
root=$(dirname "$(find "$art" -maxdepth 3 -name meta.json | head -1)")
[ -f "$root/meta.json" ] || { echo "no meta.json in $art: the fleet run did not finish" >&2; exit 1; }
head=$(sed -E 's/.*"head": "([0-9a-f]+)".*/\1/' "$root/meta.json")
base=$(sed -E 's/.*"base": "([0-9a-f]+)".*/\1/' "$root/meta.json")

gh pr view "$pr" -R manaflow-ai/cmux --json body --jq .body > "$work/body.md"
# Judge against the checked-in baselines when the same renderer drew them; otherwise against the
# base rendered live in the same run, so a browser or font update is never blamed on the PR.
baselines="$root/base/baselines"
if [ -d "$root/base-render" ] && ! cmp -s "$root/base/baselines/web/renderer.json" "$root/captures/web/renderer.json"; then
  echo "checked-in web baselines missing or from another renderer: judging against the base rendered live"
  baselines="$root/base-render"
fi
[ -d "$repo/scripts/gallery-matrix/node_modules" ] || (cd "$repo/scripts/gallery-matrix" && bun install --frozen-lockfile >/dev/null)
rc=0
bun "$gate/gate.ts" --expectations "$root/base/expectations" --head-expectations "$root/head/expectations" \
  --baselines "$baselines" --captures "$root/captures" --body "$work/body.md" --out "$work/review" \
  --pr "$pr" --head-sha "$head" --base-sha "$base" \
  --media-base "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/$pr" || rc=$?
echo "review page: $work/review/comment.md"
if [ "$post" = 1 ]; then
  mapfile -t media < <(sed "s#^#$work/review/#" "$work/review/media.txt")
  [ ${#media[@]} -eq 0 ] || python3 "$repo/scripts/pr-media.py" --pr "$pr" "${media[@]}" >/dev/null
  gh pr comment "$pr" -R manaflow-ai/cmux --body-file "$work/review/comment.md"
fi
exit "$rc"
