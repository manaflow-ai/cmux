#!/usr/bin/env bash
# Decides whether this base autofix run repairs or is held: at most one run repairs per window
# (cmux-next-base-autofix.yml, "Once per window"). Prints run=true|false and why=... for $GITHUB_OUTPUT.
#
# A push run is held when an older run of this workflow on BRANCH, created within the last
# NEXT_BASE_AUTOFIX_WINDOW_MINUTES (default 120), repaired or is still in flight. A held run is cancelled by
# its window job, so it ends cancelled and base-autofix-since.sh passes over it: the next run that repairs
# diffs from the last successful one and so covers every held push. Runs that never count: cancelled and
# skipped ones (held runs among them) and the push of this workflow's own repair commit, which repairs nothing.
#
# Every other case runs, as before the window: a window of 0, a dispatch, a re-run (someone asked for it),
# and any GitHub read that fails (fail open).
#
#   base-autofix-window.sh RUN_ID [BRANCH]
# Env: GH_TOKEN (actions: read), GITHUB_REPOSITORY, GITHUB_EVENT_NAME, GITHUB_RUN_ATTEMPT,
#      NEXT_BASE_AUTOFIX_WINDOW_MINUTES; BASE_AUTOFIX_WINDOW_NOW (epoch seconds, tests only).
set -uo pipefail

run_id="${1:?usage: base-autofix-window.sh RUN_ID [BRANCH]}"
branch="${2:-feat-cmux-next}"
repo="${GITHUB_REPOSITORY:-manaflow-ai/cmux}"
window="${NEXT_BASE_AUTOFIX_WINDOW_MINUTES:-}"
[[ -n "$window" ]] || window=120

say() { printf 'run=%s\nwhy=%s\n' "$1" "$2"; }

if ! [[ "$window" =~ ^[0-9]+$ ]] || [[ "$window" == 0 ]]; then
  say true "window off (NEXT_BASE_AUTOFIX_WINDOW_MINUTES=${window})"
  exit 0
fi
if [[ "${GITHUB_EVENT_NAME:-push}" != push ]]; then
  say true "event ${GITHUB_EVENT_NAME}"
  exit 0
fi
if [[ "${GITHUB_RUN_ATTEMPT:-1}" != 1 ]]; then
  say true "re-run (attempt ${GITHUB_RUN_ATTEMPT})"
  exit 0
fi

now="${BASE_AUTOFIX_WINDOW_NOW:-$(date -u +%s)}"
since="$(date -u -d "@$((now - window * 60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || {
  say true "no clock"
  exit 0
}

# One read: this workflow's push runs on BRANCH created within the window, newest first.
rows="$(gh api "repos/$repo/actions/workflows/cmux-next-base-autofix.yml/runs?branch=$branch&event=push&created=%3E%3D$since&per_page=100" \
  --jq '.workflow_runs[] | [.id, .status, (.conclusion // ""), .display_title] | map(tostring) | join("\u001f")' 2>/dev/null)" || {
  say true "runs unreadable (fail open)"
  exit 0
}

# Fields split on the unit separator: a tab is whitespace to read, so an empty conclusion would vanish.
while IFS=$'\x1f' read -r id status conclusion title; do
  [[ -n "$id" ]] || continue
  # Only older runs hold this one: of two runs that start together, the older decides and the newer follows it.
  (( id < run_id )) || continue
  case "$title" in
    "chore(next): base autofix at "* | "chore(next): pin GhosttyKit for ghostty "*) continue ;;
  esac
  if [[ "$status" != completed ]]; then
    say false "run $id is in flight (window ${window} min)"
    exit 0
  fi
  case "$conclusion" in
    cancelled | skipped | "") continue ;;
  esac
  say false "run $id ended $conclusion within the last ${window} min"
  exit 0
done <<<"$rows"

say true "no run repaired within the last ${window} min"
