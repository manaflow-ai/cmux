#!/usr/bin/env bash
# Ralph Wiggum Technique: Keep running Claude Code until all beads issues are done
# "I'm helping! I'm helping!" - Ralph Wiggum
#
# Usage:
#   ./scripts/ralph.sh [--label <label>] [--max-iterations <n>] [--dry-run]
#
# Examples:
#   ./scripts/ralph.sh                    # Work through all open issues
#   ./scripts/ralph.sh --label austin     # Only issues with 'austin' label
#   ./scripts/ralph.sh --max-iterations 5 # Stop after 5 iterations
#   ./scripts/ralph.sh --dry-run          # Show what would run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Default config
LABEL=""
MAX_ITERATIONS=100
DRY_RUN=false
SESSION_ID=""
CONTINUE_SESSION=false

# Auto-detect label from current git branch if not provided
get_branch_label() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --label)
      LABEL="$2"
      shift 2
      ;;
    --max-iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --continue)
      CONTINUE_SESSION=true
      shift
      ;;
    --session)
      SESSION_ID="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Auto-detect label from branch if not provided
if [[ -z "$LABEL" ]]; then
  LABEL=$(get_branch_label)
  if [[ -z "$LABEL" ]]; then
    echo "ERROR: Could not detect git branch and no --label provided."
    echo "Branch name is REQUIRED as the label for all beads work."
    echo "Either run from a git repo or provide --label explicitly."
    exit 1
  fi
  echo "Auto-detected label from branch: $LABEL"
fi

# Build bd list command - ALWAYS filter by label (branch name)
bd_list_cmd="bd ready --label $LABEL"

# Count remaining issues
count_remaining() {
  $bd_list_cmd --json 2>/dev/null | jq -r 'length' || echo "0"
}

# Get next issue to work on
get_next_issue() {
  $bd_list_cmd --json --limit 1 2>/dev/null | jq -r '.[0].id // empty'
}

# Get issue title
get_issue_title() {
  local id="$1"
  bd show "$id" --json 2>/dev/null | jq -r '.title // "Unknown"'
}

# Log with timestamp
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Main loop
iteration=0
log "Starting Ralph Wiggum loop..."
log "Label (branch): $LABEL"
log "Max iterations: $MAX_ITERATIONS"

while true; do
  iteration=$((iteration + 1))

  if [[ $iteration -gt $MAX_ITERATIONS ]]; then
    log "Reached max iterations ($MAX_ITERATIONS). Stopping."
    break
  fi

  remaining=$(count_remaining)
  log "Iteration $iteration: $remaining issues remaining"

  if [[ "$remaining" == "0" ]]; then
    log "All issues complete! Ralph is done helping."
    break
  fi

  next_issue=$(get_next_issue)
  if [[ -z "$next_issue" ]]; then
    log "No issues ready to work on. Stopping."
    break
  fi

  issue_title=$(get_issue_title "$next_issue")
  log "Working on: $next_issue - $issue_title"

  # Build the prompt
  PROMPT="You are in Ralph Wiggum mode - keep working until all beads issues are done.

Current issue to work on: $next_issue
Title: $issue_title
Branch/Label: $LABEL

Instructions:
1. Run 'bd update $next_issue --status=in_progress' to claim the issue
2. Run 'bd show $next_issue' to see full details
3. Complete the work required for this issue
4. Run 'bd close $next_issue' when done
5. Check 'bd ready --label $LABEL' for remaining work
6. If there are more issues, continue with the next one
7. If context is getting full, summarize progress and stop cleanly

IMPORTANT:
- Always run 'bd sync' before stopping to save your progress
- When creating new issues, ALWAYS use: bd create --title=\"...\" --labels $LABEL
- Never create issues without the branch label ($LABEL)"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would run claude with prompt:"
    echo "$PROMPT"
    echo "---"
    break
  fi

  # Build claude command
  CLAUDE_CMD="claude -p"

  # Continue previous session if requested or if we have a session ID
  if [[ "$CONTINUE_SESSION" == "true" ]] && [[ $iteration -gt 1 ]]; then
    CLAUDE_CMD="$CLAUDE_CMD --continue"
  elif [[ -n "$SESSION_ID" ]]; then
    CLAUDE_CMD="$CLAUDE_CMD --resume $SESSION_ID"
  fi

  # Run Claude Code
  log "Launching Claude Code..."

  # Capture the output and session info
  set +e
  OUTPUT=$($CLAUDE_CMD "$PROMPT" 2>&1)
  EXIT_CODE=$?
  set -e

  echo "$OUTPUT"

  if [[ $EXIT_CODE -ne 0 ]]; then
    log "Claude exited with code $EXIT_CODE"
    # Check if it was a context exhaustion
    if echo "$OUTPUT" | grep -qi "context\|token\|limit"; then
      log "Possible context exhaustion. Continuing with fresh session..."
      CONTINUE_SESSION=false
      continue
    fi
  fi

  # Sync beads after each iteration
  log "Syncing beads..."
  bd sync 2>/dev/null || true

  # Small delay between iterations
  sleep 2
done

log "Ralph Wiggum session complete!"
log "Final stats:"
bd stats 2>/dev/null || true
