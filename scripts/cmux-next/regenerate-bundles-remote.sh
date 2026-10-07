#!/usr/bin/env bash
# Regenerates the committed agent-pane and page bundles (build-agent-pane-web.sh,
# build-pages-web.sh) for this checkout's branch on a Linux runner, for a machine
# without bun, and applies them here to commit and push. It dispatches
# cmux-next-regenerate-bundles.yml from feat-cmux-next at this branch's HEAD,
# which must already be pushed, and refuses a dirty tree.
# CMUX_REGENERATE_BUNDLES_REF dispatches the workflow from another branch (to
# test a change to it).
#
# Usage: scripts/cmux-next/regenerate-bundles-remote.sh
set -euo pipefail

repo=manaflow-ai/cmux
workflow=cmux-next-regenerate-bundles.yml
workflow_ref="${CMUX_REGENERATE_BUNDLES_REF:-feat-cmux-next}"
branch="$(git branch --show-current)"
sha="$(git rev-parse HEAD)"
if [[ -z "$branch" || "$branch" == main || "$branch" == feat-cmux-next ]]; then
  echo "error: check out a lane branch (not main or feat-cmux-next)" >&2
  exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: commit or stash local changes first" >&2
  exit 1
fi
pushed="$(git ls-remote "https://github.com/$repo.git" "refs/heads/$branch" | awk '{print $1}')"
if [[ "$pushed" != "$sha" ]]; then
  echo "error: push $branch first: origin has ${pushed:-no such branch}, HEAD is $sha" >&2
  exit 1
fi

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
gh workflow run "$workflow" -R "$repo" --ref "$workflow_ref" -f branch="$branch" -f sha="$sha" >/dev/null
title="regenerate bundles for $branch @ $sha"
run=""
for _ in $(seq 1 30); do
  run="$(gh run list -R "$repo" --workflow "$workflow" --limit 30 --json databaseId,displayTitle,createdAt \
    --jq "[.[] | select(.displayTitle == \"$title\" and .createdAt >= \"$since\")][0].databaseId // empty")"
  [[ -n "$run" ]] && break
  sleep 4
done
if [[ -z "$run" ]]; then
  echo "error: the dispatched run did not appear; see https://github.com/$repo/actions/workflows/$workflow" >&2
  exit 1
fi
echo "run: https://github.com/$repo/actions/runs/$run"
if ! gh run watch "$run" -R "$repo" --exit-status >/dev/null; then
  echo "error: the run failed: https://github.com/$repo/actions/runs/$run" >&2
  exit 1
fi

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
if ! gh run download "$run" -R "$repo" -n cmux-next-bundles-patch -D "$dir" >/dev/null 2>&1; then
  echo "The bundles at $sha are current; nothing to apply."
  exit 0
fi
# Only bundle paths, as the workflow collects them.
while IFS=$'\t' read -r _ _ path; do
  case "$path" in
    *..*) ;;
    Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/*) continue ;;
    Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/*) continue ;;
    webviews/src/*/generated/strings.json) continue ;;
  esac
  echo "error: the patch touches $path, which is not a bundle path" >&2
  exit 1
done < <(git apply --numstat "$dir/bundles.patch")
git apply --index "$dir/bundles.patch"
git diff --cached --stat
echo "Applied. Commit and push:"
echo "  git commit -m 'chore(cmux-next): regenerate the agent pane and page bundles' && git push"
