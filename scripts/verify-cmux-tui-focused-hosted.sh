#!/usr/bin/env bash
# Run one exact Rust test filter on hosted macOS and Linux.
set -euo pipefail

REPO="manaflow-ai/cmux"
WORKFLOW="cmux-tui.yml"

usage() {
  echo "Usage: ./scripts/verify-cmux-tui-focused-hosted.sh --filter <rust-test-name>"
}

if [[ "$#" -ne 2 || "${1:-}" != "--filter" ]]; then
  usage >&2
  exit 2
fi
test_filter="$2"
if [[ ! "$test_filter" =~ ^[A-Za-z0-9_][A-Za-z0-9_:.-]{0,199}$ ]]; then
  echo "error: --filter must be one Rust test-name substring without shell syntax" >&2
  exit 2
fi

timeout_seconds="${CMUX_TUI_HOSTED_TIMEOUT_SECONDS:-7200}"
if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: hosted verification timeout must be a positive integer" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
cd "$repo_root"

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo "error: commit all changes before hosted verification" >&2
  git status --short >&2
  exit 1
fi

branch="$(git symbolic-ref --quiet --short HEAD || true)"
if [[ -z "$branch" ]]; then
  echo "error: hosted verification requires a pushed branch" >&2
  exit 1
fi
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
if [[ "$upstream" == */* ]]; then
  remote="${upstream%%/*}"
  remote_branch="${upstream#*/}"
else
  remote="origin"
  remote_branch="$branch"
fi
remote_url="$(git remote get-url "$remote")"
remote_matches_repo=false
for expected_url in \
  "https://github.com/$REPO" \
  "https://github.com/$REPO.git" \
  "git@github.com:$REPO" \
  "git@github.com:$REPO.git" \
  "ssh://git@github.com/$REPO" \
  "ssh://git@github.com/$REPO.git"
do
  if [[ "$remote_url" == "$expected_url" ]]; then
    remote_matches_repo=true
    break
  fi
done
if [[ "$remote_matches_repo" != true ]]; then
  echo "error: upstream remote $remote does not target github.com/$REPO" >&2
  exit 1
fi

commit="$(git rev-parse HEAD)"
remote_commit="$(git ls-remote --heads "$remote" "refs/heads/$remote_branch" | awk 'NR == 1 { print $1 }')"
if [[ "$remote_commit" != "$commit" ]]; then
  echo "error: origin head is '$remote_commit', local head is '$commit'" >&2
  exit 1
fi

if command -v uuidgen >/dev/null 2>&1; then
  request_nonce="$(uuidgen | tr '[:upper:]' '[:lower:]')"
else
  request_nonce="$(head -c 32 /dev/urandom | git hash-object --stdin)"
fi
request_id="${commit:0:12}-$request_nonce"
run_title="cmux-tui focused $request_id @ $commit"

gh workflow run "$WORKFLOW" \
  --repo "$REPO" \
  --ref "$remote_branch" \
  -f "commit=$commit" \
  -f "test_filter=$test_filter" \
  -f "request_id=$request_id"

run_id=""
for _ in $(seq 1 60); do
  run_id="$(
    gh run list \
      --repo "$REPO" \
      --workflow "$WORKFLOW" \
      --branch "$remote_branch" \
      --event workflow_dispatch \
      --limit 100 \
      --json databaseId,displayTitle,headSha \
      --jq ".[]
        | select(.displayTitle == \"$run_title\" and .headSha == \"$commit\")
        | .databaseId"       | sed -n '1p'
  )" || true
  [[ -n "$run_id" ]] && break
  sleep 2
done
if [[ -z "$run_id" ]]; then
  echo "error: dispatched workflow did not appear within 120 seconds" >&2
  exit 1
fi

run_url="https://github.com/$REPO/actions/runs/$run_id"
echo "Run: $run_url"
started="$(date +%s)"
while true; do
  state="$(
    gh run view "$run_id"       --repo "$REPO"       --json status,conclusion       --jq '[.status, .conclusion] | @tsv'
  )" || state=""
  IFS=$'\t' read -r status conclusion <<< "$state"
  if [[ "$status" == completed ]]; then
    if [[ "$conclusion" == success ]]; then
      echo "Hosted verification passed: $run_url"
      exit 0
    fi
    echo "Hosted verification failed: $run_url" >&2
    gh run view "$run_id" --repo "$REPO" --log-failed || true
    exit 1
  fi
  if (( $(date +%s) - started >= timeout_seconds )); then
    echo "error: hosted verification timed out: $run_url" >&2
    exit 1
  fi
  sleep 10
done
