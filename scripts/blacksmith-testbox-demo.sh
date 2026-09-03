#!/usr/bin/env bash
# Guided end-to-end tour of the cmux-tui Blacksmith Testbox lane.
#
# Warms a box from main, pins it to your pushed HEAD, builds cmux-tui twice to
# show what the persistent disk buys, and always stops the box it created.
# Every remote command is printed before it runs, so the tour doubles as the
# documentation.
set -euo pipefail

WORKFLOW=.github/workflows/cmux-tui-testbox-warmup.yml
JOB=cmux-tui-rust
IDLE_TIMEOUT=30
CLEANUP_TIMEOUT=30
APPROVE=1
STAGES=0

usage() {
  cat <<'USAGE'
usage: scripts/blacksmith-testbox-demo.sh [options]

  --stages        run the three measured benchmark stages instead of the two
                  plain builds (slower, produces evidence JSON)
  --no-approve    do not approve the deployment gate; approve it yourself in
                  the GitHub UI when the script pauses
  --idle-timeout  minutes before Blacksmith reclaims the box (default 30)
USAGE
}

while (( $# )); do
  case "$1" in
    --stages) STAGES=1 ;;
    --no-approve) APPROVE=0 ;;
    --idle-timeout) shift; IDLE_TIMEOUT="${1:?--idle-timeout needs minutes}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
run_local() { printf '\033[2m$ %s\033[0m\n' "$*"; "$@"; }

cd "$(git rev-parse --show-toplevel)"
BOUNDED=./scripts/blacksmith-bounded-command.sh

# ---------------------------------------------------------------- preflight --
say "Preflight"
for tool in blacksmith gh git; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 65; }
done
test -x "$BOUNDED" || { echo "missing $BOUNDED; run from a cmux worktree" >&2; exit 65; }
test -f "$WORKFLOW" || { echo "missing $WORKFLOW; rebase onto a main that has the lane" >&2; exit 65; }

if [[ ! -f ghostty/build.zig.zon ]]; then
  say "Initializing the Ghostty submodule (one time, takes a moment)"
  run_local git submodule update --init ghostty
fi

BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
[[ -n "$BRANCH" ]] || { echo "HEAD is detached; check out a branch first" >&2; exit 65; }
SOURCE_SHA="$(git rev-parse HEAD)"
GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)"

if [[ -n "$(git status --porcelain=v1 --untracked-files=normal)" ]]; then
  echo "worktree is dirty; commit and push before benchmarking" >&2
  git status --short >&2
  exit 65
fi
remote_sha="$(git ls-remote --exit-code origin "refs/heads/$BRANCH" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
if [[ "$remote_sha" != "$SOURCE_SHA" ]]; then
  cat >&2 <<EOF
push this branch first. The box resolves your commit by fetching it from
GitHub; a local-only commit fails there with 'upload-pack: not our ref'.
  git push origin $BRANCH
EOF
  exit 65
fi

blacksmith auth whoami >/dev/null || { echo "run: blacksmith auth login" >&2; exit 65; }
echo "branch        $BRANCH"
echo "commit        $SOURCE_SHA"
echo "ghostty       $GHOSTTY_SHA"
echo "CLI           $(blacksmith --version)"

say "Boxes currently running in the org (never adopt one you did not warm)"
printf '\033[2m$ blacksmith testbox list --all\033[0m\n'
preflight_inventory_ok=0
preexisting_testboxes=""
set +e
preflight_inventory="$(blacksmith testbox list --all 2>&1)"
preflight_inventory_status=$?
set -e
if (( preflight_inventory_status == 0 )); then
  preflight_inventory_ok=1
  preexisting_testboxes="$(printf '%s\n' "$preflight_inventory" \
    | awk '$1 ~ /^tbx_[A-Za-z0-9_-]+$/ { print $1 }' | sort -u)"
  preexisting_count="$(printf '%s\n' "$preexisting_testboxes" | awk 'NF { count += 1 } END { print count + 0 }')"
  printf 'captured pre-dispatch Testbox inventory (%s boxes)\n' "$preexisting_count"
else
  echo "could not capture the pre-dispatch Testbox inventory; partial warmup cleanup will fail closed" >&2
fi

echo
echo "Warming one 32 vCPU Linux VM: about 4 minutes of hydration, a few minutes"
echo "of building, then it stops itself. Ctrl-C also stops it."

# ------------------------------------------------------------------- warmup --
TBX=""
RUN_ID=""
warmup_log=""
ready_log=""
inventory_log=""
partial_status_log=""
pre_ready_status_log=""
approval_status_log=""
ready_phase_started=0

extract_run_id_from_log() {
  local log_path="$1"
  local run_url run_id
  [[ -s "$log_path" ]] || return 1

  # The RUN URL is emitted on the row for this exact Testbox once the box is
  # ready. Do not scan the whole transcript: another row or a pasted URL must
  # never become the cleanup target.
  run_url="$(awk -v testbox_id="$TBX" '
    $1 == testbox_id {
      for (field = 1; field <= NF; field++) {
        if ($field ~ /^https:\/\/github\.com\/manaflow-ai\/cmux\/actions\/runs\/[0-9]+\/?$/) {
          print $field
          exit
        }
      }
    }
  ' "$log_path")"
  run_id="$(printf '%s\n' "$run_url" | sed -nE 's#^https://github\.com/manaflow-ai/cmux/actions/runs/([0-9]+)/?$#\1#p')"
  [[ "$run_id" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$run_id"
}

record_run_id_from_log() {
  local log_path="$1"
  local discovered
  [[ -z "$RUN_ID" ]] || return 0
  discovered="$(extract_run_id_from_log "$log_path" 2>/dev/null || true)"
  if [[ "$discovered" =~ ^[0-9]+$ ]]; then
    RUN_ID="$discovered"
    echo "recorded exact warmup run URL for cleanup"
    return 0
  fi
  return 1
}

recover_partial_testbox() {
  local log_path="$1"
  local candidate status_status
  [[ -z "$TBX" ]] || return 0

  # A nonzero warmup status is not an ownership receipt. Treat any printed ID
  # as an untrusted candidate, then require an exact ID-specific status row and
  # proof that the ID was absent from the pre-dispatch inventory. If either
  # check fails, leave TBX empty so cleanup cannot stop another operator's box.
  set +e
  candidate="$(grep -Eo 'tbx_[A-Za-z0-9_-]+' "$log_path" | head -1)"
  set -e
  [[ "$candidate" =~ ^tbx_[A-Za-z0-9_-]+$ ]] || return 1
  if (( preflight_inventory_ok == 0 )); then
    echo "warmup failed; pre-dispatch Testbox inventory was unavailable, refusing cleanup ownership" >&2
    return 1
  fi
  if printf '%s\n' "$preexisting_testboxes" | grep -Fqx "$candidate"; then
    echo "warmup failed; candidate existed before dispatch, refusing cleanup ownership" >&2
    return 1
  fi

  partial_status_log="$(mktemp)"
  set +e
  "$BOUNDED" "$CLEANUP_TIMEOUT" blacksmith testbox status --id "$candidate" \
    >"$partial_status_log" 2>&1
  status_status=$?
  set -e
  if (( status_status != 0 )); then
    echo "warmup failed; exact status lookup did not verify the candidate, refusing cleanup ownership" >&2
    rm -f -- "$partial_status_log"
    partial_status_log=""
    return 1
  fi
  if ! awk -v testbox_id="$candidate" '$1 == testbox_id { found=1; exit } END { exit found ? 0 : 1 }' \
    "$partial_status_log"; then
    echo "warmup failed; status omitted the candidate, refusing cleanup ownership" >&2
    rm -f -- "$partial_status_log"
    partial_status_log=""
    return 1
  fi

  TBX="$candidate"
  record_run_id_from_log "$partial_status_log" || true
  rm -f -- "$partial_status_log"
  partial_status_log=""
  echo "recovered Testbox after failed warmup from exact ID-specific status" >&2
  return 0
}

discover_run_id() {
  [[ -n "$TBX" && -z "$RUN_ID" ]] || return 0

  # A ready/status transcript may already contain the authoritative RUN URL.
  if [[ -n "$ready_log" ]]; then
    record_run_id_from_log "$ready_log" && return 0
  fi

  # Ask Blacksmith for the row keyed by our Testbox ID. RUN URL is the
  # authoritative binding once hydration has assigned the runner.
  local status_log
  status_log="$(mktemp)"
  set +e
  # Let the CLI poll its ID-specific endpoint while the outer command deadline
  # guarantees that EXIT cleanup cannot wait forever. Parse the transcript even
  # when the outer bound expires, because a complete row may have been flushed.
  "$BOUNDED" "$CLEANUP_TIMEOUT" blacksmith testbox status --id "$TBX" \
    --wait --wait-timeout 30s >"$status_log" 2>&1
  set -e
  # A transient status exit can still leave a complete, exact row in the
  # transcript. Parse it before considering the command status.
  record_run_id_from_log "$status_log" || true
  rm -f -- "$status_log"
  [[ -z "$RUN_ID" ]] || return 0

  # Older CLI versions include RUN URL only in the inventory listing. Keep
  # this fallback keyed by the exact Testbox ID for the same ownership proof.
  inventory_log="$(mktemp)"
  set +e
  "$BOUNDED" "$CLEANUP_TIMEOUT" blacksmith testbox list --all >"$inventory_log" 2>&1
  set -e
  record_run_id_from_log "$inventory_log" || true
  rm -f -- "$inventory_log"
  inventory_log=""
  [[ -z "$RUN_ID" ]] || return 0

}

discover_run_id_before_stop() {
  [[ -n "$TBX" && -z "$RUN_ID" ]] || return 0

  # Approval can fail before the ready phase starts. Use one exact, non-waiting
  # row lookup before stopping so an already-assigned RUN URL remains available
  # for the cancellation fallback. Never use the waiting-run set difference.
  local status_status
  pre_ready_status_log="$(mktemp)"
  set +e
  "$BOUNDED" "$CLEANUP_TIMEOUT" blacksmith testbox status --id "$TBX" \
    >"$pre_ready_status_log" 2>&1
  status_status=$?
  set -e
  record_run_id_from_log "$pre_ready_status_log" || true
  rm -f -- "$pre_ready_status_log"
  pre_ready_status_log=""
  (( status_status == 0 )) || return 1
  [[ -n "$RUN_ID" ]]
}

reconcile_run_id() {
  [[ -n "$TBX" && -z "$RUN_ID" ]] || return 0
  discover_run_id || true
  [[ -n "$RUN_ID" ]]
}

remove_temp_files() {
  local path
  for path in "$warmup_log" "$ready_log" "$inventory_log" "$partial_status_log" "$pre_ready_status_log" "$approval_status_log"; do
    if [[ -n "$path" ]]; then
      rm -f -- "$path"
    fi
  done
  return 0
}

cleanup() {
  local status=$?
  local stop_status=0
  trap - EXIT INT TERM

  # A signal can arrive while the warmup command is still in the foreground,
  # before its ID assignment runs. Reuse the same preflight and exact status
  # proof used for nonzero warmups before giving up on ownership recovery.
  if [[ -z "$TBX" && -s "$warmup_log" ]]; then
    recover_partial_testbox "$warmup_log" || true
  fi

  # Discover before stopping the box. The RUN URL is present while the box is
  # ready, and stopping first can remove the only authoritative row. Before
  # approval, use one exact non-waiting row lookup because the gate cannot move.
  if (( ready_phase_started )); then
    reconcile_run_id || true
  else
    discover_run_id_before_stop || true
  fi
  if [[ -n "$TBX" ]]; then
    say "Stopping the box this script created"
    set +e
    "$BOUNDED" "$CLEANUP_TIMEOUT" blacksmith testbox stop --id "$TBX" >/dev/null 2>&1
    stop_status=$?
    set -e
    if (( stop_status != 0 )); then
      echo "stop failed; inspect the Testbox dashboard for the box created by this branch" >&2
    fi
  fi
  # Blacksmith's documented Testbox contract stops the box and its underlying
  # workflow run together. Issue a direct GitHub cancellation only if the
  # Testbox stop failed and the exact row URL proved which run this invocation
  # owns.
  if (( stop_status != 0 )) && [[ "$RUN_ID" =~ ^[0-9]+$ ]]; then
    say "Cancelling the warmup run this script owns after stop failure"
    if ! "$BOUNDED" "$CLEANUP_TIMEOUT" gh run cancel "$RUN_ID" --repo manaflow-ai/cmux >/dev/null 2>&1; then
      echo "cancel failed; inspect Actions for this branch's warmup run and cancel it" >&2
      status=1
    fi
    echo "cancelling takes a few minutes to land; final state:"
    "$BOUNDED" "$CLEANUP_TIMEOUT" gh api "repos/manaflow-ai/cmux/actions/runs/$RUN_ID" \
      --jq '"\(.status) \(.conclusion // "pending")"' || true
  elif [[ -n "$TBX" ]] && ! [[ "$RUN_ID" =~ ^[0-9]+$ ]]; then
    echo "could not bind an exact warmup RUN URL; refusing explicit run cancellation" >&2
    if (( status == 0 )); then
      status=1
    fi
  fi
  remove_temp_files
  exit "$status"
}
trap cleanup EXIT INT TERM

say "Warming a box from main"
echo "The workflow refuses any ref but main: it is the trust boundary, because"
echo "the CLI resolves the workflow definition from the same ref it hydrates."
warmup_log="$(mktemp)"
printf '\033[2m$ blacksmith testbox warmup %s --ref main --job %s --idle-timeout %s\033[0m\n' \
  "$WORKFLOW" "$JOB" "$IDLE_TIMEOUT"
set +e
"$BOUNDED" 300 blacksmith testbox warmup "$WORKFLOW" \
  --ref main --job "$JOB" --idle-timeout "$IDLE_TIMEOUT" | tee "$warmup_log"
pipeline_status=("${PIPESTATUS[@]}")
warmup_status="${pipeline_status[0]}"
tee_status="${pipeline_status[1]}"
set -e
if (( warmup_status != 0 )); then
  if recover_partial_testbox "$warmup_log"; then
    echo "warmup failed with status $warmup_status; exact status proof recovered the Testbox for cleanup" >&2
  else
    echo "warmup failed with status $warmup_status; refusing to adopt a Testbox ID from failed warmup transcript without an exact status proof" >&2
  fi
  exit "$warmup_status"
fi
if (( tee_status != 0 )); then
  if recover_partial_testbox "$warmup_log"; then
    echo "could not save the warmup transcript (tee status $tee_status); exact status proof recovered the Testbox for cleanup" >&2
  else
    echo "could not save the warmup transcript (tee status $tee_status); refusing to adopt a Testbox ID without an exact status proof" >&2
  fi
  exit "$tee_status"
fi
set +e
TBX="$(grep -Eo 'tbx_[A-Za-z0-9_-]+' "$warmup_log" | head -1)"
set -e
[[ "$TBX" =~ ^tbx_[A-Za-z0-9_-]+$ ]] || { echo "warmup returned no valid Testbox ID" >&2; exit 66; }
record_run_id_from_log "$warmup_log" || true
rm -f -- "$warmup_log"
warmup_log=""
# The warmup transcript may already contain the exact row. Do not issue a
# native wait before approval, because the gate keeps hydration from starting.
# The ready transition below performs bounded reconciliation after approval.

# ------------------------------------------------------------------ approve --
say "Approving the deployment gate"
echo "The run parks before its first step until a reviewer approves. Self-"
echo "approval is allowed on this environment."
if (( APPROVE )); then
  approved=0
  for _ in $(seq 1 30); do
    # Waiting-list set differences are not ownership proof. Ask the exact
    # Testbox row for its RUN URL, then approve only that numeric run.
    if [[ -z "$RUN_ID" ]]; then
      approval_status_log="$(mktemp)"
      set +e
      "$BOUNDED" "$CLEANUP_TIMEOUT" blacksmith testbox status --id "$TBX" \
        >"$approval_status_log" 2>&1
      set -e
      record_run_id_from_log "$approval_status_log" || true
      rm -f -- "$approval_status_log"
      approval_status_log=""
    fi
    if [[ "$RUN_ID" =~ ^[0-9]+$ ]]; then
      run_id="$RUN_ID"
      set +e
      env_id="$("$BOUNDED" "$CLEANUP_TIMEOUT" gh api \
        "repos/manaflow-ai/cmux/actions/runs/$run_id/pending_deployments" \
        --jq '.[0].environment.id' 2>/dev/null)"
      env_status=$?
      set -e
      if (( env_status != 0 )); then
        echo "the exact Testbox run could not be inspected for approval; refusing approval" >&2
        exit "$env_status"
      fi
      if ! [[ "$env_id" =~ ^[0-9]+$ ]]; then
        echo "the exact Testbox run returned a malformed environment ID; refusing approval" >&2
        break
      fi
      set +e
      "$BOUNDED" "$CLEANUP_TIMEOUT" gh api -X POST \
        "repos/manaflow-ai/cmux/actions/runs/$run_id/pending_deployments" \
        --input - >/dev/null 2>&1 <<JSON
{"environment_ids": [$env_id], "state": "approved", "comment": "blacksmith-testbox-demo"}
JSON
      approval_status=$?
      set -e
      if (( approval_status != 0 )); then
        echo "the exact Testbox run could not be approved; cleanup will continue" >&2
        exit "$approval_status"
      fi
      echo "approved the exact Testbox run"
      approved=1
      break
    fi
    sleep 5
  done
  if (( ! approved )); then
    echo "not approved automatically; refusing to start hydration until the run is approved" >&2
    exit 1
  fi
else
  echo "approve the waiting run in the GitHub UI now"
fi

# -------------------------------------------------------------------- ready --
say "Waiting for hydration (installs pinned Zig and Rust, fetches Cargo and Zig deps)"
ready_phase_started=1
ready_log="$(mktemp)"
set +e
"$BOUNDED" 1200 blacksmith testbox status --id "$TBX" --wait --wait-timeout 15m | tee "$ready_log"
pipeline_status=("${PIPESTATUS[@]}")
ready_status="${pipeline_status[0]}"
tee_status="${pipeline_status[1]}"
set -e
record_run_id_from_log "$ready_log" || true
if (( ready_status != 0 )); then
  exit "$ready_status"
fi
(( tee_status == 0 )) || exit "$tee_status"
if ! reconcile_run_id; then
  echo "warmup run is not yet bound; cleanup will retry from the exact Testbox row" >&2
fi

# ---------------------------------------------------------------------- pin --
say "Pinning the box to your commit"
echo "The box is an exact checkout of main right now, because that is what CI"
echo "hydrated. This makes it an exact checkout of $SOURCE_SHA."
pin_command="set -euo pipefail; git fetch --no-tags origin $SOURCE_SHA; git reset --hard $SOURCE_SHA; git submodule update --init --depth 1 ghostty; git rev-parse HEAD"
printf '\033[2m$ blacksmith testbox run --id %s "%s"\033[0m\n' "$TBX" "$pin_command"
"$BOUNDED" 300 blacksmith testbox run --id "$TBX" "$pin_command"

# -------------------------------------------------------------------- build --
if (( STAGES )); then
  say "Running the three measured stages"
  out=".cmux-scratch/testbox-demo-$(git rev-parse --short HEAD)"
  mkdir -p "$out/raw"
  for stage in first-clean incremental-noop changed-file; do
    say "Stage: $stage"
    stage_command="CMUX_TESTBOX_REMOTE=1 CMUX_TESTBOX_ID=$TBX ./scripts/blacksmith-cmux-tui-testbox-stage.sh $stage $SOURCE_SHA $GHOSTTY_SHA"
    printf '\033[2m$ blacksmith testbox run --id %s "%s"\033[0m\n' "$TBX" "$stage_command"
    "$BOUNDED" 1500 blacksmith testbox run --id "$TBX" "$stage_command"
    for suffix in json time log; do
      "$BOUNDED" 120 blacksmith testbox download --id "$TBX" \
        "testbox-benchmark/$stage.$suffix" "$out/raw/$stage.$suffix" >/dev/null
    done
  done
  say "Timings"
  python3 - "$out/raw" <<'PY'
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1])
for stage in ("first-clean", "incremental-noop", "changed-file"):
    record = json.loads((raw / f"{stage}.json").read_text())
    hydration = record["hydration"]
    print(f"{stage:18} {record['wall_seconds']:>9.3f} s   ok={record['ok']}")
    print(f"{'':18} hydrated from {hydration['ref']} {hydration['commit_sha'][:10]}, "
          f"same commit as benchmarked: {hydration['matches_benchmarked_source']}")
PY
  echo "raw records: $out/raw"
else
  say "Build 1 of 2: cold target directory, warm dependency caches"
  build_command="cd cmux-tui && cargo build -p cmux-tui --locked"
  printf '\033[2m$ blacksmith testbox run --id %s "%s"\033[0m\n' "$TBX" "$build_command"
  "$BOUNDED" 1500 blacksmith testbox run --id "$TBX" "$build_command"

  say "Build 2 of 2: nothing changed, same VM, same disk"
  echo "This is what the persistent box buys. Compare it to build 1."
  "$BOUNDED" 600 blacksmith testbox run --id "$TBX" "$build_command"
fi

say "Done. The box stops next, on the way out."
