#!/bin/bash
# Nightly Daybreak security audit of new commits (cmux feat-cmux-next and cmuxterm-hq main).
#
# Runs Daybreak Blue Codex workers (gpt-daybreak-blue-latest through subrouter, account
# lawrence@manaflow.ai) read-only over the commits pushed since the last audited sha, one
# worker per path lane, and writes one report per lane. Critical or high findings raise a
# cmux notification. Installed by install.sh as a stable copy outside any checkout, so a
# pushed change to this file runs only after someone reinstalls it.
#
# Usage: nightly.sh [--dry-run] [--since <git date>]
#   --dry-run      print the lanes and ranges, start no worker, keep the state unchanged
#   --since DATE   ignore the saved state and audit commits since DATE (default first run: 26 hours)
set -uo pipefail

DRY_RUN=0; SINCE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --since) SINCE_OVERRIDE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

STATE_DIR="${CMUX_DAYBREAK_STATE_DIR:-$HOME/Library/Application Support/cmux-daybreak}"
OUT_ROOT="${CMUX_DAYBREAK_OUT_DIR:-$HOME/fun/cmux-worktrees/security-audit/nightly}"
WT_ROOT="${CMUX_DAYBREAK_WORKTREE_DIR:-$HOME/fun/cmux-worktrees}"
MODEL="${CMUX_DAYBREAK_MODEL:-gpt-daybreak-blue-latest}"
ACCOUNT="${CMUX_DAYBREAK_ACCOUNT:-lawrence@manaflow.ai}"
MAX_PARALLEL="${CMUX_DAYBREAK_PARALLEL:-4}"
# A worker can hang on the model stream with no error; stop it after this many seconds.
LANE_TIMEOUT="${CMUX_DAYBREAK_LANE_TIMEOUT:-5400}"
PROMPT_FILE="${CMUX_DAYBREAK_PROMPT:-$STATE_DIR/prompt.md}"
[[ -f "$PROMPT_FILE" ]] || PROMPT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/prompt.md"

# name|checkout|branch|lanes ("lane=pathspec,pathspec;...")
REPOS=(
  "cmux|$HOME/fun/cmux|feat-cmux-next|app=Packages/macOS,Sources,Resources,webviews,cmuxUITests;rust=cmux-tui,Native,cmuxd;cloud=web,backend,workers;mobile=cmux-next-ios,Packages/iOS,Packages/Shared;ci=.github,scripts,ops,tests,Makefile,package.json,bun.lock"
  "hq|$HOME/fun/cmuxterm-hq|main|all=."
)

# Tests replace the repo list: one "name|checkout|branch|lanes" entry per line.
if [[ -n "${CMUX_DAYBREAK_REPOS:-}" ]]; then
  REPOS=(); while IFS= read -r l; do [[ -n "$l" ]] && REPOS+=("$l"); done <<< "$CMUX_DAYBREAK_REPOS"
fi

DATE="$(date +%Y-%m-%d)"
OUT_DIR="$OUT_ROOT/$DATE"
mkdir -p "$STATE_DIR" "$OUT_DIR"
chmod 700 "$STATE_DIR"
LOCK="$STATE_DIR/lock"
if ! mkdir "$LOCK" 2>/dev/null; then echo "another run holds $LOCK" >&2; exit 0; fi
trap 'rmdir "$LOCK"' EXIT

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$OUT_DIR/run.log" >&2; }

run_lane() { # repo lane wt range pathspecs...
  local repo="$1" lane="$2" wt="$3" range="$4"; shift 4
  local out="$OUT_DIR/$repo-$lane.md" prompt
  rm -f "$out"
  prompt="$(sed -e "s|{{REPO}}|$repo|g" -e "s|{{LANE}}|$lane|g" -e "s|{{RANGE}}|$range|g" \
    -e "s|{{PATHS}}|$*|g" -e "s|{{OUT}}|$out|g" "$PROMPT_FILE")"
  ( cd "$wt" && exec env SUBROUTER_CODEX_ACCOUNT_ID="$ACCOUNT" sr codex exec --json -m "$MODEL" \
      -s read-only --skip-git-repo-check -o "$out" "$prompt" \
      > "$OUT_DIR/$repo-$lane.jsonl" 2> "$OUT_DIR/$repo-$lane.err" ) &
  local worker=$!
  # sr runs codex as a child; stop the children too, or codex keeps running orphaned.
  ( sleep "$LANE_TIMEOUT"; pkill -TERM -P "$worker" 2>/dev/null; kill -TERM "$worker" 2>/dev/null ) &
  local watchdog=$!
  wait "$worker"; local rc=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  if [[ $rc -ne 0 ]]; then log "$repo/$lane: worker exited $rc (143 = lane timeout)"; fi
  [[ -s "$out" ]] && grep -q '^COUNTS ' "$out"
}

FAILED=0
declare -a NEW_STATE=()
for entry in "${REPOS[@]}"; do
  IFS='|' read -r repo checkout branch lanes <<< "$entry"
  [[ -d "$checkout/.git" || -f "$checkout/.git" ]] || { log "$repo: no checkout at $checkout"; continue; }
  git -C "$checkout" fetch -q origin "$branch" || { log "$repo: fetch failed"; FAILED=1; continue; }
  new="$(git -C "$checkout" rev-parse "origin/$branch")"
  state_file="$STATE_DIR/last-$repo.sha"
  old=""
  if [[ -z "$SINCE_OVERRIDE" && -s "$state_file" ]]; then old="$(<"$state_file")"; fi
  if [[ -n "$old" ]] && ! git -C "$checkout" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then old=""; fi
  if [[ -z "$old" ]]; then
    old="$(git -C "$checkout" rev-list -1 --before="${SINCE_OVERRIDE:-26 hours ago}" "$new")"
  fi
  if [[ -z "$old" || "$old" == "$new" ]]; then log "$repo: nothing new"; continue; fi
  range="$old..$new"
  wt="$WT_ROOT/daybreak-nightly-$repo"
  if [[ $DRY_RUN -eq 0 ]]; then
    if [[ ! -e "$wt" ]]; then git -C "$checkout" worktree add -q --detach "$wt" "$new" || { FAILED=1; continue; }; fi
    git -C "$wt" checkout -q --detach "$new" || { FAILED=1; continue; }
  fi
  IFS=';' read -ra lane_list <<< "$lanes"
  pids=(); lane_failed=0
  for lane_spec in "${lane_list[@]}"; do
    lane="${lane_spec%%=*}"; IFS=',' read -ra paths <<< "${lane_spec#*=}"
    count="$(git -C "$checkout" log --oneline "$range" -- "${paths[@]}" | wc -l | tr -d ' ')"
    log "$repo/$lane: $count commits in $range"
    [[ "$count" -gt 0 ]] || continue
    [[ $DRY_RUN -eq 1 ]] && continue
    run_lane "$repo" "$lane" "$wt" "$range" "${paths[@]}" &
    pids+=("$!")
    # /bin/bash 3.2 has no `wait -n`: wait for the whole batch when it is full.
    if [[ ${#pids[@]} -ge $MAX_PARALLEL ]]; then
      for p in "${pids[@]}"; do wait "$p" || lane_failed=1; done; pids=()
    fi
  done
  for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || lane_failed=1; done
  if [[ $lane_failed -eq 0 ]]; then NEW_STATE+=("$state_file|$new"); else FAILED=1; fi
done

[[ $DRY_RUN -eq 1 ]] && exit 0

crit=0; high=0
for f in "$OUT_DIR"/*.md; do
  [[ -f "$f" ]] || continue
  line="$(grep -E '^COUNTS ' "$f" | tail -1)"
  c="$(sed -nE 's/.*critical=([0-9]+).*/\1/p' <<< "$line")"; h="$(sed -nE 's/.*high=([0-9]+).*/\1/p' <<< "$line")"
  crit=$((crit + ${c:-0})); high=$((high + ${h:-0}))
done
log "totals: critical=$crit high=$high failed=$FAILED"
for s in ${NEW_STATE[@]+"${NEW_STATE[@]}"}; do printf '%s\n' "${s#*|}" > "${s%%|*}"; done

if [[ $((crit + high)) -gt 0 ]]; then
  cmux notification create --level error --title "Daybreak nightly: $crit critical, $high high" \
    --body "Reports in $OUT_DIR" >/dev/null 2>&1 || true
elif [[ $FAILED -ne 0 ]]; then
  cmux notification create --level warning --title "Daybreak nightly did not finish" \
    --body "See $OUT_DIR/run.log" >/dev/null 2>&1 || true
fi
exit $FAILED
