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
#   gh_budget_wait.sh --backoff TRY [WHAT]
#                                    wait (once, bounded) after try TRY of a call
#                                    made outside gh (an action) failed; never fails
#
# A refused call is tried at most GH_BUDGET_WAIT_ATTEMPTS times (default 6), and
# one job waits at most GH_BUDGET_WAIT_MAX_SECONDS in all (default 3600, the
# longest a reset can be away); each wait is logged. Reading /rate_limit costs
# nothing. A refused request did nothing on GitHub's side, so retrying a write is
# safe. Standard input is replayed only when the call reads it (`--input -`,
# `@-`, `-F -`); otherwise it is left alone for the caller.
# Runs on macOS's bash 3.2.

REAL_GH=gh # --install writes the real gh's path here

set -u

ledger_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gh-budget-wait"
max_total="${GH_BUDGET_WAIT_MAX_SECONDS:-3600}"
attempts="${GH_BUDGET_WAIT_ATTEMPTS:-6}"

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
# then 120, 240 and 300 s per wait. $1 is the try number.
seconds_to_reset() {
  local now reset left try="${1:-1}"
  now="$(date +%s)"
  reset="$("$REAL_GH" api rate_limit --jq \
    '[.resources.core, .resources.graphql, .resources.search] | map(select(.remaining == 0) | .reset) | max // 0' \
    2>/dev/null || echo 0)"
  case "$reset" in '' | *[!0-9]*) reset=0 ;; esac
  if [ "$reset" -gt "$now" ]; then
    left=$((reset - now + 5))
  else
    left=$((60 << (try - 1)))
    [ "$left" -le 300 ] || left=300
  fi
  echo "$left"
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

# --backoff TRY: one wait after try TRY of a call that is not gh (an action such as
# actions/attest-build-provenance) was refused. Until the exhausted budget's reset
# (x-ratelimit-reset, read from /rate_limit) or, with none exhausted, GitHub's
# secondary limit backoff for that try. Within the job total; never fails, so the
# next try decides.
if [ "${1:-}" = "--backoff" ]; then
  try="${2:-1}"
  case "$try" in '' | *[!0-9]* | 0) try=1 ;; esac
  wait_for_budget "$(seconds_to_reset "$try")" "${3:-a GitHub API call} failed (try $try), likely the API rate limit" || true
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
while [ "$try" -le "$attempts" ]; do
  if [ -n "$stdin_file" ]; then
    "$REAL_GH" "$@" <"$stdin_file" >"$work/out" 2>"$work/err"
  else
    "$REAL_GH" "$@" >"$work/out" 2>"$work/err"
  fi
  rc=$?
  if [ "$rc" -eq 0 ] || [ "$try" -eq "$attempts" ] ||
    ! grep -qiE 'rate limit exceeded|secondary rate limit|abuse detection|too many requests|HTTP 429' "$work/err" "$work/out"; then
    break
  fi
  wait_for_budget "$(seconds_to_reset "$try")" "gh ${1:-} ${2:-} was refused for the API rate limit (try $try of $attempts)" || break
  try=$((try + 1))
done
cat "$work/out"
cat "$work/err" >&2
exit "$rc"
