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
  ./scripts/verify-cmux-tui-hosted.sh [--cancel-on-timeout] --filter <name> | --full

--filter runs matching Rust tests on hosted Linux and macOS.
The reserved `chatmux_relay` filter runs the complete `chatmux-relay` package;
Cargo test names do not include their package name, so a plain test-name filter
cannot select that crate.
--full runs the cross-platform merge gate, including real Windows execution.
Both modes build and download the matching macOS arm64 cmux-tui artifact from the
exact pushed HEAD. --full also downloads the separate userland agent-plugin artifact;
--filter builds the macOS target on a Linux runner, which stages the plugin inside the
cmux-tui artifact (when it built) instead.

The wait ends after CMUX_TUI_HOSTED_TIMEOUT_SECONDS (default 7200). The hosted
run is not cancelled then: the script prints the run URL and how to keep
waiting, and exits with status 3. Ctrl-C cancels the hosted run.
--cancel-on-timeout also cancels the hosted run when the wait ends (exit 1).
EOF
}

mode=""
test_filter=""
cancel_on_timeout=false
args=()
for arg in "$@"; do
  if [[ "$arg" == "--cancel-on-timeout" ]]; then
    cancel_on_timeout=true
  else
    args+=("$arg")
  fi
done
set -- ${args[@]+"${args[@]}"}
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
# How long a run cancelled by someone else may take to be re-run (CI rescue).
rescue_window_seconds="${CMUX_TUI_HOSTED_RESCUE_WINDOW_SECONDS:-300}"
# The shortest time between two waiter rounds.
round_seconds="${CMUX_TUI_HOSTED_ROUND_SECONDS:-30}"
if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: hosted verification timeout must be a positive integer" >&2
  exit 2
fi
if [[ ! "$rescue_window_seconds" =~ ^[0-9]+$ ]]; then
  echo "error: CMUX_TUI_HOSTED_RESCUE_WINDOW_SECONDS must be a whole number of seconds" >&2
  exit 2
fi
if [[ ! "$round_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CMUX_TUI_HOSTED_ROUND_SECONDS must be a positive whole number of seconds" >&2
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

echo "Dispatching $mode verification for $commit"
# return_run_details makes the dispatch answer with the run it created, so
# there is no run list to poll for it.
run_id="$(gh api -X POST "repos/$REPO/actions/workflows/$WORKFLOW/dispatches" \
  -f "ref=$remote_branch" \
  -f "inputs[commit]=$commit" \
  -f "inputs[mode]=$mode" \
  -f "inputs[test_filter]=$test_filter" \
  -f "inputs[request_id]=$request_id" \
  -F return_run_details=true \
  --jq '.workflow_run_id // ""')"

if [[ ! "$run_id" =~ ^[0-9]+$ ]]; then
  echo "error: the workflow dispatch returned no run id" >&2
  exit 1
fi

# Re-read the run before accepting it so a branch/ref race cannot make us
# watch a run for a different revision. The dispatch named this run, so its
# title (run-name, with request_id) is not checked: GitHub renders it a moment
# after the dispatch, and a run read sooner is titled only "cmux-tui".
run_identity="$(gh run view --repo "$REPO" "$run_id" \
  --json headSha,headBranch,event \
  --jq '[.headSha, .headBranch, .event] | @tsv')"
IFS=$'\t' read -r run_head_sha run_head_branch run_event <<< "$run_identity"
if [[ "$run_head_sha" != "$commit" || "$run_head_branch" != "$remote_branch" || \
      "$run_event" != "workflow_dispatch" ]]; then
  echo "error: dispatched workflow run $run_id is not this revision; refusing it" >&2
  printf 'expected: sha=%s branch=%s event=workflow_dispatch\n' "$commit" "$remote_branch" >&2
  printf 'actual:   sha=%s branch=%s event=%s\n' "$run_head_sha" "$run_head_branch" "$run_event" >&2
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
# Bounded: gh run cancel gets 10 seconds, then a warning names the run URL.
cancel_hosted_run() {
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
}
# Ctrl-C is an explicit stop, so it also stops the hosted run. HUP and TERM
# (a closed terminal, an agent harness that ends the command) do not: the run
# is evidence that other callers wait for.
interrupt_hosted_run() {
  trap - HUP INT TERM
  if [[ "$cancel_on_interrupt" == true ]]; then
    cancel_on_interrupt=false
    stop_owned_process watch_owner_pid
    echo "Interrupted; cancelling the hosted run: $run_url" >&2
    cancel_hosted_run
  fi
  exit 130
}
cancel_on_interrupt=true
trap cleanup EXIT
trap 'exit_on_signal 129' HUP
trap interrupt_hosted_run INT
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
  # Runs one child as the owned process, so a signal reaps it; sets child_status.
  run_child() {
    "$@" &
    gh_child_pid=$!
    wait "$gh_child_pid"
    child_status=$?
    gh_child_pid=""
  }

  # One waiter per round, no tight loop: glaeda-gh shares one cheap poller per
  # machine; without it, gh run watch checks once per five minutes. A waiter
  # can return before the run is done: glaeda-gh rules on each attempt, and
  # ci-owned-pool-rescue cancels a run whose macOS jobs wait for a busy owned
  # pool and re-runs it on Blacksmith (run 42503576472, 2026-11-08: attempt 1
  # cancelled at 17:14:26Z, attempt 2 queued at 17:14:34Z). So a round that
  # ends with the run not done, or cancelled by someone else, waits again
  # until the deadline. This script never cancels the run here.
  set +e
  deadline=$((SECONDS + timeout_seconds))
  waiter_log="$temp_dir/waiter.log"
  run_state_file="$temp_dir/run-state"
  use_glaeda=false
  command -v glaeda-gh >/dev/null 2>&1 && use_glaeda=true
  cancelled_since=""
  run_status="unknown"
  run_conclusion="unknown"
  while true; do
    remaining=$((deadline - SECONDS))
    [[ "$remaining" -gt 0 ]] || break
    round_start=$SECONDS
    if [[ "$use_glaeda" == true ]]; then
      run_child glaeda-gh wait run "$REPO/$run_id" --until "done" --timeout "$remaining" > "$waiter_log" 2>&1
      waiter="glaeda-gh wait run"
    else
      run_child gh run watch --repo "$REPO" "$run_id" --interval 300 > "$waiter_log" 2>&1
      waiter="gh run watch"
    fi
    waiter_status=$child_status
    waited=$((SECONDS - round_start))

    : > "$run_state_file"
    run_child gh run view --repo "$REPO" "$run_id" --json status,conclusion,attempt \
      --jq '"\(.status)|\(.conclusion)|\(.attempt)"' > "$run_state_file"
    run_status="unknown"
    run_conclusion="unknown"
    run_attempt="?"
    if [[ "$child_status" -eq 0 ]]; then
      # "|", not a tab: IFS whitespace would merge the empty conclusion of a
      # queued run into one separator.
      IFS='|' read -r run_status run_conclusion run_attempt < "$run_state_file" || true
    fi

    if [[ "$run_status" == "completed" && "$run_conclusion" != "cancelled" ]]; then
      break
    fi
    if [[ "$run_status" == "completed" ]]; then
      # Cancelled by someone else. ci-owned-pool-rescue re-runs within a minute
      # or two; after this window the cancellation is the result.
      if [[ -z "$cancelled_since" ]]; then
        cancelled_since=$SECONDS
        echo "note: attempt $run_attempt of the run was cancelled outside this script; waiting up to ${rescue_window_seconds}s for a re-run (CI rescue)" >&2
      fi
      if (( SECONDS - cancelled_since >= rescue_window_seconds )); then
        break
      fi
    else
      cancelled_since=""
      if (( SECONDS < deadline )); then
        echo "warning: $waiter exited $waiter_status after ${waited}s with the run ${run_status} (attempt $run_attempt); waiting again, the run is not cancelled" >&2
        if [[ -s "$waiter_log" ]]; then
          tail -n 5 "$waiter_log" | sed 's/^/  waiter: /' >&2
        fi
      fi
    fi
    # glaeda-gh exits 3 when its daemon is down and 64 on a usage error; it
    # would fail the same way again, so the next rounds use gh run watch.
    if [[ "$use_glaeda" == true && ( "$waiter_status" -eq 3 || "$waiter_status" -eq 64 ) ]]; then
      echo "warning: glaeda-gh cannot wait here; using gh run watch (one check per 5 minutes) instead" >&2
      use_glaeda=false
    fi
    # At most one round per round_seconds (30), so a waiter that keeps
    # returning at once (a cancelled attempt, a failed read) does not spin on
    # the API.
    pause=$((round_seconds - (SECONDS - round_start)))
    remaining=$((deadline - SECONDS))
    (( pause > remaining )) && pause=$remaining
    if (( pause > 0 )); then
      run_child sleep "$pause"
    fi
  done
  set -e
  trap - HUP TERM INT EXIT
  printf '%s\t%s\n' "$run_status" "$run_conclusion" >&3
  exit 0
) &
watch_owner_pid=$!

run_finished=false
# The watcher publishes at its own deadline; this read is the backstop.
if IFS=$'\t' read -r -t "$((timeout_seconds + 60))" run_status run_conclusion <&3; then
  wait "$watch_owner_pid" || true
  watch_owner_pid=""
  [[ "$run_status" == "completed" ]] && run_finished=true
fi
# The deadline came with the run not done. The macOS queue can be longer than
# the wait, so by default the run keeps going and the caller waits on it; it is
# not cancelled.
if [[ "$run_finished" != true ]]; then
  cancel_on_interrupt=false
  stop_owned_process watch_owner_pid
  if [[ "$cancel_on_timeout" == true ]]; then
    cancel_hosted_run
    echo "error: hosted verification did not complete (run ${run_status:-still running}) within the wait of ${timeout_seconds}s; cancelled: $run_url" >&2
    exit 1
  fi
  echo "Hosted verification is still running (run ${run_status:-still running}) after the wait of ${timeout_seconds}s: $run_url" >&2
  echo "still running, wait with glaeda-gh wait run $REPO/$run_id" >&2
  echo "Do not run this script again for this commit: that starts a second run. When it is done: gh run view --repo $REPO $run_id --log-failed, or gh run download --repo $REPO $run_id" >&2
  exit 3
fi
cancel_on_interrupt=false
exec 3>&-

if [[ "$run_conclusion" != "success" ]]; then
  echo "Hosted verification failed: $run_url" >&2
  if [[ "$run_conclusion" == "cancelled" ]]; then
    echo "The run was cancelled outside this script and was not re-run within ${rescue_window_seconds}s." >&2
  fi
  gh run view --repo "$REPO" "$run_id" --log-failed || true
  exit 1
fi

gh run download \
  --repo "$REPO" \
  "$run_id" \
  --name cmux-tui-aarch64-apple-darwin \
  --dir "$temp_dir"

plugin_download_dir="$temp_dir/agent-plugin"
mkdir -p "$plugin_download_dir"
if [[ "$mode" == "full" ]]; then
  gh run download \
    --repo "$REPO" \
    "$run_id" \
    --name cmux-agent-screen-detection-aarch64-apple-darwin \
    --dir "$plugin_download_dir"
fi

downloaded_binary="$(find "$temp_dir" -type f -name cmux-tui-aarch64-apple-darwin -print | sed -n '1p')"
if [[ -z "$downloaded_binary" ]]; then
  echo "error: the macOS arm64 artifact did not contain cmux-tui" >&2
  exit 1
fi

if [[ "$mode" == "full" ]]; then
  downloaded_plugin="$(find "$plugin_download_dir" -type f -name cmux-agent-screen-detection-aarch64-apple-darwin -print | sed -n '1p')"
  if [[ -z "$downloaded_plugin" ]]; then
    echo "error: the macOS arm64 artifact did not contain the agent screen-detection plugin" >&2
    exit 1
  fi
else
  # Focused runs build on Linux (darwin_builder=linux): the plugin rides the
  # cmux-tui artifact, and scripts/ci/stage-agent-detector.sh leaves it out
  # with a warning when it did not build.
  downloaded_plugin="$(find "$temp_dir" -type f -name cmux-tui-agent-screen-detection-aarch64-apple-darwin -print | sed -n '1p')"
  if [[ -z "$downloaded_plugin" ]]; then
    echo "warning: the macOS arm64 artifact has no agent screen-detection plugin; installing cmux-tui without it" >&2
  fi
fi

artifact_dir="cmux-tui/target/hosted/$commit"
artifact_binary="$artifact_dir/cmux-tui"
artifact_plugin="$artifact_dir/cmux-agent-screen-detection"
mkdir -p "$artifact_dir"
install -m 0755 "$downloaded_binary" "$artifact_binary"
if [[ -n "$downloaded_plugin" ]]; then
  install -m 0755 "$downloaded_plugin" "$artifact_plugin"
fi

echo "Hosted verification passed: $run_url"
echo "Artifact: $artifact_binary"
if [[ -n "$downloaded_plugin" ]]; then
  echo "Artifact: $artifact_plugin"
fi
echo "Dogfood: $artifact_binary --session verify-${commit:0:8}"
