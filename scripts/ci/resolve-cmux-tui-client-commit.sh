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
# Usage: scripts/ci/resolve-cmux-tui-client-commit.sh [--max-fallback <n>] [--head <rev>]
#   --max-fallback <n>  older published commits that may stand in when newer candidates
#                       have no manifest yet (artifacts run failed or still running).
#                       Default 0: the newest candidate must be published, or this fails.
#   --head <rev>        history to search (default HEAD).
# Env: CMUX_TUI_CLIENT_MANIFEST_BASE (default https://files.cmux.com/cmux-tui),
#      CMUX_TUI_CLIENT_REMOTE (default origin; where a shallow clone deepens from).
# The chosen 40-hex commit is the only stdout line; diagnostics go to stderr.
set -euo pipefail

PATHS=(cmux-tui ghostty .github/workflows/cmux-tui-artifacts.yml .github/workflows/cmux-tui-build-package.yml)
BASE="${CMUX_TUI_CLIENT_MANIFEST_BASE:-https://files.cmux.com/cmux-tui}"
REMOTE="${CMUX_TUI_CLIENT_REMOTE:-origin}"
MAX_FALLBACK=0
HEAD_REV=HEAD

log() { echo "resolve-cmux-tui-client-commit: $*" >&2; }
usage() { sed -n '2,24p' "$0"; }

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
  done < <(git log -n $((want + 8)) --format=%H "$head_sha" -- "${PATHS[@]}")
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
  if ! git fetch --quiet --deepen="$deepen" "$REMOTE" "$head_sha" 2>/dev/null \
     && ! git fetch --quiet --deepen="$deepen" "$REMOTE"; then
    log "could not deepen the clone from $REMOTE"
    break
  fi
  rounds=$((rounds + 1))
  deepen=$((deepen * 2))
done

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "error: no commit touching ${PATHS[*]} is visible from $head_sha" >&2
  exit 1
fi

chosen=""
skipped=0
for ((i = 0; i < ${#CANDIDATES[@]}; i++)); do
  sha="${CANDIDATES[$i]}"
  url="$BASE/$sha/manifest.json"
  # One probe per candidate, no retry loop: a transient failure just moves on to the
  # next candidate (or fails exact mode, which a re-run covers) instead of waiting.
  if curl --proto '=https,file' --tlsv1.2 -fsS -o /dev/null "$url" 2>/dev/null; then
    chosen="$sha"
    break
  fi
  log "no published cmux-tui client for $sha ($url)"
  skipped=$((skipped + 1))
  if [[ $skipped -gt $MAX_FALLBACK ]]; then break; fi
done

if [[ -z "$chosen" ]]; then
  echo "error: the newest cmux-tui commit ${CANDIDATES[0]} has no published client at $BASE/${CANDIDATES[0]}/manifest.json" >&2
  echo "       check the 'cmux-tui artifacts' run for that commit (--max-fallback $MAX_FALLBACK)" >&2
  exit 1
fi
if [[ $skipped -gt 0 ]]; then
  echo "::warning title=cmux-tui client fallback::bundling the client of $chosen; $skipped newer cmux-tui commit(s) have no published artifacts (newest: ${CANDIDATES[0]})" >&2
fi
log "using cmux-tui commit $chosen"
printf '%s\n' "$chosen"
