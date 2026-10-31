#!/usr/bin/env bash
# The action exports for base autofix (the Mac action-exports job of cmux-next-base-autofix.yml),
# made at the newest BRANCH tip: plans/cmux-next/action-surfaces.json, actions.md and links.json.
#
# The Mac job waits for a runner for up to half an hour and the actions area moves every few minutes,
# so this starts on the newest tip when the area moved while the job queued. It regenerates once and
# prints "made at: SHA". When the tip moves the area again during the regeneration, the exports still
# go out as made there: base-autofix-push.sh lands them on the newest tip as progress, and the next
# push run makes them on the newer tip. A regeneration is never retried: three in a row raced the
# merges (one every three minutes or so, against about three and a half per regeneration) and none
# landed (run 39633520123, 2026-10-21).
#
# OUT gets every export file that differs from the run's own commit (HEAD at the start), at its
# repository path: the repair is made on that commit, so it then holds the whole export made at the
# tip. "regenerated: PATH" is printed for each. The checkout ends back at the run's commit (prepared
# again when it moved), as the steps after it expect.
#
# Usage: scripts/cmux-next/base-autofix-action-exports.sh OUT REMOTE BRANCH
# CMUX_ACTIONS_REGENERATE: the regeneration, run as `REGENERATE DIR` (default: the checkout's
#   regenerate-action-exports.sh); it writes the exports into the checkout.
# CMUX_BASE_AUTOFIX_ACTIONS_PREPARE: a command run after each checkout of another commit (the
#   workflow rebuilds the web bundles the package's resources include).
set -euo pipefail

# The whole body is read before it runs: a checkout of a newer tip rewrites this file.
main() {
  local out remote branch here root at tip file regenerate
  local exports=(plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md plans/cmux-next/links.json)
  out="$(mkdir -p "${1:?usage: $0 OUT REMOTE BRANCH}" && cd "$1" && pwd)"
  remote="${2:?usage: $0 OUT REMOTE BRANCH}"
  branch="${3:?usage: $0 OUT REMOTE BRANCH}"
  # Global, like start: the EXIT trap prepares the run's commit again after main has returned.
  prepare="${CMUX_BASE_AUTOFIX_ACTIONS_PREPARE:-}"
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Global, and cleaned up on EXIT, not RETURN: set -e ends the script without returning from main.
  work="$(mktemp -d)"
  root="$(git rev-parse --show-toplevel)"
  cd "$root"
  start="$(git rev-parse HEAD)"
  trap 'back_to_start; rm -rf "${work:-}"' EXIT
  # The run's own area rules, copied before a checkout can change them.
  cp "$here/autofix-areas.sh" "$work/areas.sh"
  # --depth only where the checkout is already shallow (the CI checkout): in a full clone it would make every
  # worktree sharing it shallow (tests/test_ci_no_shallow_dev_fetch.py).
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)

  at="$start"
  # The area most likely moved while the job queued: start on the newest tip, not a regeneration later.
  if tip="$(read_tip)" && moved "$at" "$tip"; then
    echo "$branch moved the action exports' inputs to ${tip:0:12} after ${at:0:12} while this job queued; regenerating there." >&2
    check_out "$tip" || return 1
    at="$tip"
  fi
  regenerate="${CMUX_ACTIONS_REGENERATE:-$root/scripts/cmux-next/regenerate-action-exports.sh}"
  "$regenerate" "$work/regenerated" >&2 || {
    echo "::error::regenerating the action exports on ${at:0:12} failed" >&2
    return 1
  }
  if tip="$(read_tip)" && moved "$at" "$tip"; then
    echo "::notice::$branch moved the action exports' inputs to ${tip:0:12} during the regeneration on ${at:0:12}; they land as progress and the next run makes them there." >&2
  fi
  for file in "${exports[@]}"; do
    [[ -f "$file" ]] || continue
    if git cat-file -e "$start:$file" 2>/dev/null && cmp -s <(git cat-file blob "$start:$file") "$file"; then
      continue
    fi
    mkdir -p "$out/$(dirname "$file")"
    cp "$file" "$out/$file"
    echo "regenerated: $file"
  done
  echo "made at: $at"
}

read_tip() {
  git fetch --quiet --no-tags ${depth[@]+"${depth[@]}"} "$remote" "refs/heads/$branch" >&2 || return 1
  git rev-parse FETCH_HEAD
}

# Whether FROM..TO moved the actions area. A diff or area read that fails counts as moved: it never
# proves the exports current.
moved() { # <from> <to>
  local changed areas
  [[ "$1" != "$2" ]] || return 1
  if changed="$(git diff --name-only --no-renames "$1" "$2")" && areas="$("$work/areas.sh" <<<"$changed")"; then
    grep -qx 'actions=true' <<<"$areas"
  else
    echo "::warning::cannot read what ${1:0:12}..${2:0:12} changed; counting the action exports' inputs as moved" >&2
    return 0
  fi
}

# Called under `||`, where set -e is off: every failure returns on its own, or the exports made at the
# old commit would be named as made at this one.
check_out() { # <commit>
  git checkout --quiet --force --detach "$1" || { echo "::error::cannot check out ${1:0:12}" >&2; return 1; }
  if [[ -n "$prepare" ]]; then
    "$prepare" >&2 || { echo "::error::preparing the checkout of ${1:0:12} failed ($prepare)" >&2; return 1; }
  fi
}

back_to_start() {
  [[ -n "${start:-}" ]] || return 0
  if [[ "$(git rev-parse HEAD 2>/dev/null)" != "$start" ]]; then
    check_out "$start" || true
  else
    # The regeneration writes the exports into the checkout; the steps after it read the run's own.
    git checkout --quiet --force -- . 2>/dev/null || true
  fi
}

main "$@"; exit $?
