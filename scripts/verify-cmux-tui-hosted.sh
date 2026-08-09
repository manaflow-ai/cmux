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
  run_id="$({
    gh run list \
      --repo "$REPO" \
      --workflow "$WORKFLOW" \
      --branch "$remote_branch" \
      --event workflow_dispatch \
      --limit 100 \
      --json databaseId,displayTitle \
      --jq ".[] | select(.displayTitle == \"$run_title\") | .databaseId"
  } | head -n 1)"
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
if command -v python3 >/dev/null 2>&1; then
  python_cmd=python3
elif command -v python >/dev/null 2>&1; then
  python_cmd=python
else
  echo "error: Python is required to enforce the hosted verification timeout" >&2
  exit 1
fi
watch_status=0
"$python_cmd" - "$timeout_seconds" "$REPO" "$run_id" <<'PY' || watch_status=$?
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
repo = sys.argv[2]
run_id = sys.argv[3]
try:
    result = subprocess.run(
        ["gh", "run", "watch", run_id, "--repo", repo, "--exit-status"],
        timeout=timeout_seconds,
        check=False,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY

if [[ "$watch_status" -eq 124 ]]; then
  echo "error: hosted verification did not complete within ${timeout_seconds}s: $run_url" >&2
  exit 1
fi
if [[ "$watch_status" -ne 0 ]]; then
  echo "Hosted verification failed: $run_url" >&2
  gh run view --repo "$REPO" "$run_id" --log-failed || true
  exit 1
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-hosted.XXXXXX")"
cleanup() {
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT

gh run download \
  --repo "$REPO" \
  "$run_id" \
  --name cmux-tui-aarch64-apple-darwin \
  --dir "$temp_dir"

downloaded_binary="$(find "$temp_dir" -type f -name cmux-tui-aarch64-apple-darwin -print -quit)"
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
