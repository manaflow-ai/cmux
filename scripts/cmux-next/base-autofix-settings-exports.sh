#!/usr/bin/env bash
# The settings exports for base autofix (the Mac action-exports job of
# cmux-next-base-autofix.yml), regenerated on the newest BRANCH tip.
#
# A base autofix run takes about half an hour and feat-cmux-next takes a push
# about once a minute, so some push nearly always moved a settings input
# (autofix-areas.sh's settings area) after the run's commit, and
# base-autofix-push.sh held exports made there on every run: they never landed
# (2026-10-21). So after each regeneration this reads the newest tip, and when
# the tip moved the settings inputs since the commit the exports were made at
# (the settings area, unless the tip's sources give the same source stamp as
# the commit the exports were made at),
# it checks that tip out and regenerates there, at most
# CMUX_BASE_AUTOFIX_SETTINGS_TRIES times (3). It then prints "made at: SHA";
# base-autofix-push.sh lands the exports only where nothing moved their inputs
# after that commit. When the inputs still moved after the last try, it hands
# on no settings export, prints an error and fails, and the exports wait.
#
# OUT gets every export file that differs from the run's own commit (HEAD at
# the start), at its repository path: base autofix's repair is made on that
# commit, so it then holds the whole export made at the tip, not only its diff
# from the tip's committed copy. "regenerated: PATH" is printed for each.
#
# Usage: scripts/cmux-next/base-autofix-settings-exports.sh OUT REMOTE BRANCH
# CMUX_SETTINGS_REGENERATE: the regeneration (default: the checkout's
#   regenerate-settings-exports.sh; it must copy every export with CMUX_SETTINGS_EXPORTS_ALL=1).
# CMUX_BASE_AUTOFIX_SETTINGS_PREPARE: a command run before each regeneration on
#   a moved tip (the workflow rebuilds the web bundles the export tests host).
set -euo pipefail

# The whole body is read before it runs: a checkout of a newer tip rewrites this file.
main() {
  local out remote branch tries here root start at tip try moved changed areas file rel prepare regenerate stamp
  out="$(mkdir -p "${1:?usage: $0 OUT REMOTE BRANCH}" && cd "$1" && pwd)"
  remote="${2:?usage: $0 OUT REMOTE BRANCH}"
  branch="${3:?usage: $0 OUT REMOTE BRANCH}"
  tries="${CMUX_BASE_AUTOFIX_SETTINGS_TRIES:-3}"
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Global, and removed on EXIT, not RETURN: set -e ends the script without returning from main.
  work="$(mktemp -d)"
  trap 'rm -rf "${work:-}"' EXIT
  # The run's own area rules, copied before a checkout can change them.
  cp "$here/autofix-areas.sh" "$work/areas.sh"
  root="$(git rev-parse --show-toplevel)"
  cd "$root"
  start="$(git rev-parse HEAD)"
  # --depth only where the checkout is already shallow (the CI checkout): in a full clone it would make every
  # worktree sharing it shallow (tests/test_ci_no_shallow_dev_fetch.py).
  local depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
  at="$start"
  prepare="${CMUX_BASE_AUTOFIX_SETTINGS_PREPARE:-}"
  for ((try = 1; try <= tries; try++)); do
    rm -rf "$work/out"
    mkdir -p "$work/out"
    if ((try > 1)) && [[ -n "$prepare" ]]; then
      "$prepare" >&2 || { echo "::error::preparing the regeneration on ${at:0:12} failed ($prepare)" >&2; return 1; }
    fi
    regenerate="${CMUX_SETTINGS_REGENERATE:-$root/scripts/cmux-next/regenerate-settings-exports.sh}"
    # Its own "regenerated:" lines name what differs from the commit it ran on; this prints the
    # ones that differ from the run's commit below.
    CMUX_SETTINGS_EXPORTS_ALL=1 "$regenerate" "$work/out" >&2 || {
      echo "::error::regenerating the settings exports on ${at:0:12} failed" >&2
      return 1
    }
    git fetch --quiet --no-tags ${depth[@]+"${depth[@]}"} "$remote" "refs/heads/$branch" || {
      echo "::error::cannot read $branch, so the settings exports made at ${at:0:12} are not known to be current" >&2
      return 1
    }
    tip="$(git rev-parse FETCH_HEAD)"
    # A diff or area read that fails counts as moved: it never proves the exports current.
    moved=1
    if changed="$(git diff --name-only --no-renames "$at" "$tip")" && areas="$("$work/areas.sh" <<<"$changed")"; then
      grep -qx 'settings=true' <<<"$areas" || moved=0
      # A settings-area move whose sources give the same source stamp at the tip as where the exports
      # were made, with the same regeneration, changed none of the exports' inputs (base-autofix-push.sh
      # judges it the same way). The stamp is derived from each tree, never committed. The checkout's
      # own guard reads the trees (it finds the repository from its own path).
      if ((moved)) \
        && stamp="$(python3 "$root/scripts/ci/defaults_guard.py" source-stamp --ref "$at" 2>/dev/null)" \
        && [[ -n "$stamp" && "$stamp" == "$(python3 "$root/scripts/ci/defaults_guard.py" source-stamp --ref "$tip" 2>/dev/null)" ]] \
        && git diff --quiet "$at" "$tip" -- scripts/cmux-next/regenerate-settings-exports.sh 2>/dev/null; then
        moved=0
      fi
    else
      echo "::warning::cannot read what ${at:0:12}..${tip:0:12} changed; counting the settings inputs as moved" >&2
    fi
    if ((moved == 0)); then
      while IFS= read -r -d '' file; do
        rel="${file#"$work/out"/}"
        if git cat-file -e "$start:$rel" 2>/dev/null && cmp -s <(git cat-file blob "$start:$rel") "$file"; then
          continue
        fi
        mkdir -p "$out/$(dirname "$rel")"
        cp "$file" "$out/$rel"
        echo "regenerated: $rel"
      done < <(find "$work/out" -type f -print0 | sort -z)
      echo "made at: $at"
      return 0
    fi
    echo "$branch moved to ${tip:0:12} and changed the settings exports' inputs after ${at:0:12} (try $try of $tries)." >&2
    if ((try < tries)); then
      git checkout --quiet --force --detach "$tip"
      at="$tip"
    fi
  done
  echo "::error::$branch kept changing the settings exports' inputs through $tries regenerations (last made at ${at:0:12}, tip ${tip:0:12}); the exports wait for the next run" >&2
  return 1
}
main "$@"; exit $?
