#!/usr/bin/env bash
# Pushes base autofix's repair commit (HEAD, one commit on top of BASE_SHA) to
# BRANCH of REMOTE, and lands what is still right on the newest tip.
# feat-cmux-next takes a push every minute or two and the Mac export takes ten
# or more, so a run usually finds the branch moved.
#
# A file never lands as it was made at BASE_SHA when the tip moved its inputs:
# the areas of the paths changed in BASE_SHA..tip (autofix-areas.sh, the same
# input paths that decide the repairs) hold every output those areas build,
# so a revert in between can't land a wrong export. A file is also held when a
# commit since BASE_SHA wrote it itself (a pull request's own regeneration, or
# a base autofix repair made from a newer tree), when it adds into a directory
# a newer commit removed, and when no area is known to build it. An earlier
# base autofix repair made from an older tree is replaced. The exports land as
# a whole or not at all (the settings schema, docs/mdm and their stamp; the
# three action exports), and files built from an export that waits wait with
# it. The defaults snapshot reads flags anywhere in the app's sources, so it is
# never copied: on a moved tip it is derived again there
# (scripts/ci/defaults_guard.py snapshot), and only when nothing else waits.
#
# The rest lands; when anything waited the run still fails, so the next run
# diffs from an older successful one and repairs it. Nothing already on the tip
# is pushed again (no empty commit). Each push is a plain push, retried on a
# moved tip up to CMUX_BASE_AUTOFIX_PUSH_ATTEMPTS times (5).
#
# Usage: scripts/cmux-next/base-autofix-push.sh REMOTE BRANCH BASE_SHA
# Credentials come from the caller's environment (GIT_CONFIG_* extraheader).
# CMUX_BASE_AUTOFIX_AREAS names the area script (default: autofix-areas.sh beside this one).
set -euo pipefail
remote="${1:?usage: $0 REMOTE BRANCH BASE_SHA}"
branch="${2:?usage: $0 REMOTE BRANCH BASE_SHA}"
base="${3:?usage: $0 REMOTE BRANCH BASE_SHA}"
attempts="${CMUX_BASE_AUTOFIX_PUSH_ATTEMPTS:-5}"
# The subject of base autofix's own commits (cmux-next-base-autofix.yml); the
# SHA after "at" is the tree the repair was made from.
autofix_subject='^chore(next): base autofix at '
snapshot=schemas/defaults/cmux-next.json
areas_script="${CMUX_BASE_AUTOFIX_AREAS:-$(dirname "${BASH_SOURCE[0]}")/autofix-areas.sh}"

# The areas whose inputs a list of changed paths (stdin) touches.
input_areas() { "$areas_script" | sed -n 's/=true$//p' | sort -u; }
# The areas that build each output (stdin; base-autofix.sh's outputs). A file built from several
# areas names them all; one this list doesn't know is "unknown", which never lands on a moved tip.
output_areas() {
  local path
  while IFS= read -r path; do
    case "$path" in
      Packages/macOS/CmuxNext/ci-target-graph.json) echo graph ;;
      */generated/strings.json) echo strings; echo webviews ;;
      cmux-tui/bindings/*) echo sdk ;;
      plans/cmux-next/action-surfaces.json | plans/cmux-next/actions.md | plans/cmux-next/links.json)
        echo actions; echo shortcuts; echo apphost ;;
      schemas/settings/settings-schema.json | schemas/settings-export/* | docs/mdm/*) echo settings ;;
      "$snapshot") echo settings; echo actions ;;
      web/data/cmux-shortcuts.generated.json) echo shortcuts; echo actions ;;
      cmux-tui/crates/cmux-app-host/generated/*) echo apphost; echo actions ;;
      scripts/lint-namespace-types-ratchet.txt) echo ratchets ;;
      clients/ts/cloud/* | cmux-tui/crates/cmux-cloud-wire/src/generated/*) echo cloud ;;
      webviews/*) echo webviews ;;
      cmux-tui/* | Native/OptChat/*) echo fmt ;;
      *) echo unknown ;;
    esac
  done | sort -u
}

# The export a file is part of; an export lands whole (regenerate-*-exports.sh list them).
export_of() {
  case "$1" in
    plans/cmux-next/action-surfaces.json | plans/cmux-next/actions.md | plans/cmux-next/links.json) echo actions ;;
    schemas/settings/settings-schema.json | schemas/settings-export/* | docs/mdm/*) echo settings ;;
  esac
}
# The exports a file is generated from (base-autofix.sh). The snapshot is derived again instead.
built_from() {
  case "$1" in
    web/data/cmux-shortcuts.generated.json | cmux-tui/crates/cmux-app-host/generated/*) echo actions ;;
    */generated/strings.json) echo settings ;;
  esac
}

repair="$(git rev-parse HEAD)"
base="$(git rev-parse "$base^{commit}")"
[[ "$(git rev-parse HEAD^)" == "$base" ]] || {
  echo "::error::the repair commit is not one commit on top of ${base:0:12}" >&2
  exit 1
}
repaired="$(git diff --name-only --no-renames "$base" "$repair" | sort -u)"

# The files commits in BASE..TIP wrote that this repair must not overwrite: every commit but
# a base autofix repair, and a base autofix repair made from a tree after BASE.
# Fails when history can't be read, so an unreadable range never reads as "nothing newer".
newer_writes() { # <tip>
  local tip="$1" commit subject at made repairs
  git log --first-parent --diff-merges=first-parent --format= --name-only --no-renames \
    --invert-grep --grep="$autofix_subject" "$base..$tip" || return 1
  repairs="$(git log --first-parent --format='%H %s' --grep="$autofix_subject" "$base..$tip")" || return 1
  while read -r commit subject; do
    at="$(sed -n 's/^chore(next): base autofix at \([0-9a-f]\{7,40\}\).*/\1/p' <<<"$subject")"
    [[ -n "$at" ]] || continue
    made="$(git rev-parse -q --verify "$at^{commit}" 2>/dev/null || true)"
    if [[ -n "$made" && "$made" != "$base" ]] && git merge-base --is-ancestor "$base" "$made" 2>/dev/null; then
      git show --format= --name-only --no-renames "$commit" || return 1
    fi
  done <<<"$repairs"
}

held=""
# The tip the last rejected push went onto; a rejection that did not move the branch is no race.
rejected_on=""
for ((attempt = 1; attempt <= attempts; attempt++)); do
  git fetch --quiet --no-tags "$remote" "refs/heads/$branch" || {
    echo "::error::cannot read $branch from the remote" >&2
    exit 1
  }
  tip="$(git rev-parse FETCH_HEAD)"
  if [[ "$tip" == "$rejected_on" ]]; then
    echo "::error::the push was rejected but $branch did not move from ${tip:0:12}; see the push output above." >&2
    exit 1
  fi
  held=""
  if [[ "$tip" == "$base" ]]; then
    git checkout --quiet --detach "$repair"
  else
    newer="$(newer_writes "$tip")" || {
      echo "::error::cannot read the commits ${base:0:12}..${tip:0:12} wrote, so nothing lands over them" >&2
      exit 1
    }
    newer="$(grep . <<<"$newer" | sort -u || true)"
    moved_areas="$(git diff --name-only --no-renames "$base" "$tip" | input_areas)" || {
      echo "::error::cannot read what ${base:0:12}..${tip:0:12} changed, so nothing lands over it" >&2
      exit 1
    }
    held_set=""
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      # The snapshot is derived again on the tip (below); only moved inputs and other waits hold it.
      if grep -qxF unknown <<<"$(output_areas <<<"$path")" \
        || [[ -n "$(comm -12 <(output_areas <<<"$path") <(printf '%s\n' "$moved_areas"))" ]]; then
        held_set+="$path"$'\n'
        continue
      fi
      [[ "$path" != "$snapshot" ]] || continue
      if grep -qxF -- "$path" <<<"$newer"; then
        held_set+="$path"$'\n'
        continue
      fi
      # A file the repair adds into a directory a newer commit removed.
      git cat-file -e "$base:$path" 2>/dev/null && continue
      dir="$(dirname "$path")"
      [[ "$dir" == . ]] && continue
      if git cat-file -e "$base:$dir" 2>/dev/null && ! git cat-file -e "$tip:$dir" 2>/dev/null; then
        held_set+="$path"$'\n'
      fi
    done <<<"$repaired"
    # An export lands whole, and what is built from a held export waits with it.
    waiting="$(while IFS= read -r path; do
      if [[ -n "$path" ]]; then export_of "$path"; fi
    done <<<"$held_set" | sort -u)"
    kept=()
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      group="$(export_of "$path")"
      if grep -qxF -- "$path" <<<"$held_set" \
        || { [[ -n "$group" ]] && grep -qxF -- "$group" <<<"$waiting"; } \
        || [[ -n "$(comm -12 <(built_from "$path" | sort -u) <(printf '%s\n' "$waiting"))" ]]; then
        held+="$path"$'\n'
      else
        kept+=("$path")
      fi
    done <<<"$repaired"
    # The snapshot never lands beside a file that waits: it reads them all.
    if [[ -n "$held" ]] && grep -qxF -- "$snapshot" <<<"$repaired" && ! grep -qxF -- "$snapshot" <<<"$held"; then
      held+="$snapshot"$'\n'
      still=()
      for path in "${kept[@]}"; do
        [[ "$path" == "$snapshot" ]] || still+=("$path")
      done
      kept=(${still[@]+"${still[@]}"})
    fi
    if ((${#kept[@]} == 0)); then
      echo "::error::$branch moved to ${tip:0:12} after ${base:0:12} and changed the inputs or the files of everything this repair writes; the newer run repairs them:" >&2
      printf '%s' "$held" | sed 's/^/  /' >&2
      exit 1
    fi
    echo "$branch moved to ${tip:0:12} after ${base:0:12} (attempt $attempt of $attempts); writing ${#kept[@]} repaired file(s) onto it."
    git checkout --quiet --detach "$tip"
    for path in "${kept[@]}"; do
      if [[ "$path" == "$snapshot" ]]; then
        continue
      elif git cat-file -e "$repair:$path" 2>/dev/null; then
        git checkout --quiet "$repair" -- "$path"
      else
        git rm --quiet --cached --ignore-unmatch -- "$path"
        rm -f -- "$path"
      fi
    done
    if printf '%s\n' "${kept[@]}" | grep -qxF -- "$snapshot"; then
      if [[ -f scripts/ci/defaults_guard.py ]] && python3 scripts/ci/defaults_guard.py snapshot >/dev/null; then
        git add -- "$snapshot"
      else
        echo "::warning::could not derive $snapshot on ${tip:0:12}; it waits for the next run" >&2
        git checkout --quiet "$tip" -- "$snapshot" 2>/dev/null || true
        held+="$snapshot"$'\n'
      fi
    fi
    if git diff --cached --quiet; then
      if [[ -n "$held" ]]; then
        echo "::error::$branch ${tip:0:12} already holds the repairs that could land; left to the next run:" >&2
        printf '%s' "$held" | sed 's/^/  /' >&2
        exit 1
      fi
      echo "$branch at ${tip:0:12} already holds this repair; nothing to push."
      exit 0
    fi
    message="$(git log -1 --format=%B "$repair")"
    message+=$'\n\n'"Re-applied on ${tip:0:12}, which $branch moved to after ${base:0:12}."
    [[ -z "$held" ]] || message+=$'\n'"Left to the next run (newer commits changed them or their inputs): $(printf '%s' "$held" | tr '\n' ' ')"
    git commit --quiet -m "$message"
  fi
  # A plain push: it fails rather than overwrite a commit pushed meanwhile.
  if git push --quiet "$remote" "HEAD:refs/heads/$branch"; then
    echo "Pushed $(git rev-parse --short HEAD) to $branch."
    if [[ -n "$held" ]]; then
      echo "::error::pushed part of the repair; newer commits changed these or their inputs, so the next run repairs them:" >&2
      printf '%s' "$held" | sed 's/^/  /' >&2
      exit 1
    fi
    exit 0
  fi
  rejected_on="$tip"
  echo "The push to $branch was refused (attempt $attempt of $attempts); reading the tip again."
done
echo "::error::$branch kept moving; the next run repairs it." >&2
exit 1
