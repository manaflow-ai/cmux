#!/usr/bin/env bash
# Deepen a shallow CI checkout just far enough for generate-testflight-notes.sh
# to walk <base>..HEAD, where <base> is the previous beta's commit.
#
# Usage: fetch-testflight-notes-history.sh <base-sha>
#
# The upload workflows check out with fetch-depth 1: a full clone of this repo
# cost ~12 min per run on the macOS pool, and the notes range is the only thing
# in the upload path that reads history. This script:
#   1. fetches the base commit alone (depth 1) to learn its committer date,
#   2. fetches HEAD's history back to one day before that date
#      (--shallow-since), which normally makes the base an ancestor in one round
#      trip,
#   3. if it still is not, deepens in steps for histories whose committer dates
#      are not monotonic, and
#   4. once the base is an ancestor, keeps deepening while <base>..HEAD may
#      still be wrong (see range_incomplete). main has merge commits, and a
#      merged side branch can hold commits older than the --shallow-since
#      cutoff that are not ancestors of the base; stopping at the ancestor
#      check alone silently drops them from the notes.
#
# All fetches use --filter=blob:none. Steps 3 and 4 share one bound: at most
# CMUX_NOTES_HISTORY_MAX_COMMITS (default 20000; blobless commits are cheap)
# commits beyond the --shallow-since fetch. Deepening also stops early when a
# fetch brings in no new commits, or, while the base is not yet an ancestor,
# once <base>..HEAD has no shallow boundary left or every boundary in it is more
# than CMUX_NOTES_HISTORY_DATE_SLACK_DAYS (default 7) days older than the
# cutoff: the base is then not in HEAD's history (e.g. it was force-pushed
# away).
#
# It never fails the upload: every path exits 0. An empty, unknown, or
# unreachable base leaves the checkout as is, and the generator emits its
# generic fallback line, which is what it already did for those cases in a full
# clone.
set -uo pipefail

BASE="${1:-}"
REMOTE="${CMUX_NOTES_HISTORY_REMOTE:-origin}"
MAX_COMMITS="${CMUX_NOTES_HISTORY_MAX_COMMITS:-20000}"
DEEPEN_STEP="${CMUX_NOTES_HISTORY_DEEPEN_STEP:-250}"
SLACK_DAYS="${CMUX_NOTES_HISTORY_DATE_SLACK_DAYS:-7}"
MARGIN_SECONDS=86400

# The history fetches are blobless (commits and trees only: ~10x faster here,
# and the notes generator's path-limited log needs no blobs), which makes the
# checkout a partial clone. Keep git from lazily fetching missing objects one
# at a time while this script walks history.
export GIT_NO_LAZY_FETCH=1

log() { echo "fetch-testflight-notes-history: $*" >&2; }

if [[ -z "$BASE" ]]; then
  log "no previous beta SHA; nothing to fetch"
  exit 0
fi
if ! [[ "$BASE" =~ ^[0-9a-f]{40}$ ]]; then
  log "ignoring base '$BASE': not a full commit SHA"
  exit 0
fi
case "$MAX_COMMITS$DEEPEN_STEP$SLACK_DAYS" in
  *[!0-9]*) log "invalid deepen bounds"; exit 0 ;;
esac

base_is_ancestor() {
  git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null &&
    git merge-base --is-ancestor "$BASE" HEAD 2>/dev/null
}

commit_count() { git rev-list --count HEAD 2>/dev/null || echo 0; }

# Shallow boundary commits (parents not fetched) inside BASE..HEAD, one per line.
range_boundaries() {
  local shallow
  shallow="$(git rev-parse --git-path shallow)"
  [[ -s "$shallow" ]] || return 0
  git rev-list "${BASE}..HEAD" 2>/dev/null | grep -Ff "$shallow"
}

# True while <base>..HEAD may still be wrong in this shallow checkout, which
# happens two ways once the base is an ancestor:
#   - a shallow boundary is inside the range: a merged side branch continues
#     past it, so range commits are missing;
#   - a range commit is no newer than a shallow boundary in the base's own
#     history: it may be an ancestor of the base through history not fetched
#     yet (e.g. main merged into that side branch), so it is counted wrongly.
range_incomplete() {
  local shallow oldest_in_range newest_base_boundary
  shallow="$(git rev-parse --git-path shallow)"
  [[ -s "$shallow" ]] || return 1
  [[ -z "$(range_boundaries)" ]] || return 0
  oldest_in_range="$(git log --format=%ct "${BASE}..HEAD" 2>/dev/null | sort -n | head -n 1)"
  [[ -n "$oldest_in_range" ]] || return 1
  newest_base_boundary="$(
    git rev-list "$BASE" 2>/dev/null | grep -Ff "$shallow" |
      while IFS= read -r sha; do git show -s --format=%ct "$sha"; done | sort -n | tail -n 1
  )"
  [[ -n "$newest_base_boundary" ]] || return 1
  (( oldest_in_range <= newest_base_boundary ))
}

# Keep .git/shallow consistent with the object store after each fetch. Two
# server behaviors break it: a --shallow-since fetch can record a boundary
# commit it never sent (seen against github.com with git 2.54; every later
# fetch then dies with "error in object: unshallow <sha>"), and a commit
# fetched shallow on its own (the base) can stay marked shallow after a later
# fetch brings in its parents, which makes its ancestors look like part of
# <base>..HEAD. Drop entries whose commit is missing, and entries whose parents
# are all present (each fetched parent is itself either complete or listed).
repair_shallow() {
  local shallow sha parent keep
  shallow="$(git rev-parse --git-path shallow)"
  [[ -s "$shallow" ]] || return 0
  while IFS= read -r sha; do
    git cat-file -e "${sha}^{commit}" 2>/dev/null || continue
    keep=0
    for parent in $(git cat-file commit "$sha" | sed -n '/^$/q; s/^parent //p'); do
      git cat-file -e "${parent}^{commit}" 2>/dev/null || { keep=1; break; }
    done
    if (( keep )); then
      echo "$sha"
    fi
  done <"$shallow" >"${shallow}.repair" && mv "${shallow}.repair" "$shallow"
  [[ -s "$shallow" ]] || rm -f "$shallow"
}

# Committer time of the newest shallow boundary inside BASE..HEAD, or empty.
newest_boundary_time() {
  local shas
  shas="$(range_boundaries)"
  [[ -n "$shas" ]] || return 0
  # shellcheck disable=SC2086
  git show -s --format=%ct $shas | sort -n | tail -n 1
}

if [[ "$(git rev-parse --is-shallow-repository)" != "true" ]]; then
  log "checkout already has full history"
  exit 0
fi

HEAD_SHA="$(git rev-parse HEAD)"

if ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null; then
  if ! git fetch --quiet --no-tags --filter=blob:none --depth=1 "$REMOTE" "$BASE"; then
    log "could not fetch ${BASE:0:12}; notes fall back to the generic line"
    exit 0
  fi
fi

if ! base_is_ancestor || range_incomplete; then
  base_time="$(git show -s --format=%ct "$BASE")"
  since=$((base_time - MARGIN_SECONDS))
  if ! git fetch --quiet --no-tags --filter=blob:none --shallow-since="@${since}" "$REMOTE" "$HEAD_SHA"; then
    log "--shallow-since fetch failed; deepening in steps instead"
  fi
  repair_shallow
  give_up_before=$((since - SLACK_DAYS * 86400))

  start_count="$(commit_count)"
  while :; do
    if base_is_ancestor; then
      range_incomplete || break
    else
      newest="$(newest_boundary_time)"
      if [[ -z "$newest" ]]; then
        # BASE..HEAD has no shallow boundary left, so the merge base of the two
        # is fetched and the base is not on HEAD's history (force-push).
        log "${BASE:0:12} is not an ancestor of HEAD; notes fall back to the generic line"
        exit 0
      fi
      if (( newest < give_up_before )); then
        log "every shallow boundary is over ${SLACK_DAYS} days older than ${BASE:0:12}; it is not in HEAD's history, so notes fall back to the generic line"
        exit 0
      fi
    fi
    before_count="$(commit_count)"
    if (( before_count - start_count >= MAX_COMMITS )); then
      if base_is_ancestor; then
        log "warning: range may still be incomplete after ${MAX_COMMITS} extra commits; notes may omit older merged commits"
        break
      fi
      log "${BASE:0:12} not reached within ${MAX_COMMITS} extra commits; notes fall back to the generic line"
      exit 0
    fi
    if ! git fetch --quiet --no-tags --filter=blob:none --deepen="$DEEPEN_STEP" "$REMOTE" "$HEAD_SHA"; then
      if base_is_ancestor; then
        log "warning: deepen fetch failed; notes may omit older merged commits"
        break
      fi
      log "deepen fetch failed; notes fall back to the generic line"
      exit 0
    fi
    repair_shallow
    if (( $(commit_count) == before_count )); then
      if base_is_ancestor; then
        log "warning: deepen fetch brought no new commits; notes may omit older merged commits"
        break
      fi
      log "deepen fetch brought no new commits and ${BASE:0:12} is not an ancestor; notes fall back to the generic line"
      exit 0
    fi
  done
fi

log "history from ${BASE:0:12} to ${HEAD_SHA:0:12} is available ($(git rev-list --count "${BASE}..HEAD") commits)"
exit 0
