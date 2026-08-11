#!/usr/bin/env bash
# Verify the exact pushed HEAD on hosted runners and download its macOS arm64 TUI.
set -euo pipefail

REPO="manaflow-ai/cmux"
WORKFLOW="cmux-tui.yml"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify-cmux-tui-hosted.sh --filter <rust-test-name>
  ./scripts/verify-cmux-tui-hosted.sh --full

--filter runs matching Rust tests on hosted Linux and macOS.
--full runs the cross-platform merge gate, including real Windows execution.
Both modes build and download a macOS arm64 cmux-tui artifact from the exact pushed HEAD.
EOF
}

mode=""
test_filter=""
case "${1:-}" in
  --filter)
    if [[ $# -ne 2 ]]; then
      usage >&2
      exit 2
    fi
    mode="focused"
    test_filter="$2"
    ;;
  --full)
    if [[ $# -ne 1 ]]; then
      usage >&2
      exit 2
    fi
    mode="full"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ "$mode" == "focused" && ! "$test_filter" =~ ^[A-Za-z0-9_][A-Za-z0-9_:.-]{0,199}$ ]]; then
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
  echo "error: hosted verification requires a pushed branch, not detached HEAD" >&2
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
remote_ref="$remote/$remote_branch"
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
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: could not resolve an exact commit SHA" >&2
  exit 1
fi

remote_commit="$(git ls-remote --heads "$remote" "refs/heads/$remote_branch" | awk 'NR == 1 { print $1 }')"
if [[ -z "$remote_commit" ]]; then
  echo "error: $remote_ref does not exist; push this branch first" >&2
  exit 1
fi
if [[ "$remote_commit" != "$commit" ]]; then
  echo "error: $remote_ref is $remote_commit, but local HEAD is $commit" >&2
  echo "push the exact local HEAD before hosted verification" >&2
  exit 1
fi

request_id="${commit:0:12}-$(date +%s)-$$"
run_title="cmux-tui $mode $request_id @ $commit"

echo "Dispatching $mode verification for $commit"
gh workflow run "$WORKFLOW" \
  --repo "$REPO" \
  --ref "$remote_branch" \
  -f "commit=$commit" \
  -f "mode=$mode" \
  -f "test_filter=$test_filter" \
  -f "request_id=$request_id"

run_id=""
# The dispatch command does not return a run ID. Poll only until the uniquely
# titled run appears, and then let GitHub CLI watch the run state.
for _ in $(seq 1 60); do
  run_query=""
  if run_query="$(
    gh run list \
      --repo "$REPO" \
      --workflow "$WORKFLOW" \
      --branch "$remote_branch" \
      --event workflow_dispatch \
      --limit 100 \
      --json databaseId,displayTitle,headSha \
      --jq ".[] | select(.displayTitle == \"$run_title\" and .headSha == \"$commit\") | .databaseId"
  )"; then
    run_id="$(printf '%s\n' "$run_query" | sed -n '1p')"
  else
    echo "warning: run discovery query failed; retrying" >&2
  fi
  if [[ -n "$run_id" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "$run_id" ]]; then
  echo "error: the dispatched workflow did not appear within 120 seconds" >&2
  exit 1
fi

run_url="https://github.com/$REPO/actions/runs/$run_id"
echo "Run: $run_url"
echo "Waiting for hosted verification"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-hosted.XXXXXX")"
watch_result_fifo="$temp_dir/run-watch-result"
mkfifo "$watch_result_fifo"
cleanup() {
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT

# Keep both ends open so the timed read starts before the watcher publishes its
# result. The watcher owns the GitHub CLI child and reaps it on every exit path.
exec 3<> "$watch_result_fifo"
(
  watcher_pid=""
  stop_watcher() {
    if [[ -n "$watcher_pid" ]]; then
      kill "$watcher_pid" 2>/dev/null || true
      wait "$watcher_pid" 2>/dev/null || true
    fi
  }
  trap stop_watcher TERM INT EXIT

  set +e
  gh run watch \
    --repo "$REPO" \
    "$run_id" \
    --exit-status \
    --interval 10 >&2 &
  watcher_pid=$!
  wait "$watcher_pid"
  watch_status=$?
  watcher_pid=""
  set -e

  trap - TERM INT EXIT
  printf '%s\n' "$watch_status" >&3
) &
watch_owner_pid=$!

if IFS= read -r -t "$timeout_seconds" watch_status <&3; then
  wait "$watch_owner_pid"
else
  kill "$watch_owner_pid" 2>/dev/null || true
  wait "$watch_owner_pid" 2>/dev/null || true
  gh run cancel --repo "$REPO" "$run_id" >/dev/null 2>&1 || true
  echo "error: hosted verification did not complete within ${timeout_seconds}s: $run_url" >&2
  exit 1
fi
exec 3>&-

run_state="$(
  gh run view \
    --repo "$REPO" \
    "$run_id" \
    --json status,conclusion \
    --jq '[.status, .conclusion] | @tsv'
)"
IFS=$'\t' read -r run_status run_conclusion <<< "$run_state"
if [[ "$run_status" != "completed" ]]; then
  echo "error: hosted run watcher exited before completion: $run_url" >&2
  exit 1
fi

if [[ "$run_conclusion" != "success" ]]; then
  echo "Hosted verification failed: $run_url" >&2
  gh run view --repo "$REPO" "$run_id" --log-failed || true
  exit 1
fi

gh run download \
  --repo "$REPO" \
  "$run_id" \
  --name cmux-tui-aarch64-apple-darwin \
  --dir "$temp_dir"

downloaded_binary="$(find "$temp_dir" -type f -name cmux-tui-aarch64-apple-darwin -print | sed -n '1p')"
if [[ -z "$downloaded_binary" ]]; then
  echo "error: the macOS arm64 artifact did not contain cmux-tui" >&2
  exit 1
fi

artifact_dir="cmux-tui/target/hosted/$commit"
artifact_binary="$artifact_dir/cmux-tui"
mkdir -p "$artifact_dir"
install -m 0755 "$downloaded_binary" "$artifact_binary"

echo "Hosted verification passed: $run_url"
echo "Artifact: $artifact_binary"
echo "Dogfood: $artifact_binary --session verify-${commit:0:8}"
