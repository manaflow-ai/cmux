#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO="manaflow-ai/cmux"
GH_BIN="${GH_BIN:-gh}"
REPO="$DEFAULT_REPO"
STATE=""
ISSUE_REF=""
RUN_ID="${CMUX_ISSUE_STATUS_RUN_ID:-}"
DETAILS=""
PR_URL=""
RELEASE=""
ALLOWED_ISSUE="${CMUX_ALLOWED_ISSUE_NUMBER:-}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  scripts/issue-status.sh <state> <issue-number-or-url> [options]

States:
  taking-a-look    Begin an agent investigation.
  needs-detail     Ask the reporter for missing reproduction or request detail.
  deferred         Explain that the work is outside the current scope.
  resolved         Comment after the linked PR has merged.

Options:
  --repo <owner/repo>       Repository. Default: manaflow-ai/cmux.
  --run-id <id>             Idempotency key for this investigation.
  --details <text>          Missing information for needs-detail.
  --pr <url-or-number>      Merged PR for resolved.
  --release <version>       Optional release containing the fix.
  --allowed-issue <number>  Restrict the command to one triggering issue.
  --dry-run                 Print the comment without posting it.
  --help                    Show this help.
EOF
}

die() {
  printf 'issue-status: %s\n' "$*" >&2
  exit 1
}

sanitize_marker_value() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._:-' '-'
}

parse_args() {
  [[ $# -ge 2 ]] || { usage >&2; exit 1; }
  STATE="$1"
  ISSUE_REF="$2"
  shift 2

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires a value"
        REPO="$2"
        shift 2
        ;;
      --run-id)
        [[ $# -ge 2 ]] || die "--run-id requires a value"
        RUN_ID="$2"
        shift 2
        ;;
      --details)
        [[ $# -ge 2 ]] || die "--details requires a value"
        DETAILS="$2"
        shift 2
        ;;
      --pr)
        [[ $# -ge 2 ]] || die "--pr requires a value"
        PR_URL="$2"
        shift 2
        ;;
      --release)
        [[ $# -ge 2 ]] || die "--release requires a value"
        RELEASE="$2"
        shift 2
        ;;
      --allowed-issue)
        [[ $# -ge 2 ]] || die "--allowed-issue requires a value"
        ALLOWED_ISSUE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown option: $1"
        ;;
    esac
  done
}

validate_state() {
  case "$STATE" in
    taking-a-look|needs-detail|deferred|resolved) ;;
    *) die "unknown state: $STATE" ;;
  esac

  [[ "$REPO" == "$DEFAULT_REPO" ]] || die "only $DEFAULT_REPO is supported"
  if [[ -z "$RUN_ID" ]]; then
    RUN_ID="local-$(git branch --show-current 2>/dev/null || printf 'manual')"
  fi
  RUN_ID="$(sanitize_marker_value "$RUN_ID")"
}

load_issue() {
  ISSUE_JSON="$("$GH_BIN" issue view "$ISSUE_REF" --repo "$REPO" --json number,url,title)"
  ISSUE_NUMBER="$(jq -r '.number // empty' <<<"$ISSUE_JSON")"
  ISSUE_URL="$(jq -r '.url // empty' <<<"$ISSUE_JSON")"
  [[ -n "$ISSUE_NUMBER" && -n "$ISSUE_URL" ]] || die "could not resolve issue: $ISSUE_REF"
  if [[ -n "$ALLOWED_ISSUE" && "$ISSUE_NUMBER" != "$ALLOWED_ISSUE" ]]; then
    die "issue $ISSUE_NUMBER does not match allowed issue $ALLOWED_ISSUE"
  fi
}

build_comment() {
  local marker
  marker="<!-- cmux-issue-status state=$STATE issue=$ISSUE_NUMBER run=$RUN_ID -->"

  case "$STATE" in
    taking-a-look)
      BODY="$marker
Taking a look at this now."
      ;;
    needs-detail)
      [[ -n "$DETAILS" ]] || die "needs-detail requires --details"
      BODY="$marker
Thanks for reporting this. We need more detail to reproduce the behavior or understand the request.

Please add:
$DETAILS

Once we have that, we can take another look."
      ;;
    deferred)
      BODY="$marker
Thanks for the suggestion. This is outside our current planned scope, so we are not taking it up right now. We may revisit it in the future."
      ;;
    resolved)
      [[ -n "$PR_URL" ]] || die "resolved requires --pr"
      PR_JSON="$("$GH_BIN" pr view "$PR_URL" --repo "$REPO" --json state,mergedAt,url)"
      PR_STATE="$(jq -r '.state // empty' <<<"$PR_JSON")"
      MERGED_AT="$(jq -r '.mergedAt // empty' <<<"$PR_JSON")"
      RESOLVED_URL="$(jq -r '.url // empty' <<<"$PR_JSON")"
      [[ "$PR_STATE" == "MERGED" && -n "$MERGED_AT" ]] || die "PR is not merged: $PR_URL"
      [[ -n "$RESOLVED_URL" ]] || die "could not resolve PR URL: $PR_URL"
      marker="<!-- cmux-issue-status state=resolved issue=$ISSUE_NUMBER pr=$(sanitize_marker_value "$RESOLVED_URL") -->"
      if [[ -n "$RELEASE" ]]; then
        BODY="$marker
Resolved in $RESOLVED_URL and included in release $RELEASE. Please let us know if you have any other questions. Thank you for helping us improve cmux."
      else
        BODY="$marker
Resolved in $RESOLVED_URL. Please let us know if you have any other questions. Thank you for helping us improve cmux."
      fi
      ;;
  esac
}

already_posted() {
  local comments marker
  marker="${BODY%%$'\n'*}"
  comments="$("$GH_BIN" issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments --jq '.comments[].body' 2>/dev/null || true)"
  grep -Fq -- "$marker" <<<"$comments"
}

main() {
  parse_args "$@"
  validate_state
  load_issue
  build_comment

  if already_posted; then
    printf 'already posted for %s: %s\n' "$ISSUE_URL" "$STATE"
    exit 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s\n' "$BODY"
    exit 0
  fi

  "$GH_BIN" issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$BODY"
}

main "$@"
