#!/bin/bash
set -euo pipefail

# Source bashrc to ensure PATH, shell functions (claudem / claudeg / claudew), and env load.
if [[ -f "${HOME}/.bashrc" ]]; then
  if ! source "${HOME}/.bashrc"; then
    printf 'Error: failed to source %s\n' "${HOME}/.bashrc" >&2
    exit 1
  fi
fi

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <time-HH:MM> [branch-name] [flags|launcher ...]"
  echo ""
  echo "  branch-name      Optional. If omitted, uses the current git branch."
  echo "  --continue       Resume with Claude --continue (default)."
  echo "  --fresh          Start a new session (no --continue)."
  echo "  claudem|claudeg|claudew|claudeme"
  echo "                   Use your ~/.bashrc wrapper instead of plain claude (Minimax / Z.AI GLM / Wafer)."
  echo ""
  echo "Examples:"
  echo "  $0 09:30                              # at 09:30: default claude, --continue, current branch"
  echo "  $0 09:30 feature/foo claudem          # Minimax wrapper, same resume behavior"
  echo "  $0 09:30 claudew --fresh              # Wafer session, new conversation"
  exit 1
fi

SCHEDULE_TIME="$1"
shift

# Default matches historical behavior: always pass --continue to claude.
USE_CONTINUE=true
LAUNCHER="claude"
REMOTE_BRANCH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --continue)
      USE_CONTINUE=true
      ;;
    --fresh | --no-continue)
      USE_CONTINUE=false
      ;;
    claudem | claudeg | claudew | claudeme)
      LAUNCHER="$1"
      ;;
    -*)
      echo "Error: unknown option: $1"
      exit 1
      ;;
    *)
      if [ -n "$REMOTE_BRANCH" ]; then
        echo "Error: unexpected extra argument: $1 (branch already set to $REMOTE_BRANCH)"
        exit 1
      fi
      REMOTE_BRANCH="$1"
      ;;
  esac
  shift
done

# Ensure the time is in HH:MM 24-hour format
if ! [[ "$SCHEDULE_TIME" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  echo "Error: time must be in HH:MM 24-hour format"
  exit 1
fi

# Resolve branch if not provided (with detached-HEAD guard)
if [ -z "$REMOTE_BRANCH" ]; then
  REMOTE_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git branch --show-current || git rev-parse --abbrev-ref HEAD 2>/dev/null)
fi
if [ -z "$REMOTE_BRANCH" ] || [ "$REMOTE_BRANCH" = "HEAD" ]; then
  echo "Error: Could not determine current branch (detached HEAD?). Please specify a branch name or ensure you are in a valid Git repository."
  exit 1
fi

# Gather context uniformly for the resolved branch
echo "Gathering context for branch: $REMOTE_BRANCH"

# Check for an open PR on this branch using the 'gh' CLI tool
PR_INFO=""
if command -v gh >/dev/null 2>&1; then
  PR_INFO=$(gh pr list --head "$REMOTE_BRANCH" --state open --json number,title,url 2>/dev/null | jq -r '.[] | "PR #\(.number): \(.title)"' 2>/dev/null || echo "")
fi

# Check for a scratchpad file for additional context
SCRATCHPAD_INFO=""
SCRATCHPAD_FILE="roadmap/scratchpad_${REMOTE_BRANCH}.md"
if [ -f "$SCRATCHPAD_FILE" ]; then
  # Get the first few relevant lines of the scratchpad for context
  SCRATCHPAD_INFO=$(head -n 10 "$SCRATCHPAD_FILE" 2>/dev/null | grep -E "(Goal:|Task:|Current:|Status:)" | head -n 3 | tr '\n' ' ' || echo "")
fi

# Determine the default branch name (e.g., main, master, etc.)
# Use command substitution that won't fail with set -euo pipefail
DEFAULT_BRANCH=""
if git symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
  DEFAULT_BRANCH=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
fi
if [ -z "$DEFAULT_BRANCH" ]; then
  # Fallback to 'main' if we can't determine the default branch
  DEFAULT_BRANCH="main"
fi

# Get recent commit messages from the current branch (not on default branch)
BRANCH_FOR_LOG="$REMOTE_BRANCH"
if [ -z "$BRANCH_FOR_LOG" ]; then
  BRANCH_FOR_LOG=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git branch --show-current)
fi
RECENT_COMMITS=$(git log --oneline -3 origin/"$DEFAULT_BRANCH".."$BRANCH_FOR_LOG" 2>/dev/null | sed 's/^/  /' || echo "")

# Check for a TODO file that might provide context
TODO_INFO=""
TODO_FILE="TODO_${REMOTE_BRANCH}.md"
if [ -f "$TODO_FILE" ]; then
  TODO_INFO=$(head -n 5 "$TODO_FILE" 2>/dev/null | tr '\n' ' ' || echo "")
fi

# Build a comprehensive context message for the CLI (resume vs fresh wording).
if [ "$USE_CONTINUE" = true ]; then
  BRANCH_MESSAGE="Resume work on branch: $REMOTE_BRANCH"
else
  BRANCH_MESSAGE="Start a new session for branch: $REMOTE_BRANCH"
fi

if [ -n "$PR_INFO" ]; then
  BRANCH_MESSAGE="$BRANCH_MESSAGE. Active $PR_INFO"
fi

if [ -n "$SCRATCHPAD_INFO" ]; then
  BRANCH_MESSAGE="$BRANCH_MESSAGE. Context: $SCRATCHPAD_INFO"
fi

if [ -n "$TODO_INFO" ]; then
  BRANCH_MESSAGE="$BRANCH_MESSAGE. TODO: $TODO_INFO"
fi

if [ -n "$RECENT_COMMITS" ]; then
  BRANCH_MESSAGE+=$'\n'"$RECENT_COMMITS"
fi

if [ "$USE_CONTINUE" = true ]; then
  BRANCH_MESSAGE+=$'\n\nPlease review conversation history and any existing context to continue the work appropriately.'
else
  BRANCH_MESSAGE+=$'\n\nThis is a new session: use only the repository context above (no prior assistant thread).'
fi

# --- SCHEDULING LOGIC ---
# Calculate the number of seconds to wait until the scheduled time.
# Cross-platform compatible date handling for GNU/Linux and macOS/BSD systems.

# Get current time in seconds since epoch
CURRENT_SECONDS=$(date +%s)

# Get target time in seconds since epoch (cross-platform compatible)
if [[ "$OSTYPE" == "darwin"* ]] || [[ "$OSTYPE" == "freebsd"* ]]; then
  # macOS/BSD date syntax
  TARGET_SECONDS=$(date -j -f "%H:%M" "$SCHEDULE_TIME" "+%s" 2>/dev/null)
  if [ $? -ne 0 ]; then
    echo "Error: Invalid time format for macOS/BSD date command"
    exit 1
  fi
else
  # GNU/Linux date syntax
  TARGET_SECONDS=$(date -d "$SCHEDULE_TIME" +%s 2>/dev/null)
  if [ $? -ne 0 ]; then
    echo "Error: Invalid time format for GNU date command"
    exit 1
  fi
fi

# If the target time has already passed today, schedule it for the same time tomorrow.
if [ "$TARGET_SECONDS" -lt "$CURRENT_SECONDS" ]; then
  TARGET_SECONDS=$((TARGET_SECONDS + 86400)) # Add 24 hours in seconds
fi

SLEEP_DURATION=$((TARGET_SECONDS - CURRENT_SECONDS))

# Validate sleep duration is reasonable (not negative, not more than 24 hours)
if [ "$SLEEP_DURATION" -lt 0 ] || [ "$SLEEP_DURATION" -gt 86400 ]; then
  echo "Error: Calculated sleep duration ($SLEEP_DURATION seconds) is invalid"
  exit 1
fi

# Format target time for display (cross-platform compatible)
if [[ "$OSTYPE" == "darwin"* ]] || [[ "$OSTYPE" == "freebsd"* ]]; then
  TARGET_TIME_DISPLAY=$(date -r "$TARGET_SECONDS" "+%Y-%m-%d %H:%M:%S")
else
  TARGET_TIME_DISPLAY=$(date -d "@$TARGET_SECONDS" "+%Y-%m-%d %H:%M:%S")
fi

echo "Waiting for $SLEEP_DURATION seconds until $TARGET_TIME_DISPLAY..."
echo "Press Ctrl+C to cancel."

# Set up signal handler to gracefully handle interruption
trap 'echo "\nScheduling cancelled by user."; exit 130' INT TERM

# Wait until the scheduled time and validate successful completion
if ! sleep "$SLEEP_DURATION"; then
  echo "Error: Sleep command was interrupted or failed"
  exit 1
fi

echo "Time reached! Launching ${LAUNCHER}..."

# Run Claude (or a ~/.bashrc wrapper) with the gathered context as the initial prompt.
# Wrappers (claudem / claudeg / claudew) already set provider URLs, models, and
# --dangerously-skip-permissions; pass only --continue and the message.

if [[ "$LAUNCHER" == "claude" ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "Error: 'claude' CLI not found in PATH."
    exit 127
  fi
  if [ "$USE_CONTINUE" = true ]; then
    claude --dangerously-skip-permissions --model sonnet --continue "$BRANCH_MESSAGE"
  else
    claude --dangerously-skip-permissions --model sonnet "$BRANCH_MESSAGE"
  fi
else
  if ! declare -F "$LAUNCHER" >/dev/null 2>&1; then
    echo "Error: shell function '$LAUNCHER' not found after sourcing ~/.bashrc."
    echo "Define it in ~/.bashrc, or run without a launcher token to use the stock claude CLI."
    exit 127
  fi
  if [ "$USE_CONTINUE" = true ]; then
    "$LAUNCHER" --continue "$BRANCH_MESSAGE"
  else
    "$LAUNCHER" "$BRANCH_MESSAGE"
  fi
fi
