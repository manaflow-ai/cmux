#!/bin/bash
# gh, except that a call made with github.token goes out as the release GitHub App first and
# falls back to github.token when the App token is refused.
#
# Every workflow's github.token is the same actor, so one workflow's burst of POSTs and uploads
# hits a limit that every other workflow's publish then shares. On 2026-10-26 the nightly publish
# (run 40298250989) was refused with HTTP 403 "API rate limit exceeded for installation" from
# 12:04:51Z to 12:14Z while the core budget still had 4899 of 5000 calls left and the 403s
# carried no x-ratelimit-* headers: a secondary, per-actor (or per-repository) limit, not core
# exhaustion. The release App is a separate actor with its own limits.
#
#   gh_app_token.sh --install   GH_APP_TOKEN (the minted App token, may be empty) and
#                               GH_FALLBACK_TOKEN (github.token) in the environment. Puts this
#                               wrapper first on PATH as `gh` (GITHUB_PATH) for the rest of the
#                               job. With no App token (a failed mint) nothing is installed and
#                               gh keeps github.token.
#
# Only a call whose GH_TOKEN (or GITHUB_TOKEN) is github.token is changed; a step that passes
# another token keeps it. The App token is tried first. A refusal of it (401, 403, 429 or a rate
# limit) runs the same call with github.token; a refused request did nothing on GitHub's side,
# so this is safe for writes. A 401 (the App token lasts an hour) stops using it for the job.
# When github.token is refused too for a rate limit or a 403 that is not a permission refusal,
# the call backs off (Retry-After when the output shows one, else 60 s, 120 s, 240 s, ...) and
# tries both again, at most GH_APP_TOKEN_ATTEMPTS times (default 4). Waits count against
# gh_budget_wait.sh's per-job ledger and total (GH_BUDGET_WAIT_MAX_SECONDS, default 3600), so
# the two wrappers together wait at most that long; gh_budget_wait.sh, installed after this,
# wraps this one and still waits for a core reset. Runs on macOS's bash 3.2.

REAL_GH=gh # --install writes the real gh's path here

set -u

dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gh-app-token"
ledger_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gh-budget-wait"
max_total="${GH_BUDGET_WAIT_MAX_SECONDS:-3600}"
attempts="${GH_APP_TOKEN_ATTEMPTS:-4}"
throttled='rate limit exceeded|secondary rate limit|abuse detection|too many requests|HTTP 429'

digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# A notice, kept out of a caller's data when it reads stderr with stdout (as gh_budget_wait.sh does).
note() {
  mkdir -p "$dir"
  echo "$(date -u +%H:%M:%SZ) $1" >>"$dir/log"
  if [ /dev/fd/1 -ef /dev/fd/2 ]; then
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "- GitHub API token: $1" >>"$GITHUB_STEP_SUMMARY"
  else
    echo "::notice title=GitHub API token::$1" >&2
  fi
}

if [ "${1:-}" = "--install" ]; then
  real="$(command -v gh 2>/dev/null || true)"
  if [ -z "${GH_APP_TOKEN:-}" ] || [ -z "${GH_FALLBACK_TOKEN:-}" ]; then
    echo "::warning title=GitHub API token::no release App token (the mint failed or the job has no App credentials); gh calls in this job use github.token"
    exit 0
  fi
  if [ -z "$real" ] || [ -z "${GITHUB_PATH:-}" ]; then
    echo "::warning title=GitHub API token::no gh or GITHUB_PATH; gh calls in this job use github.token"
    exit 0
  fi
  mkdir -p "$dir/bin"
  (umask 077 && printf '%s' "$GH_APP_TOKEN" >"$dir/token")
  printf '%s' "$GH_FALLBACK_TOKEN" | digest >"$dir/fallback.sha256"
  sed "s|^REAL_GH=gh |REAL_GH='$real' |" "$0" >"$dir/bin/gh"
  chmod +x "$dir/bin/gh"
  echo "$dir/bin" >>"$GITHUB_PATH"
  echo "gh calls made with github.token in this job go out as the release App first (real gh: $real)"
  exit 0
fi

caller="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ ! -s "$dir/token" ] || [ -z "$caller" ] ||
  [ "$(printf '%s' "$caller" | digest)" != "$(cat "$dir/fallback.sha256" 2>/dev/null)" ]; then
  exec "$REAL_GH" "$@"
fi

# The call's API area: `gh api repos/O/R/<area>/...` gives <area>, another subcommand its name
# (`gh release ...` gives release). The release App holds Contents and Workflows write and
# Variables read only, so an area it is refused ("Resource not accessible by integration", e.g.
# actions or issues) goes straight to github.token for the rest of the job.
area="${1:-}"
if [ "$area" = api ]; then
  for arg in "${@:2}"; do
    case "$arg" in graphql) area=graphql; break ;; esac
    # /rate_limit reads (gh_budget_wait.sh's) report github.token's budget, the one it waits on.
    case "$arg" in rate_limit | /rate_limit) exec "$REAL_GH" "$@" ;; esac
    case "$arg" in repos/* | /repos/*)
      area="$(printf '%s' "${arg#/}" | sed -n 's#^repos/[^/]*/[^/]*/\([^/?]*\).*#\1#p')"
      break ;;
    esac
  done
fi
if grep -qxF "$area" "$dir/unscoped" 2>/dev/null; then
  exec "$REAL_GH" "$@"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/gh-app-token.XXXXXX")" || exec "$REAL_GH" "$@"
trap 'rm -rf "$work"' EXIT

stdin_file=""
for arg in "$@"; do
  case "$arg" in
    - | *@- | --input=- | --body-file=-) stdin_file="$work/stdin" ;;
  esac
done
[ -z "$stdin_file" ] || cat >"$stdin_file"

refused() { grep -qiE "$1" "$work/err" "$work/out"; }

try=1
while :; do
  if [ -s "$dir/token" ]; then
    if [ -n "$stdin_file" ]; then
      GH_TOKEN="$(cat "$dir/token")" "$REAL_GH" "$@" <"$stdin_file" >"$work/out" 2>"$work/err"
    else
      GH_TOKEN="$(cat "$dir/token")" "$REAL_GH" "$@" >"$work/out" 2>"$work/err"
    fi
    rc=$?
    # GraphQL reports a permission refusal without an HTTP status.
    if [ "$rc" -eq 0 ] || ! refused "$throttled|HTTP 40[13]|bad credentials|resource not accessible"; then
      break
    fi
    if refused 'resource not accessible by integration'; then
      echo "$area" >>"$dir/unscoped"
    fi
    if refused 'HTTP 401|bad credentials'; then
      rm -f "$dir/token"
      note "the release App token was refused as expired or invalid; gh uses github.token for the rest of this job"
    fi
    echo "$(date -u +%H:%M:%SZ) gh ${1:-} ${2:-}: App token refused, retried with github.token" >>"$dir/log"
  fi
  if [ -n "$stdin_file" ]; then
    "$REAL_GH" "$@" <"$stdin_file" >"$work/out" 2>"$work/err"
  else
    "$REAL_GH" "$@" >"$work/out" 2>"$work/err"
  fi
  rc=$?
  if [ "$rc" -eq 0 ] || [ "$try" -ge "$attempts" ] || refused 'resource not accessible' ||
    ! refused "$throttled|HTTP 403"; then
    break
  fi
  # Retry-After when the output carries it (gh api -i), else exponential from 60 s.
  want="$(grep -ihoE '^retry-after: *[0-9]+' "$work/out" "$work/err" | head -1 | tr -dc '0-9')"
  [ -n "$want" ] || want=$((60 * (1 << (try - 1))))
  # The job's ledger, as gh_budget_wait.sh reads it: none yet is nothing waited; one that
  # cannot be read or parsed counts as the whole budget spent (fail closed).
  if [ -e "$ledger_dir/waited" ]; then
    spent="$(cat "$ledger_dir/waited" 2>/dev/null)" || spent="$max_total"
    case "$spent" in '' | *[!0-9]*) spent="$max_total" ;; esac
  else
    spent=0
  fi
  left=$((max_total - spent))
  [ "$left" -gt 0 ] || break
  [ "$want" -le "$left" ] || want="$left"
  # Reserve the wait before sleeping, written whole and renamed into place; a wait that
  # cannot be recorded is not taken (later steps could not see it).
  if ! { mkdir -p "$ledger_dir" 2>/dev/null &&
    echo $((spent + want)) 2>/dev/null >"$ledger_dir/waited.$$" &&
    mv -f "$ledger_dir/waited.$$" "$ledger_dir/waited" 2>/dev/null; }; then
    note "could not record a ${want}s wait in $ledger_dir/waited; not waiting"
    break
  fi
  note "gh ${1:-} ${2:-} was refused with the App token and with github.token (try $try of $attempts); backing off ${want}s (${spent}s waited in this job so far)"
  sleep "$want"
  try=$((try + 1))
done
cat "$work/out"
cat "$work/err" >&2
exit "$rc"
