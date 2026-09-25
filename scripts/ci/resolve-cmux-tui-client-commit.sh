#!/usr/bin/env bash
# resolve-cmux-tui-client-commit.sh — print the cmux-tui commit whose published client
# an app bundle should carry.
#
# The `cmux-tui artifacts` workflow publishes one client build per main commit that
# touches cmux-tui or its build inputs, at
# https://files.cmux.com/cmux-tui/<commit>/manifest.json. The app workflows bundle the
# client of the newest such commit in the checked-out history.
#
# A bare `git log -1 -- <paths>` is wrong on CI: actions/checkout clones with depth 1,
# and in a one-commit history the grafted root shows every file as added, so the answer
# is always HEAD. HEAD has a published client only when it touched cmux-tui itself, so
# the download 404s on almost every push. This deepens a shallow clone until real
# cmux-tui history is visible, ignores shallow boundary commits, and walks candidates
# newest first until one has a published manifest.
#
# Candidates come from the full history, merge commits included, and are grouped by the
# content of the client inputs. The client depends only on that content, so any
# published commit in a group stands for all of it. Without this, a branch-side merge
# commit that reached main through a merge-commit PR (52020d35 via #14090) was the
# "newest" candidate while only the PR's main-side merge (f4b331d15) was published, and
# every reload build failed in exact mode.
#
# Usage: scripts/ci/resolve-cmux-tui-client-commit.sh [--max-fallback <n>] [--head <rev>]
#   --max-fallback <n>  older input versions (groups of commits with identical client
#                       inputs) that may stand in when no commit with newer inputs has a
#                       manifest yet (artifacts run failed or still running). Default 0: a
#                       commit with HEAD's exact inputs must be published, or this fails.
#   --head <rev>        history to search (default HEAD).
# Env: CMUX_TUI_CLIENT_MANIFEST_BASE (default https://files.cmux.com/cmux-tui),
#      CMUX_TUI_CLIENT_REMOTE (default origin; where a shallow clone deepens from),
#      CMUX_TUI_CLIENT_FETCH_ATTEMPTS (default 5; tries per deepen before giving up),
#      CMUX_TUI_CLIENT_FETCH_RETRY_SECONDS (default 2; first backoff, doubles per try),
#      CMUX_TUI_CLIENT_PROBE_RETRY_SECONDS (default 3; wait between manifest probes after
#      a transient failure; a 404 never waits).
# The chosen 40-hex commit is the only stdout line; diagnostics go to stderr.
set -euo pipefail

PATHS=(cmux-tui ghostty .github/workflows/cmux-tui-artifacts.yml .github/workflows/cmux-tui-build-package.yml)
BASE="${CMUX_TUI_CLIENT_MANIFEST_BASE:-https://files.cmux.com/cmux-tui}"
REMOTE="${CMUX_TUI_CLIENT_REMOTE:-origin}"
MAX_FALLBACK=0
HEAD_REV=HEAD

log() { echo "resolve-cmux-tui-client-commit: $*" >&2; }
usage() { sed -n '2,28p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-fallback) shift; MAX_FALLBACK="${1:?--max-fallback needs a value}" ;;
    --head) shift; HEAD_REV="${1:?--head needs a value}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done
case "$MAX_FALLBACK" in
  ''|*[!0-9]*) echo "error: --max-fallback must be a non-negative integer" >&2; exit 64 ;;
esac
# Decimal, so a value with a leading zero (08) is not read as octal by the arithmetic below.
MAX_FALLBACK=$((10#$MAX_FALLBACK))
FETCH_ATTEMPTS="${CMUX_TUI_CLIENT_FETCH_ATTEMPTS:-5}"
FETCH_RETRY_SECONDS="${CMUX_TUI_CLIENT_FETCH_RETRY_SECONDS:-2}"
PROBE_RETRY_SECONDS="${CMUX_TUI_CLIENT_PROBE_RETRY_SECONDS:-3}"
case "$FETCH_ATTEMPTS" in
  ''|*[!0-9]*) echo "error: CMUX_TUI_CLIENT_FETCH_ATTEMPTS must be a positive integer" >&2; exit 64 ;;
esac
case "$FETCH_RETRY_SECONDS" in
  ''|*[!0-9]*) echo "error: CMUX_TUI_CLIENT_FETCH_RETRY_SECONDS must be a non-negative integer" >&2; exit 64 ;;
esac
case "$PROBE_RETRY_SECONDS" in
  ''|*[!0-9]*) echo "error: CMUX_TUI_CLIENT_PROBE_RETRY_SECONDS must be a non-negative integer" >&2; exit 64 ;;
esac
# Normalize before the positive check so an all-zero spelling (00) is rejected too.
FETCH_ATTEMPTS=$((10#$FETCH_ATTEMPTS))
FETCH_RETRY_SECONDS=$((10#$FETCH_RETRY_SECONDS))
PROBE_RETRY_SECONDS=$((10#$PROBE_RETRY_SECONDS))
if [[ $FETCH_ATTEMPTS -lt 1 ]]; then
  echo "error: CMUX_TUI_CLIENT_FETCH_ATTEMPTS must be a positive integer" >&2
  exit 64
fi

head_sha="$(git rev-parse --verify "${HEAD_REV}^{commit}")"
shallow_file="$(git rev-parse --git-path shallow)"
want=$((MAX_FALLBACK + 1))

is_shallow_boundary() {
  [[ -f "$shallow_file" ]] && grep -qx "$1" "$shallow_file"
}

# Candidates: commits in the history that touch the client inputs, newest first. A
# shallow boundary commit is skipped: with its parents missing, git shows it as adding
# every file, so it would match whether or not it touched cmux-tui.
CANDIDATES=()
collect_candidates() {
  CANDIDATES=()
  local sha
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    if is_shallow_boundary "$sha"; then continue; fi
    CANDIDATES[${#CANDIDATES[@]}]="$sha"
  done < <(git log --full-history -n $((want * 4 + 16)) --format=%H "$head_sha" -- "${PATHS[@]}")
}

# The client inputs' content at a commit: a key equal for every commit a client built
# from one of them is valid for.
inputs_key() {
  git ls-tree "$1" -- "${PATHS[@]}" | git hash-object --stdin
}

# The deepen fetch is the resolver's one network call to GitHub, made after a
# 40-minute build on a release runner. A transient failure there (DNS blip,
# connection reset) must not fail the release, so retry with bounded backoff.
# Release run 34851108495 died on "Could not resolve host: github.com".
fetch_deepen() {
  local attempt=1 delay="$FETCH_RETRY_SECONDS"
  while :; do
    if git fetch --quiet --deepen="$deepen" "$REMOTE" "$head_sha" 2>/dev/null \
       || git fetch --quiet --deepen="$deepen" "$REMOTE"; then
      return 0
    fi
    if [[ $attempt -ge $FETCH_ATTEMPTS ]]; then
      return 1
    fi
    log "deepen attempt $attempt of $FETCH_ATTEMPTS failed; retrying in ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

deepen=200
rounds=0
while :; do
  collect_candidates
  if [[ ${#CANDIDATES[@]} -ge $want ]]; then break; fi
  # No shallow file means the history is complete: what we have is all there is.
  if [[ ! -f "$shallow_file" ]]; then break; fi
  if [[ $rounds -ge 6 ]]; then
    log "gave up deepening after $rounds rounds with ${#CANDIDATES[@]} usable candidate(s)"
    break
  fi
  log "shallow clone shows ${#CANDIDATES[@]} usable cmux-tui commit(s); deepening by $deepen from $REMOTE"
  if ! fetch_deepen; then
    log "could not deepen the clone from $REMOTE after $FETCH_ATTEMPTS attempt(s)"
    break
  fi
  rounds=$((rounds + 1))
  deepen=$((deepen * 2))
done

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "error: no commit touching ${PATHS[*]} is visible from $head_sha" >&2
  exit 1
fi

# Succeeds when the manifest exists. A definitive miss (HTTP 404/410, or a missing
# file:// path, curl exit 37) returns at once. Anything else (DNS, connection reset,
# 5xx, 429) is retried with bounded delay so a network hiccup on the release runner
# does not read as a missing manifest. curl --retry-all-errors cannot tell the two
# apart and slept through five retries on every genuine 404.
PROBE_ATTEMPTS=6
probe_manifest() {
  local url="$1" attempt code rc
  for ((attempt = 1; attempt <= PROBE_ATTEMPTS; attempt++)); do
    rc=0
    code="$(curl --proto '=https,file' --tlsv1.2 -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" || rc=$?
    if [[ $rc -eq 0 ]]; then
      # Like curl -f, anything below 400 is found; file:// reports 000 on success.
      case "$code" in
        404|410) return 1 ;;
        [45]??) ;;
        *) return 0 ;;
      esac
    elif [[ $rc -eq 37 ]]; then
      return 1
    fi
    if [[ $attempt -lt $PROBE_ATTEMPTS ]]; then sleep "$PROBE_RETRY_SECONDS"; fi
  done
  log "manifest probe still failing after $PROBE_ATTEMPTS attempts (curl exit $rc, HTTP $code): $url"
  return 1
}

# Group candidates by input content, keeping newest-first order of each group's first
# member. Fallback counts groups, not commits: an unpublished commit whose content a
# published one shares is not a fallback.
GROUP_KEYS=()
GROUP_MEMBERS=()
for ((i = 0; i < ${#CANDIDATES[@]}; i++)); do
  sha="${CANDIDATES[$i]}"
  key="$(inputs_key "$sha")"
  found=-1
  for ((g = 0; g < ${#GROUP_KEYS[@]}; g++)); do
    if [[ "${GROUP_KEYS[$g]}" == "$key" ]]; then found=$g; break; fi
  done
  if [[ $found -lt 0 ]]; then
    GROUP_KEYS[${#GROUP_KEYS[@]}]="$key"
    GROUP_MEMBERS[${#GROUP_MEMBERS[@]}]="$sha"
  else
    GROUP_MEMBERS[$found]="${GROUP_MEMBERS[$found]} $sha"
  fi
done

# The newest group must carry HEAD's inputs: git hides a commit only when its inputs
# match every parent, so this holds by construction, and exact mode relies on it.
# release.yml and nightly.yml have no content backstop of their own, so enforce it.
if [[ "${GROUP_KEYS[0]}" != "$(inputs_key "$head_sha")" ]]; then
  echo "error: the newest cmux-tui candidate ${CANDIDATES[0]} does not carry HEAD's client inputs" >&2
  exit 1
fi

chosen=""
skipped=0
for ((g = 0; g < ${#GROUP_KEYS[@]}; g++)); do
  # One probe per member: the first published member wins; a group with none moves on
  # to the next group (or fails exact mode).
  for sha in ${GROUP_MEMBERS[$g]}; do
    url="$BASE/$sha/manifest.json"
    if probe_manifest "$url"; then
      chosen="$sha"
      break
    fi
    log "no published cmux-tui client for $sha ($url)"
  done
  if [[ -n "$chosen" ]]; then break; fi
  skipped=$((skipped + 1))
  if [[ $skipped -gt $MAX_FALLBACK ]]; then break; fi
done

if [[ -z "$chosen" ]]; then
  echo "error: no commit with HEAD's cmux-tui client inputs has a published client at $BASE/<commit>/manifest.json" >&2
  echo "       tried: ${GROUP_MEMBERS[0]}" >&2
  echo "       check the 'cmux-tui artifacts' run for those commits (--max-fallback $MAX_FALLBACK)" >&2
  exit 1
fi
if [[ $skipped -gt 0 ]]; then
  echo "::warning title=cmux-tui client fallback::bundling the client of $chosen; $skipped newer cmux-tui input version(s) have no published artifacts (newest: ${CANDIDATES[0]})" >&2
fi
log "using cmux-tui commit $chosen"
printf '%s\n' "$chosen"
