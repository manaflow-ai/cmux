#!/usr/bin/env bash
# Verify the exact pushed HEAD on hosted runners and download its macOS arm64 TUI.
set -euo pipefail

REPO="manaflow-ai/cmux"
WORKFLOW="cmux-tui.yml"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify-cmux-tui-hosted.sh --filter <rust-test-name>
  ./scripts/verify-cmux-tui-hosted.sh --filter chatmux_relay
  ./scripts/verify-cmux-tui-hosted.sh --full

--filter runs matching Rust tests on hosted Linux and macOS.
The reserved `chatmux_relay` filter runs the complete `chatmux-relay` package;
Cargo test names do not include their package name, so a plain test-name filter
cannot select that crate.
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

# The list query is only a discovery hint. Re-read the run before accepting it
# so a branch/ref race cannot make us watch a run for a different revision.
run_identity="$(gh run view --repo "$REPO" "$run_id" \
  --json headSha,headBranch,event,displayTitle \
  --jq '[.headSha, .headBranch, .event, .displayTitle] | @tsv')"
IFS=$'\t' read -r run_head_sha run_head_branch run_event run_display_title <<< "$run_identity"
if [[ "$run_head_sha" != "$commit" || "$run_head_branch" != "$remote_branch" || \
      "$run_event" != "workflow_dispatch" || "$run_display_title" != "$run_title" ]]; then
  echo "error: discovered workflow run identity changed; refusing non-exact run" >&2
  printf 'expected: sha=%s branch=%s event=workflow_dispatch title=%s\n' \
    "$commit" "$remote_branch" "$run_title" >&2
  printf 'actual:   sha=%s branch=%s event=%s title=%s\n' \
    "$run_head_sha" "$run_head_branch" "$run_event" "$run_display_title" >&2
  exit 1
fi

run_url="https://github.com/$REPO/actions/runs/$run_id"
echo "Run: $run_url"
echo "Waiting for hosted verification"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-hosted.XXXXXX")"
watch_owner_pid=""
cancel_owner_pid=""
stop_owned_process() {
  local variable_name="$1"
  local owned_pid="${!variable_name}"
  if [[ -n "$owned_pid" ]]; then
    kill "$owned_pid" 2>/dev/null || true
    wait "$owned_pid" 2>/dev/null || true
    printf -v "$variable_name" '%s' ""
  fi
}
cleanup() {
  stop_owned_process cancel_owner_pid
  stop_owned_process watch_owner_pid
  rm -rf -- "$temp_dir"
}
exit_on_signal() {
  trap - HUP INT TERM
  exit "$1"
}
trap cleanup EXIT
trap 'exit_on_signal 129' HUP
trap 'exit_on_signal 130' INT
trap 'exit_on_signal 143' TERM

watch_result_fifo="$temp_dir/run-watch-result"
mkfifo "$watch_result_fifo"

# Keep both ends open so the timed read starts before the watcher publishes its
# result. The watcher owns the GitHub CLI child and reaps it on every exit path.
exec 3<> "$watch_result_fifo"
(
  gh_child_pid=""
  stop_gh_child() {
    if [[ -n "$gh_child_pid" ]]; then
      kill -KILL "$gh_child_pid" 2>/dev/null || true
      wait "$gh_child_pid" 2>/dev/null || true
      gh_child_pid=""
    fi
  }
  stop_watch_owner() {
    stop_gh_child
    exit 143
  }
  trap stop_watch_owner HUP TERM INT
  trap stop_gh_child EXIT

  while true; do
    set +e
    gh run watch \
      --repo "$REPO" \
      "$run_id" \
      --exit-status \
      --interval 10 >&2 &
    gh_child_pid=$!
    wait "$gh_child_pid"
    gh_child_pid=""
    set -e

    run_state_file="$temp_dir/run-state"
    : > "$run_state_file"
    set +e
    gh run view \
      --repo "$REPO" \
      "$run_id" \
      --json status,conclusion \
      --jq '[.status, .conclusion] | @tsv' > "$run_state_file" &
    gh_child_pid=$!
    wait "$gh_child_pid"
    view_status=$?
    gh_child_pid=""
    set -e
    if [[ "$view_status" -eq 0 ]]; then
      run_state="$(<"$run_state_file")"
      IFS=$'\t' read -r run_status run_conclusion <<< "$run_state"
      if [[ "$run_status" == "completed" ]]; then
        trap - HUP TERM INT EXIT
        printf '%s\t%s\n' "$run_status" "$run_conclusion" >&3
        exit 0
      fi
    fi
    sleep 10 &
    gh_child_pid=$!
    wait "$gh_child_pid" 2>/dev/null || true
    gh_child_pid=""
  done
) &
watch_owner_pid=$!

if IFS=$'\t' read -r -t "$timeout_seconds" run_status run_conclusion <&3; then
  wait "$watch_owner_pid"
  watch_owner_pid=""
else
  stop_owned_process watch_owner_pid

  cancel_result_fifo="$temp_dir/run-cancel-result"
  mkfifo "$cancel_result_fifo"
  exec 4<> "$cancel_result_fifo"
  (
    cancel_pid=""
    stop_cancel() {
      if [[ -n "$cancel_pid" ]]; then
        kill -KILL "$cancel_pid" 2>/dev/null || true
        wait "$cancel_pid" 2>/dev/null || true
      fi
      exit 143
    }
    trap stop_cancel HUP TERM INT
    gh run cancel --repo "$REPO" "$run_id" >/dev/null 2>&1 &
    cancel_pid=$!
    set +e
    wait "$cancel_pid"
    cancel_status=$?
    set -e
    cancel_pid=""
    trap - HUP TERM INT
    printf '%s\n' "$cancel_status" >&4
  ) &
  cancel_owner_pid=$!
  if ! read -r -t 10 cancel_status <&4; then
    stop_owned_process cancel_owner_pid
    echo "warning: hosted-run cancellation did not finish within 10 seconds; cancel it manually: $run_url" >&2
  else
    wait "$cancel_owner_pid" 2>/dev/null || true
    cancel_owner_pid=""
    if [[ "$cancel_status" -ne 0 ]]; then
      echo "warning: hosted-run cancellation failed with status $cancel_status; cancel it manually: $run_url" >&2
    fi
  fi
  exec 4>&-
  echo "error: hosted verification did not complete within ${timeout_seconds}s: $run_url" >&2
  exit 1
fi
exec 3>&-

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

# Keep a small, bounded local cache. Cleanup is opt-in so existing callers do
# not lose artifacts unexpectedly. Only directories owned by this user and
# named for a complete commit SHA are eligible. The current commit and any
# binary still open by a process are always retained.
retention_count="${CMUX_TUI_HOSTED_RETENTION_COUNT:-}"
if [[ -z "$retention_count" ]]; then
  echo "Hosted artifact retention disabled (set CMUX_TUI_HOSTED_RETENTION_COUNT to enable)" >&2
  echo "Hosted verification passed: $run_url"
  echo "Artifact: $artifact_binary"
  echo "Dogfood: $artifact_binary --session verify-${commit:0:8}"
  exit 0
fi
if [[ ! "$retention_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CMUX_TUI_HOSTED_RETENTION_COUNT must be a positive integer" >&2
  exit 2
fi
if [[ "${CMUX_TUI_HOSTED_RETENTION_DRY_RUN:-0}" == "1" ]]; then
  retention_dry_run=true
elif [[ "${CMUX_TUI_HOSTED_RETENTION_DRY_RUN:-0}" == "0" ]]; then
  retention_dry_run=false
else
  echo "error: CMUX_TUI_HOSTED_RETENTION_DRY_RUN must be 0 or 1" >&2
  exit 2
fi
retention_confirmed="${CMUX_TUI_HOSTED_RETENTION_CONFIRM:-0}"
if [[ "$retention_dry_run" == false && "$retention_confirmed" != "1" ]]; then
  echo "error: destructive retention requires CMUX_TUI_HOSTED_RETENTION_CONFIRM=1 after a dry run" >&2
  exit 2
fi
preview_file="cmux-tui/target/hosted/.retention-preview"
lsof_available=false
if command -v lsof >/dev/null 2>&1; then
  lsof_available=true
fi

hosted_artifact_dirs=()
hosted_artifact_order=()
while IFS= read -r -d '' candidate_dir; do
  candidate_commit="${candidate_dir##*/}"
  [[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || continue
  if stat -f '%m' "$candidate_dir" >/dev/null 2>&1; then
    candidate_mtime="$(stat -f '%m' "$candidate_dir")"
  else
    candidate_mtime="$(stat -c '%Y' "$candidate_dir")"
  fi
  hosted_artifact_order+=("$candidate_mtime	$candidate_commit	$candidate_dir")
done < <(find cmux-tui/target/hosted -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" -print0)
if ((${#hosted_artifact_order[@]} > 0)); then
  while IFS=$'\t' read -r _ candidate_commit candidate_dir; do
    hosted_artifact_dirs+=("$candidate_dir")
  done < <(printf '%s\n' "${hosted_artifact_order[@]}" | sort -t $'\t' -k1,1nr -k2,2r)
fi
candidate_set_hash="$(printf '%s\n' "${hosted_artifact_dirs[@]}" | shasum -a 256 | awk '{print $1}')"
if [[ "$retention_dry_run" == true ]]; then
  printf '%s\t%s\n' "$candidate_set_hash" "$(date +%s)" > "$preview_file"
elif [[ ! -f "$preview_file" ]] || [[ "$(cut -f1 "$preview_file")" != "$candidate_set_hash" ]] || \
  (( $(date +%s) - $(cut -f2 "$preview_file") > 600 )); then
  echo "error: retention requires a fresh dry-run preview for this candidate set" >&2
  exit 2
fi
retained=0
for candidate_dir in "${hosted_artifact_dirs[@]}"; do
  candidate_commit="${candidate_dir##*/}"
  candidate_binary="$candidate_dir/cmux-tui"
  if [[ "$candidate_commit" == "$commit" ]]; then
    continue
  fi
  if (( retained < retention_count )); then
    retained=$((retained + 1))
    continue
  fi
  if [[ "$lsof_available" != true ]]; then
    echo "error: cannot prove artifact is inactive because lsof is unavailable" >&2
    exit 2
  fi
  if [[ -f "$candidate_binary" ]] && lsof -t -- "$candidate_binary" >/dev/null 2>&1; then
    echo "Keeping active hosted artifact: $candidate_binary" >&2
    continue
  fi
  if [[ "$retention_dry_run" == true ]]; then
    echo "Would remove hosted artifact: $candidate_dir" >&2
  else
    rm -rf -- "$candidate_dir"
    echo "Removed hosted artifact: $candidate_dir" >&2
  fi
done

echo "Hosted verification passed: $run_url"
echo "Artifact: $artifact_binary"
echo "Dogfood: $artifact_binary --session verify-${commit:0:8}"
