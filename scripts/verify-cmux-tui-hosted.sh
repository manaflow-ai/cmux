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
Both modes build and download matching macOS arm64 cmux-tui and userland agent-plugin
artifacts from the exact pushed HEAD.

One open run per commit, mode and filter: when a cmux-tui run for the same
commit, mode and test filter is still open (queued, in progress, waiting), the
script does not dispatch a second one. It prints that run's id and URL and
exits with status 4; wait on that run with glaeda-gh wait run instead.

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
# The wait before the second and third dispatch tries is this times the try number.
dispatch_backoff="${CMUX_TUI_HOSTED_DISPATCH_BACKOFF_SECONDS:-10}"
if [[ ! "$dispatch_backoff" =~ ^[0-9]{1,4}$ ]]; then
  echo "error: CMUX_TUI_HOSTED_DISPATCH_BACKOFF_SECONDS must be a whole number of seconds below 10000" >&2
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
# Set once the dispatch names the run: Ctrl-C before that has no run to cancel.
cancel_on_interrupt=false
run_id=""
run_url=""
trap cleanup EXIT
trap 'exit_on_signal 129' HUP
trap interrupt_hosted_run INT
trap 'exit_on_signal 143' TERM

# The run API does not return a run's inputs, so the run-name (title) carries
# the filter: request_id is <sha12>-f<hash8>-<epoch>-<pid>, where hash8 is the
# first 8 hex digits of the filter's git blob hash (the empty filter in full
# mode). validate-inputs accepts [A-Za-z0-9._-]; the lookup below reads the token.
filter_hash="$(printf '%s' "$test_filter" | git hash-object --stdin)"
filter_hash="${filter_hash:0:8}"
request_id="${commit:0:12}-f${filter_hash}-$(date +%s)-$$"

# One open run per commit, mode and filter (2026-11-09: about 37 cmux-tui runs
# queued for the shared Mac pool, often several for one commit). A run of this
# commit whose title has this mode and this filter's token, and that is not
# completed, is the run to wait on: do not dispatch a second one. The run is
# not attached to here: it belongs to the caller that dispatched it, and this
# script cancels its own run on Ctrl-C and --cancel-on-timeout. A failed lookup
# only warns, so a run-list outage cannot block verification.
open_run_lookup="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --commit "$commit" \
  --event workflow_dispatch --limit 50 --json databaseId,status,displayTitle,url \
  --jq '.[] | [.databaseId, .status, .displayTitle, .url] | @tsv' 2>"$temp_dir/open-run.err")" || {
  printf 'warning: could not look for an open cmux-tui run of this commit, dispatching anyway: %s\n' \
    "$(cat "$temp_dir/open-run.err")" >&2
  open_run_lookup=""
}
while IFS=$'\t' read -r open_id open_status open_title open_url; do
  [[ -n "$open_id" && "$open_status" != "completed" ]] || continue
  [[ "$open_title" == "cmux-tui $mode "*" @ $commit" ]] || continue
  open_request="${open_title#"cmux-tui $mode "}"
  open_request="${open_request%" @ $commit"}"
  # Full mode has no filter, so any open full run of the commit counts. A
  # focused run counts only with this filter's token (a run dispatched before
  # the token existed has an unknown filter and does not count).
  if [[ "$mode" == "focused" && "$open_request" != *"-f${filter_hash}-"* ]]; then
    continue
  fi
  echo "error: cmux-tui run $open_id ($open_status) already verifies $commit in $mode mode${test_filter:+ with filter $test_filter}; not dispatching a second run" >&2
  echo "Run: $open_url" >&2
  echo "Wait on it: glaeda-gh wait run $REPO/$open_id" >&2
  echo "When it is done: gh run view --repo $REPO $open_id --log-failed, or gh run download --repo $REPO $open_id" >&2
  exit 4
done <<< "$open_run_lookup"

echo "Dispatching $mode verification for $commit"
# return_run_details makes the dispatch answer with the run it created, so
# there is no run list to poll for it.
dispatch() {
  gh api -X POST "repos/$REPO/actions/workflows/$WORKFLOW/dispatches" \
    -f "ref=$remote_branch" \
    -f "inputs[commit]=$commit" \
    -f "inputs[mode]=$mode" \
    -f "inputs[test_filter]=$test_filter" \
    -f "inputs[request_id]=$request_id" \
    -F return_run_details=true \
    --jq '.workflow_run_id // ""' 2>"$temp_dir/dispatch.err"
}
# A 5xx or a lost connection can come after GitHub created the run. Its
# run-name holds request_id, so look for it before a new try instead of
# dispatching a second run. GitHub renders the run-name a moment after the run
# starts, so a run of this commit created since the first try and still titled
# only "cmux-tui" counts too, when it is the only one.
dispatch_since="$(date -u -v-2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
dispatched_run() {
  # shellcheck disable=SC2016 # $runs is a jq variable; COMMIT, SINCE and REQUEST are replaced below
  local filter='[.[] | select(.headSha == "COMMIT" and .createdAt >= "SINCE")] as $runs
    | ([$runs[] | select(.displayTitle | contains("REQUEST"))] | .[0].databaseId)
      // ([$runs[] | select(.displayTitle == "cmux-tui")] | if length == 1 then .[0].databaseId else null end)
      // empty'
  filter="${filter//COMMIT/$commit}"
  filter="${filter//SINCE/$dispatch_since}"
  filter="${filter//REQUEST/$request_id}"
  gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$remote_branch" \
    --event workflow_dispatch --limit 30 --json databaseId,displayTitle,headSha,createdAt \
    --jq "$filter" 2>"$temp_dir/lookup.err"
}
check_runs_hint="gh run list --repo $REPO --workflow $WORKFLOW --branch $remote_branch --event workflow_dispatch"
dispatch_tries=3
for try in 1 2 3; do
  dispatch_status=0
  run_id="$(dispatch)" || dispatch_status=$?
  [[ $dispatch_status -eq 0 ]] && break
  dispatch_error="$(cat "$temp_dir/dispatch.err")"
  # GitHub refused the request (4xx): it created no run, and a new try gets the same answer.
  if grep -Eq 'HTTP 4[0-9][0-9]' <<<"$dispatch_error"; then
    printf 'error: the workflow dispatch failed: %s\n' "$dispatch_error" >&2
    echo "error: GitHub refused the dispatch, so no run was created" >&2
    exit 1
  fi
  printf 'warning: the workflow dispatch failed (try %d of %d): %s\n' "$try" "$dispatch_tries" "$dispatch_error" >&2
  # Bounded backoff between tries; it also lets GitHub render a run-name.
  sleep $((try * dispatch_backoff))
  lookup_status=0
  run_id="$(dispatched_run)" || lookup_status=$?
  if [[ $lookup_status -ne 0 ]]; then
    printf 'error: could not list runs to find one GitHub may have created for request %s: %s\n' \
      "$request_id" "$(cat "$temp_dir/lookup.err")" >&2
    echo "error: not dispatched again, so there is no second run; check with: $check_runs_hint" >&2
    exit 1
  fi
  run_id="$(head -n 1 <<<"$run_id")"
  if [[ "$run_id" =~ ^[0-9]+$ ]]; then
    echo "GitHub created run $run_id for request $request_id despite the error; using it"
    break
  fi
  if ((try >= dispatch_tries)); then
    printf 'error: the workflow dispatch failed %d times and no run was found for request %s, so no run was created that this script can see; check with: %s\n' \
      "$dispatch_tries" "$request_id" "$check_runs_hint" >&2
    exit 1
  fi
done

if [[ ! "$run_id" =~ ^[0-9]+$ ]]; then
  echo "error: the workflow dispatch returned no run id" >&2
  exit 1
fi
run_url="https://github.com/$REPO/actions/runs/$run_id"
cancel_on_interrupt=true

# Read the run before accepting it so a branch/ref race cannot make us accept
# a run of a different revision. The dispatch named this run, so its title
# (run-name, with request_id) is not checked: GitHub renders it a moment after
# the dispatch, and a run read sooner is titled only "cmux-tui".
#
# GitHub can answer 404 or 500 for a few seconds after it creates a run (run
# 42688604218: HTTP 404; run 42688525295: HTTP 500). The run exists, so such a
# read is not a failure and is not retried here: the script names the run,
# gives the wait to glaeda-gh wait run (the single poller), and checks the
# revision again before it accepts the result or an artifact. A network drop
# is waited out the same way. Any other error (401, 403, a broken gh) does
# not heal by waiting: it exits 1 at once.
run_identity_confirmed=false
check_run_identity() {
  local identity
  identity="$(gh run view --repo "$REPO" "$run_id" \
    --json headSha,headBranch,event \
    --jq '[.headSha, .headBranch, .event] | @tsv' 2>"$temp_dir/identity.err")" || return 2
  IFS=$'\t' read -r run_head_sha run_head_branch run_event <<< "$identity"
  if [[ "$run_head_sha" != "$commit" || "$run_head_branch" != "$remote_branch" || \
        "$run_event" != "workflow_dispatch" ]]; then
    echo "error: dispatched workflow run $run_id is not this revision; refusing it" >&2
    printf 'expected: sha=%s branch=%s event=workflow_dispatch\n' "$commit" "$remote_branch" >&2
    printf 'actual:   sha=%s branch=%s event=%s\n' "$run_head_sha" "$run_head_branch" "$run_event" >&2
    return 1
  fi
  run_identity_confirmed=true
}
identity_status=0
check_run_identity || identity_status=$?
if [[ $identity_status -eq 1 ]]; then
  exit 1
elif [[ $identity_status -eq 2 ]]; then
  identity_error="$(tr '\n' ' ' < "$temp_dir/identity.err")"
  # Waited out: 404 or 5xx (GitHub has not shown the new run yet) and a
  # network drop with no HTTP code. Exit at once: any other HTTP error (401,
  # 403) and a gh that fails without a network error (a broken gh).
  if ! grep -Eqi 'HTTP (404|5[0-9][0-9])|error connecting to|connection (reset|refused)|timed? ?out|i/o timeout|no such host|TLS handshake|unexpected EOF' <<<"$identity_error" || \
      grep -Eq 'HTTP (40[0-35-9]|4[1-9][0-9])' <<<"$identity_error"; then
    printf 'error: could not read run %s that the dispatch created (%s); it is not cancelled: %s\n' \
      "$run_id" "$identity_error" "$run_url" >&2
    exit 1
  fi
  printf 'note: GitHub created run %s but could not show it yet (%s); waiting on it, its revision is checked before the result counts\n' \
    "$run_id" "$identity_error" >&2
fi

echo "Run: $run_url"
echo "Waiting for hosted verification"


watch_result_fifo="$temp_dir/run-watch-result"
mkfifo "$watch_result_fifo"

# Keep both ends open so the timed read starts before the watcher publishes its
# result. The watcher owns the GitHub CLI child and reaps it on every exit path.
exec 3<> "$watch_result_fifo"
(
  stop_children() {
    # Every background child of this subshell, so a child started a moment
    # before the signal (its pid not yet recorded) is reaped too.
    local pids
    pids="$(jobs -p)"
    if [[ -n "$pids" ]]; then
      # shellcheck disable=SC2086 # one pid per word
      kill -KILL $pids 2>/dev/null || true
      # shellcheck disable=SC2086
      wait $pids 2>/dev/null || true
    fi
  }
  stop_watch_owner() {
    stop_children
    exit 143
  }
  trap stop_watch_owner HUP TERM INT
  trap stop_children EXIT
  # Runs one child, at most `limit` seconds; sets child_status (143 when the
  # limit stopped it). gh run watch has no timeout of its own.
  #
  # The limiter learns that the child ended from a line on its own fifo, not
  # from a signal: a TERM sent to a subshell that has not yet set its trap is
  # lost, and the watcher then waited out the whole limit (main tip CI, PR
  # #38729, 2026-11-08: a 60 s run read held the watcher to its deadline, so a
  # cancelled run read as "still running"). A line in a pipe cannot be lost,
  # and a fresh fifo per child means a line left by an earlier child is never
  # read as this one's.
  child_seq=0
  run_child() {
    local limit="$1"
    shift
    child_seq=$((child_seq + 1))
    local done_fifo="$temp_dir/child-done.$child_seq"
    mkfifo "$done_fifo"
    # Read-write, so neither end blocks on open; the limiter reads it as fd 5.
    exec 5<> "$done_fifo"
    "$@" 5>&- &
    local child=$!
    # The limiter keeps no stdio of the script.
    (
      if ! read -r -t "$limit" -u 5 _; then
        kill -TERM "$child" 2>/dev/null
      fi
    ) </dev/null >/dev/null 2>&1 &
    local limiter=$!
    wait "$child"
    child_status=$?
    echo ended >&5
    wait "$limiter" 2>/dev/null || true
    exec 5>&-
    rm -f "$done_fifo"
  }
  read_run_state() {
    : > "$run_state_file"
    run_child 60 gh run view --repo "$REPO" "$run_id" --json status,conclusion,attempt \
      --jq '"\(.status)|\(.conclusion)|\(.attempt)"' > "$run_state_file"
    run_status="unknown"
    run_conclusion="unknown"
    run_attempt="?"
    if [[ "$child_status" -eq 0 ]]; then
      # "|", not a tab: IFS whitespace would merge the empty conclusion of a
      # queued run into one separator.
      IFS='|' read -r run_status run_conclusion run_attempt < "$run_state_file" || true
    fi
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
  have_glaeda=false
  command -v glaeda-gh >/dev/null 2>&1 && have_glaeda=true
  use_glaeda=$have_glaeda
  ended_since=""
  run_status="unknown"
  run_conclusion="unknown"
  while true; do
    remaining=$((deadline - SECONDS))
    [[ "$remaining" -gt 0 ]] || break
    round_start=$SECONDS
    if [[ "$use_glaeda" == true ]]; then
      # --jobs: glaeda-gh holds a failure that a runner's refusal caused while
      # the rescue re-runs the failed jobs (--rescue-grace).
      run_child "$((remaining + 30))" glaeda-gh wait run "$REPO/$run_id" --until "done" --jobs \
        --timeout "$remaining" > "$waiter_log" 2>&1
      waiter="glaeda-gh wait run"
    else
      run_child "$remaining" gh run watch --repo "$REPO" "$run_id" --interval 300 > "$waiter_log" 2>&1
      waiter="gh run watch"
      # A daemon restart is brief: the next round tries glaeda-gh again.
      use_glaeda=$have_glaeda
    fi
    waiter_status=$child_status
    waited=$((SECONDS - round_start))
    read_run_state

    # A run that ended other than in success may be re-run by the CI rescue:
    # cancelled (the run waited for a busy owned pool) or failed (a runner
    # refused a job; glaeda-gh --jobs already held that one for a while).
    if [[ "$run_status" == "completed" ]]; then
      if [[ "$run_conclusion" == "success" ]]; then
        ended_since=""
        break
      fi
      if [[ -z "$ended_since" ]]; then
        ended_since=$SECONDS
        if [[ "$run_conclusion" == "cancelled" || "$waiter" == "gh run watch" ]]; then
          echo "note: attempt $run_attempt of the run ended ($run_conclusion) without this script; waiting up to ${rescue_window_seconds}s for a re-run (CI rescue)" >&2
        fi
      fi
      if [[ "$run_conclusion" != "cancelled" && "$waiter" != "gh run watch" ]] || \
          (( SECONDS - ended_since >= rescue_window_seconds )); then
        ended_since=""
        break
      fi
    else
      ended_since=""
      if (( SECONDS < deadline )); then
        echo "warning: $waiter exited $waiter_status after ${waited}s with the run ${run_status} (attempt $run_attempt); waiting again, the run is not cancelled" >&2
        if [[ -s "$waiter_log" ]]; then
          tail -n 5 "$waiter_log" | sed 's/^/  waiter: /' >&2
        fi
      fi
    fi
    # glaeda-gh exits 3 when its daemon is down or failing and 64 on a usage
    # error; the next round uses gh run watch, and the one after glaeda-gh again.
    if [[ "$use_glaeda" == true && "$waiter" == "glaeda-gh wait run" && \
          ( "$waiter_status" -eq 3 || "$waiter_status" -eq 64 ) ]]; then
      echo "warning: glaeda-gh cannot wait now (exit $waiter_status); the next round uses gh run watch (one check per 5 minutes)" >&2
      use_glaeda=false
    fi
    # At most one round per round_seconds (30), so a waiter that keeps
    # returning at once (a cancelled attempt, a failed read) does not spin on
    # the API.
    pause=$((round_seconds - (SECONDS - round_start)))
    remaining=$((deadline - SECONDS))
    (( pause > remaining )) && pause=$remaining
    if (( pause > 0 )); then
      run_child "$((pause + 5))" sleep "$pause"
    fi
  done
  # The deadline came while a re-run may still follow: that is not a result.
  if [[ -n "$ended_since" ]]; then
    run_status="ended-awaiting-rerun"
  fi
  set -e
  trap - HUP TERM INT EXIT
  printf '%s\t%s\n' "$run_status" "$run_conclusion" >&3
  exit 0
) &
watch_owner_pid=$!

run_finished=false
# The watcher publishes at its own deadline; this read is the backstop.
if IFS=$'\t' read -r -t "$((timeout_seconds + 150))" run_status run_conclusion <&3; then
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
  if [[ "$run_identity_confirmed" == true ]]; then
    echo "Running this script again for this commit and filter while the run is open exits 4 without a second run. When it is done: gh run view --repo $REPO $run_id --log-failed, or gh run download --repo $REPO $run_id" >&2
  else
    # Its first read failed, so no artifact of it may be used until its revision is read.
    echo "The run's revision is not confirmed (its first read failed). When it is done, check it with: gh run view --repo $REPO $run_id --json headSha,headBranch,event; it must be $commit on $remote_branch (workflow_dispatch) before its result or artifacts count." >&2
  fi
  exit 3
fi
cancel_on_interrupt=false
exec 3>&-

# The first read of the run failed: check its revision now, before its result
# or an artifact counts.
if [[ "$run_identity_confirmed" != true ]]; then
  identity_status=0
  check_run_identity || identity_status=$?
  if [[ $identity_status -eq 2 ]]; then
    printf 'error: could not read run %s to confirm its revision (%s); its result is not accepted: %s\n' \
      "$run_id" "$(tr '\n' ' ' < "$temp_dir/identity.err")" "$run_url" >&2
    exit 1
  elif [[ $identity_status -ne 0 ]]; then
    exit 1
  fi
fi

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
gh run download \
  --repo "$REPO" \
  "$run_id" \
  --name cmux-agent-screen-detection-aarch64-apple-darwin \
  --dir "$plugin_download_dir"

downloaded_binary="$(find "$temp_dir" -type f -name cmux-tui-aarch64-apple-darwin -print | sed -n '1p')"
if [[ -z "$downloaded_binary" ]]; then
  echo "error: the macOS arm64 artifact did not contain cmux-tui" >&2
  exit 1
fi

downloaded_plugin="$(find "$plugin_download_dir" -type f -name cmux-agent-screen-detection-aarch64-apple-darwin -print | sed -n '1p')"
if [[ -z "$downloaded_plugin" ]]; then
  echo "error: the macOS arm64 artifact did not contain the agent screen-detection plugin" >&2
  exit 1
fi

artifact_dir="cmux-tui/target/hosted/$commit"
artifact_binary="$artifact_dir/cmux-tui"
artifact_plugin="$artifact_dir/cmux-agent-screen-detection"
mkdir -p "$artifact_dir"
install -m 0755 "$downloaded_binary" "$artifact_binary"
install -m 0755 "$downloaded_plugin" "$artifact_plugin"

echo "Hosted verification passed: $run_url"
echo "Artifact: $artifact_binary"
echo "Artifact: $artifact_dir/cmux-agent-screen-detection"
echo "Dogfood: $artifact_binary --session verify-${commit:0:8}"
