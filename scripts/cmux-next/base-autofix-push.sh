#!/usr/bin/env bash
# Pushes base autofix's repair commit (HEAD, one commit on top of BASE_SHA) to
# BRANCH of REMOTE, and lands it on the newest tip. feat-cmux-next takes a push
# every minute or two and the Mac export takes ten or more, so a run usually
# finds the branch moved, often in the repair's own inputs (CmuxNextSettings
# moves with nearly every merge). Leaving such a repair to "the next run" meant
# no settings export landed while merges kept coming (run 39553409406), so a
# moved input never holds a repair back: the regenerated files land, and each
# export carries its own freshness record (the settings stamp names the
# sources it was made from), so whatever changed since is flagged and the
# newer run, which diffs from this one, regenerates it.
#
# What does hold a file back is a newer write of that file itself: a commit
# since BASE_SHA that wrote it (a pull request's own regeneration, or a base
# autofix repair made from a newer tree), or that removed the directory of a
# file the repair adds. An earlier base autofix repair made from an older tree
# is replaced. The exports land as a whole or not at all (the settings schema,
# docs/mdm and their stamp; the three action exports), and files built from an
# export that waits wait with it. The defaults snapshot reads flags anywhere in
# the app's sources, so on a moved tip it is derived again there
# (scripts/ci/defaults_guard.py snapshot), never copied.
#
# The rest lands; when anything waited the run still fails, so the next run
# diffs from an older successful one and repairs it. Nothing already on the tip
# is pushed again (no empty commit). Each push is a plain push, retried on a
# moved tip up to CMUX_BASE_AUTOFIX_PUSH_ATTEMPTS times (5).
#
# Usage: scripts/cmux-next/base-autofix-push.sh REMOTE BRANCH BASE_SHA
# Credentials come from the caller's environment (GIT_CONFIG_* extraheader).
set -euo pipefail
remote="${1:?usage: $0 REMOTE BRANCH BASE_SHA}"
branch="${2:?usage: $0 REMOTE BRANCH BASE_SHA}"
base="${3:?usage: $0 REMOTE BRANCH BASE_SHA}"
attempts="${CMUX_BASE_AUTOFIX_PUSH_ATTEMPTS:-5}"
# The subject of base autofix's own commits (cmux-next-base-autofix.yml); the
# SHA after "at" is the tree the repair was made from.
autofix_subject='^chore(next): base autofix at '
snapshot=schemas/defaults/cmux-next.json

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
newer_writes() { # <tip>
  local tip="$1" commit subject at made
  git log --first-parent --diff-merges=first-parent --format= --name-only --no-renames \
    --invert-grep --grep="$autofix_subject" "$base..$tip"
  while read -r commit subject; do
    at="$(sed -n 's/^chore(next): base autofix at \([0-9a-f]\{7,40\}\).*/\1/p' <<<"$subject")"
    [[ -n "$at" ]] || continue
    made="$(git rev-parse -q --verify "$at^{commit}" 2>/dev/null || true)"
    if [[ -n "$made" && "$made" != "$base" ]] && git merge-base --is-ancestor "$base" "$made" 2>/dev/null; then
      git show --format= --name-only --no-renames "$commit"
    fi
  done < <(git log --first-parent --format='%H %s' --grep="$autofix_subject" "$base..$tip")
}

held=""
for ((attempt = 1; attempt <= attempts; attempt++)); do
  git fetch --quiet --no-tags "$remote" "refs/heads/$branch" || {
    echo "::error::cannot read $branch from the remote" >&2
    exit 1
  }
  tip="$(git rev-parse FETCH_HEAD)"
  held=""
  if [[ "$tip" == "$base" ]]; then
    git checkout --quiet --detach "$repair"
  else
    newer="$(newer_writes "$tip" | grep . | sort -u || true)"
    held_set=""
    while IFS= read -r path; do
      [[ -n "$path" && "$path" != "$snapshot" ]] || continue
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
    if ((${#kept[@]} == 0)); then
      echo "::error::$branch moved to ${tip:0:12} after ${base:0:12}, and newer commits wrote every file this repair writes; the next run repairs them:" >&2
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
    if grep -qxF -- "$snapshot" <<<"$repaired"; then
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
    [[ -z "$held" ]] || message+=$'\n'"Left to the next run (newer commits wrote them): $(printf '%s' "$held" | tr '\n' ' ')"
    git commit --quiet -m "$message"
  fi
  # A plain push: it fails rather than overwrite a commit pushed meanwhile.
  if git push --quiet "$remote" "HEAD:refs/heads/$branch"; then
    echo "Pushed $(git rev-parse --short HEAD) to $branch."
    if [[ -n "$held" ]]; then
      echo "::error::pushed part of the repair; newer commits wrote these, so the next run repairs them:" >&2
      printf '%s' "$held" | sed 's/^/  /' >&2
      exit 1
    fi
    exit 0
  fi
  echo "$branch moved during the push (attempt $attempt of $attempts); trying again."
done
echo "::error::$branch kept moving; the next run repairs it." >&2
exit 1
