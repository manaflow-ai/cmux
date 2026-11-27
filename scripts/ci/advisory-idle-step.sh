#!/usr/bin/env bash
# advisory-idle-step.sh MODE PR HEAD_SHA LINE
#
# The controller's idle-class advisory step (cmuxterm-hq build-fleet/cmd/controller/advisory_idle.go,
# docs/design/ci-v2.md step 6 and R8). The controller starts it on idle Linux pool room for a pull request
# into feat-cmux-next, checked out at the pull request's base commit, so the guard that runs is the base's,
# never the pull request's code, as classic-api-guard.yml does. The step holds no GitHub token: it reads only
# public git objects, and its exit code is the verdict the controller records (and, once out of shadow, posts
# with the token it holds).
#
#   MODE      classic-api-guard (the only one so far)
#   PR        the pull request number (its refs/pull/PR/merge commit lists the changed paths)
#   HEAD_SHA  the head the controller saw; a merge commit of another head is not judged
#   LINE      1 when the description has a `Classic API change: <reason>` line, else 0 (the controller
#             reads the description from the webhook; the step never sees its text)
#
# Exit: 0 pass (no classic auto-deployed path, or a reason given), 10 warn (a classic path changed with no
# reason line), 4 unknown (no merge commit of this head yet), 2 bad arguments, anything else an error.
# Leo, 2026-11-24 05:02Z: "we can do it better, no? simply have a scheduler that does better."
set -euo pipefail

mode=${1:-}
pr=${2:-}
head=${3:-}
line=${4:-}
if [ "$mode" != classic-api-guard ] || ! [[ $pr =~ ^[1-9][0-9]{0,6}$ && $head =~ ^[0-9a-f]{40}$ && $line =~ ^[01]$ ]]; then
  echo "usage: advisory-idle-step.sh classic-api-guard PR HEAD_SHA 0|1" >&2
  exit 2
fi

cd "$(git rev-parse --show-toplevel)"
guard=scripts/ci/classic_api_guard.py
if [ ! -f "$guard" ]; then
  echo "advisory: the base has no $guard; nothing to check"
  exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
remote=${CMUX_ADVISORY_REMOTE:-https://github.com/manaflow-ai/cmux.git}

# The merge commit's first parent is the base GitHub merged with, so the diff is what the pull request
# changes there. Trees only, no blobs; a merge commit of another head (the ref lags a push) is not judged.
depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=2)
if ! git fetch --no-recurse-submodules --quiet --no-tags --no-write-fetch-head --filter=blob:none ${depth[@]+"${depth[@]}"} \
    "$remote" "+refs/pull/$pr/merge:refs/advisory/merge" \
  || ! git rev-parse --verify --quiet refs/advisory/merge^1 > /dev/null \
  || [ "$(git rev-parse refs/advisory/merge^2)" != "$head" ]; then
  echo "advisory: no merge commit of $head for #$pr yet; verdict unknown"
  exit 4
fi
git diff --name-only --no-renames refs/advisory/merge^1 refs/advisory/merge > "$tmp/paths.txt"
records=$(wc -l < "$tmp/paths.txt" | tr -d ' ')
: > "$tmp/body.md"
if [ "$line" = 1 ]; then
  printf 'Classic API change: given in the description\n' > "$tmp/body.md"
fi

python3 "$guard" --base feat-cmux-next --body-file "$tmp/body.md" --paths-file "$tmp/paths.txt" \
  --listed-records "$records" | tee "$tmp/out.txt"
echo "advisory: #$pr at $head: $records changed paths"
if grep -q '^::warning::' "$tmp/out.txt"; then
  exit 10
fi
exit 0
