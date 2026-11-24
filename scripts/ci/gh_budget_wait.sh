#!/bin/bash
# gh, except that a GitHub API rate-limit refusal waits for the budget to reset
# and tries again instead of failing the job.
#
# Every workflow shares one installation budget an hour. When something else has
# spent it, a nightly's publish path used to fail on its next gh call and throw a
# finished, signed build away (2026-10-26: run 40298250989 failed in
# legacy-identity-target's feed compare and in the daemon attestation). Waiting
# for the reset relaxes nothing: the same call runs, with the same token, later.
#
#   gh_budget_wait.sh --install      put this wrapper first on PATH as `gh` for the
#                                    rest of the job (GITHUB_PATH); every later gh
#                                    call, scripts' included, goes through it
#   gh_budget_wait.sh --reserve N    wait (once, bounded) until the core budget has
#                                    at least N calls left; never fails
#
# A refused call is tried at most GH_BUDGET_WAIT_ATTEMPTS times (default 6), and
# one job waits at most GH_BUDGET_WAIT_MAX_SECONDS in all (default 3600, the
# longest a reset can be away); each wait is logged. A budget whose reset is
# further away than the job has left to wait fails at once instead of sleeping
# into the same refusal. Reading /rate_limit costs nothing. A refused request did
# nothing on GitHub's side, so retrying a write is safe. Standard input is
# replayed only when the call reads it (`--input -`, `@-`, `-F -`); otherwise it
# is left alone for the caller.
#
# GitHub's own server errors (HTTP 5xx) are tried again too, after 10, 20 and
# 40 s, at most GH_BUDGET_WAIT_5XX_ATTEMPTS tries in all (default 4), within the
# same job total. A limit or server error that outlasts every try fails loud
# (an ::error annotation, or the step summary when stderr is read as data).
#
# --install also copies gh_budget_wait.cjs, the same waits for actions/github-script
# steps, next to the wrapper and names it in GH_BUDGET_WAIT_JS (GITHUB_ENV):
#   if (process.env.GH_BUDGET_WAIT_JS) require(process.env.GH_BUDGET_WAIT_JS).install({ github, core });
# (The guard keeps the scripts runnable by test harnesses that have no wrapper.)
# Runs on macOS's bash 3.2.

REAL_GH=gh # --install writes the real gh's path here

set -u

ledger_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gh-budget-wait"
max_total="${GH_BUDGET_WAIT_MAX_SECONDS:-3600}"
attempts="${GH_BUDGET_WAIT_ATTEMPTS:-6}"
server_attempts="${GH_BUDGET_WAIT_5XX_ATTEMPTS:-4}"

# No ledger yet is nothing waited; one that cannot be read or parsed counts as the whole
# budget spent (fail closed: an earlier step's waits are unknown).
waited_so_far() {
  local spent
  [ -e "$ledger_dir/waited" ] || { echo 0; return; }
  spent="$(cat "$ledger_dir/waited" 2>/dev/null)" || { echo "$max_total"; return; }
  case "$spent" in '' | *[!0-9]*) echo "$max_total" ;; *) echo "$spent" ;; esac
}

# Seconds until the exhausted budget resets (core, graphql or search). When none reads
# exhausted, the refusal is GitHub's secondary limit on bursts (it sends no reset; all of
# the repository's GITHUB_TOKENs count as one actor), so back off: 60 s on the first try,
# then 120, 240 and 300 s per wait. $1 is the try number. Prints the seconds and
# `reset` (an exhausted budget's own reset) or `backoff`.
seconds_to_reset() {
  local now reset left try="${1:-1}"
  now="$(date +%s)"
  reset="$("$REAL_GH" api rate_limit --jq \
    '[.resources.core, .resources.graphql, .resources.search] | map(select(.remaining == 0) | .reset) | max // 0' \
    2>/dev/null || echo 0)"
  case "$reset" in '' | *[!0-9]*) reset=0 ;; esac
  if [ "$reset" -gt "$now" ]; then
    echo "$((reset - now + 5)) reset"
  else
    left=$((60 << (try - 1)))
    [ "$left" -le 300 ] || left=300
    echo "$left backoff"
  fi
}

# Seconds until the core budget resets, for --reserve.
seconds_to_reset_core() {
  local now reset
  now="$(date +%s)"
  reset="$("$REAL_GH" api rate_limit --jq '.resources.core.reset' 2>/dev/null || echo 0)"
  case "$reset" in '' | *[!0-9]*) reset=0 ;; esac
  if [ "$reset" -gt "$now" ]; then echo $((reset - now + 5)); else echo 60; fi
}

# Log a wait. A caller that reads stderr with stdout (`2>&1`, as the nightly guard scripts that
# compare an exact status do) would get the notice in its data, so then it goes to the step
# summary instead. Every wait is also kept in the job's ledger directory.
log_wait() {
  { mkdir -p "$ledger_dir" && echo "$(date -u +%H:%M:%SZ) $1" >>"$ledger_dir/waits.log"; } 2>/dev/null
  if [ /dev/fd/1 -ef /dev/fd/2 ]; then
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "- GitHub API budget: $1" >>"$GITHUB_STEP_SUMMARY"
  else
    echo "::notice title=GitHub API budget::$1" >&2
  fi
}

# A call that failed through every retry: an error annotation, or the step summary when the
# caller reads stderr with stdout (the annotation would land in its data).
log_error() {
  { mkdir -p "$ledger_dir" && echo "$(date -u +%H:%M:%SZ) FAILED: $1" >>"$ledger_dir/waits.log"; } 2>/dev/null
  if [ /dev/fd/1 -ef /dev/fd/2 ]; then
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "- GitHub API: $1" >>"$GITHUB_STEP_SUMMARY"
  else
    echo "::error title=GitHub API::$1" >&2
  fi
}

# Which limiter refused a call: GitHub's own message (with its request id), and the token's
# /rate_limit headers and resources at that moment (the read costs nothing). A refusal while
# every resource there has calls left is a limit /rate_limit does not report (secondary).
# Once per job; written to the job's ledger directory and, when stderr is its own stream, as
# a notice.
log_refusal() {
  mkdir -p "$ledger_dir"
  [ ! -e "$ledger_dir/refusal-logged" ] || return 0
  : >"$ledger_dir/refusal-logged"
  local message probe
  message="$(tr '\n' ' ' <"$work/err" | cut -c1-400) $(tr '\n' ' ' <"$work/out" | cut -c1-200)"
  probe="$("$REAL_GH" api --include rate_limit 2>&1 | tr -d '\r' |
    grep -iE '^(HTTP/|x-ratelimit-|retry-after|x-github-request-id)|"(core|graphql|search|integration_manifest|actions_runner_registration)"' |
    tr '\n' ' ' | cut -c1-900)"
  {
    echo "$(date -u +%H:%M:%SZ) refused: gh ${1:-} ${2:-}: $message"
    echo "$(date -u +%H:%M:%SZ) /rate_limit then: $probe"
  } >>"$ledger_dir/waits.log"
  if ! [ /dev/fd/1 -ef /dev/fd/2 ]; then
    echo "::notice title=GitHub API refusal::gh ${1:-} ${2:-}: $message | /rate_limit then: $probe" >&2
  elif [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "- GitHub API refusal: gh ${1:-} ${2:-}: $message | /rate_limit then: $probe" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# Sleep for $1 seconds within this job's total, logging why. Fails when the total is spent.
wait_for_budget() {
  local want="$1" why="$2" spent remaining
  spent="$(waited_so_far)"
  remaining=$((max_total - spent))
  [ "$remaining" -gt 0 ] || return 1
  [ "$want" -le "$remaining" ] || want="$remaining"
  # Reserved before sleeping, so a caller's timeout that kills this mid-wait still leaves it counted.
  # A reservation that cannot be written is not waited (later steps could not see it).
  mkdir -p "$ledger_dir" 2>/dev/null &&
    echo $((spent + want)) 2>/dev/null >"$ledger_dir/waited.$$" &&
    mv -f "$ledger_dir/waited.$$" "$ledger_dir/waited" 2>/dev/null || {
    log_wait "could not record a ${want}s wait in $ledger_dir/waited; not waiting"
    return 1
  }
  log_wait "$why; waiting ${want}s for the budget to reset (${spent}s waited in this job so far)"
  sleep "$want"
}

if [ "${1:-}" = "--install" ]; then
  # The github-script half needs no gh: copy it first, so a step's require() finds it.
  js="$(dirname "$0")/gh_budget_wait.cjs"
  if [ -f "$js" ] && mkdir -p "$ledger_dir" && cp "$js" "$ledger_dir/gh_budget_wait.cjs"; then
    [ -z "${GITHUB_ENV:-}" ] || echo "GH_BUDGET_WAIT_JS=$ledger_dir/gh_budget_wait.cjs" >>"$GITHUB_ENV"
  else
    echo "::warning title=GitHub API budget::no gh_budget_wait.cjs beside this script; github-script steps in this job will not wait through a rate limit"
  fi
  real="$(command -v gh 2>/dev/null || true)"
  if [ -z "$real" ] || [ -z "${GITHUB_PATH:-}" ]; then
    echo "::warning title=GitHub API budget::no gh or GITHUB_PATH; gh calls in this job will not wait through a rate limit"
    exit 0
  fi
  mkdir -p "$ledger_dir/bin"
  sed "s|^REAL_GH=gh |REAL_GH='$real' |" "$0" >"$ledger_dir/bin/gh"
  chmod +x "$ledger_dir/bin/gh"
  echo "$ledger_dir/bin" >>"$GITHUB_PATH"
  echo "gh calls in this job wait through a rate limit (real gh: $real)"
  exit 0
fi

if [ "${1:-}" = "--reserve" ]; then
  want="${2:-200}"
  left="$("$REAL_GH" api rate_limit --jq '.resources.core.remaining' 2>/dev/null || echo "")"
  case "$left" in '' | *[!0-9]*) exit 0 ;; esac
  if [ "$left" -lt "$want" ]; then
    wait_for_budget "$(seconds_to_reset_core)" "the core budget has $left calls left, under $want" || true
  fi
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/gh-budget-wait.XXXXXX")" || exec "$REAL_GH" "$@"
trap 'rm -rf "$work"' EXIT

stdin_file=""
for arg in "$@"; do
  case "$arg" in
    - | *@- | --input=- | --body-file=-) stdin_file="$work/stdin" ;;
  esac
done
[ -z "$stdin_file" ] || cat >"$stdin_file"

try=1
server_tries=0
gave_up=""
while :; do
  if [ -n "$stdin_file" ]; then
    "$REAL_GH" "$@" <"$stdin_file" >"$work/out" 2>"$work/err"
  else
    "$REAL_GH" "$@" >"$work/out" 2>"$work/err"
  fi
  rc=$?
  [ "$rc" -ne 0 ] || { gave_up=""; break; }
  if grep -qiE 'rate limit exceeded|secondary rate limit|abuse detection|too many requests|HTTP 429' "$work/err" "$work/out"; then
    gave_up="was refused for the API rate limit"
    [ "$try" -lt "$attempts" ] || { gave_up="$gave_up on all $attempts tries"; break; }
    log_refusal "$@"
    read -r want kind <<<"$(seconds_to_reset "$try")"
    remaining=$((max_total - $(waited_so_far)))
    # A budget that resets later than this job may still wait gains nothing from a partial
    # wait: fail now, naming the reset, instead of sleeping into the same refusal.
    if [ "$kind" = reset ] && [ "$want" -gt "$remaining" ]; then
      gave_up="$gave_up; the budget resets in ${want}s, past this job's ${remaining}s left to wait (GH_BUDGET_WAIT_MAX_SECONDS=$max_total)"
      break
    fi
    wait_for_budget "$want" "gh ${1:-} ${2:-} $gave_up (try $try of $attempts)" ||
      { gave_up="$gave_up; this job's ${max_total}s of waiting is spent"; break; }
  elif grep -qE 'HTTP 5[0-9][0-9]|(502 Bad Gateway|503 Service Unavailable|504 Gateway Time-?out)' "$work/err"; then
    # GitHub's own 5xx (2026-11-20: `gh workflow run` answered "HTTP 500: Failed to run workflow
    # dispatch"): back off 10, 20, 40 s, at most GH_BUDGET_WAIT_5XX_ATTEMPTS tries in all.
    gave_up="got a GitHub server error"
    server_tries=$((server_tries + 1))
    [ "$server_tries" -lt "$server_attempts" ] || { gave_up="$gave_up on all $server_attempts tries"; break; }
    wait_for_budget $((10 << (server_tries - 1))) "gh ${1:-} ${2:-} $gave_up (try $server_tries of $server_attempts)" ||
      { gave_up="$gave_up; this job's ${max_total}s of waiting is spent"; break; }
  else
    gave_up=""
    break
  fi
  try=$((try + 1))
done
cat "$work/out"
cat "$work/err" >&2
# A limit or server error that outlasted every retry fails loud, once per call.
[ -z "$gave_up" ] || log_error "gh ${1:-} ${2:-} $gave_up; failing"
exit "$rc"
