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
run_local blacksmith testbox list --all || true

echo
echo "Warming one 32 vCPU Linux VM: about 4 minutes of hydration, a few minutes"
echo "of building, then it stops itself. Ctrl-C also stops it."

# ------------------------------------------------------------------- warmup --
TBX=""
RUN_ID=""
cleanup() {
  local status=$?
  if [[ -n "$TBX" ]]; then
    say "Stopping the box this script created ($TBX)"
    blacksmith testbox stop --id "$TBX" || echo "stop failed; stop it by hand: blacksmith testbox stop --id $TBX" >&2
    blacksmith testbox list --all || true
  fi
  # Stopping the box does not end its run. The keepalive step keeps holding a
  # 32 vCPU runner until the run itself ends, so cancel it too.
  if [[ -n "$RUN_ID" ]]; then
    say "Cancelling the warmup run this script approved ($RUN_ID)"
    gh run cancel "$RUN_ID" --repo manaflow-ai/cmux >/dev/null 2>&1 \
      || echo "cancel failed; cancel it by hand: gh run cancel $RUN_ID --repo manaflow-ai/cmux" >&2
    echo "cancelling takes a few minutes to land; final state:"
    gh api "repos/manaflow-ai/cmux/actions/runs/$RUN_ID" --jq '"\(.status) \(.conclusion // "pending")"' || true
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

say "Warming a box from main"
echo "The workflow refuses any ref but main: it is the trust boundary, because"
echo "the CLI resolves the workflow definition from the same ref it hydrates."
# Snapshot the gates already waiting before dispatching. Set difference against
# this identifies our run exactly; a time window cannot, because another agent
# dispatching seconds later lands inside any window we pick.
lane_runs_url="repos/manaflow-ai/cmux/actions/workflows/$(basename "$WORKFLOW")/runs?event=workflow_dispatch&status=waiting"
waiting_before="$(mktemp)"
waiting_now="$(mktemp)"
gh api "$lane_runs_url" --jq '.workflow_runs[].id' | sort >"$waiting_before"
warmup_log="$(mktemp)"
printf '\033[2m$ blacksmith testbox warmup %s --ref main --job %s --idle-timeout %s\033[0m\n' \
  "$WORKFLOW" "$JOB" "$IDLE_TIMEOUT"
"$BOUNDED" 300 blacksmith testbox warmup "$WORKFLOW" \
  --ref main --job "$JOB" --idle-timeout "$IDLE_TIMEOUT" | tee "$warmup_log"
TBX="$(grep -Eo 'tbx_[A-Za-z0-9_-]+' "$warmup_log" | head -1)"
rm -f "$warmup_log"
[[ -n "$TBX" ]] || { echo "warmup returned no Testbox ID" >&2; exit 66; }

# ------------------------------------------------------------------ approve --
say "Approving the deployment gate"
echo "The run parks before its first step until a reviewer approves. Self-"
echo "approval is allowed on this environment."
if (( APPROVE )); then
  approved=0
  for _ in $(seq 1 30); do
    # Our run is the one that appeared since the snapshot. Kept portable to bash
    # 3.2, which is what macOS ships: no mapfile, no process substitution.
    gh api "$lane_runs_url" --jq '.workflow_runs[].id' 2>/dev/null | sort >"$waiting_now" || true
    candidates="$(comm -13 "$waiting_before" "$waiting_now")"
    candidate_count="$(printf '%s' "$candidates" | grep -c . || true)"
    if (( candidate_count > 1 )); then
      echo "$candidate_count runs appeared at once; approve yours in the GitHub UI, or rerun this script" >&2
      break
    fi
    if (( candidate_count == 1 )); then
      run_id="$candidates"
      env_id="$(gh api "repos/manaflow-ai/cmux/actions/runs/$run_id/pending_deployments" --jq '.[0].environment.id')"
      gh api -X POST "repos/manaflow-ai/cmux/actions/runs/$run_id/pending_deployments" \
        --input - >/dev/null <<JSON
{"environment_ids": [$env_id], "state": "approved", "comment": "blacksmith-testbox-demo"}
JSON
      echo "approved run $run_id"
      RUN_ID="$run_id"
      approved=1
      break
    fi
    sleep 5
  done
  (( approved )) || echo "not approved automatically; approve the run in the GitHub UI now" >&2
else
  echo "approve the waiting run in the GitHub UI now"
fi

# -------------------------------------------------------------------- ready --
say "Waiting for hydration (installs pinned Zig and Rust, fetches Cargo and Zig deps)"
"$BOUNDED" 1200 blacksmith testbox status --id "$TBX" --wait --wait-timeout 15m

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
