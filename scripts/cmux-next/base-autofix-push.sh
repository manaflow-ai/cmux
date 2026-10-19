#!/usr/bin/env bash
# Pushes base autofix's repair commit (HEAD, one commit on top of BASE_SHA) to
# BRANCH of REMOTE. feat-cmux-next takes a push every minute or two and the
# Mac export takes ten or more, so a run usually finds the branch moved. When
# it moved, the repaired files are written onto the new tip, unless a commit
# since (other than an earlier base autofix repair, which this newer run
# supersedes) touched one of them, or deleted the directory of a file the
# repair adds. The repair then never overwrites a newer edit, and a repaired
# output whose inputs moved meanwhile is still caught by its own freshness
# check and repaired by the next run (which diffs from this run's commit).
# Otherwise nothing is pushed and the run fails, so the next run repairs it.
#
# Usage: scripts/cmux-next/base-autofix-push.sh REMOTE BRANCH BASE_SHA
# Credentials come from the caller's environment (GIT_CONFIG_* extraheader).
set -euo pipefail
remote="${1:?usage: $0 REMOTE BRANCH BASE_SHA}"
branch="${2:?usage: $0 REMOTE BRANCH BASE_SHA}"
base="${3:?usage: $0 REMOTE BRANCH BASE_SHA}"
attempts="${CMUX_BASE_AUTOFIX_PUSH_ATTEMPTS:-5}"
# The subject of base autofix's own commits (cmux-next-base-autofix.yml).
autofix_subject='^chore(next): base autofix at '

repair="$(git rev-parse HEAD)"
base="$(git rev-parse "$base^{commit}")"
[[ "$(git rev-parse HEAD^)" == "$base" ]] || {
  echo "::error::the repair commit is not one commit on top of ${base:0:12}" >&2
  exit 1
}
repaired="$(git diff --name-only --no-renames "$base" "$repair" | sort -u)"

for (( attempt = 1; attempt <= attempts; attempt++ )); do
  current="$(git ls-remote "$remote" "refs/heads/$branch" | awk '{print $1}')"
  [[ -n "$current" ]] || { echo "::error::$branch is missing on the remote" >&2; exit 1; }
  if [[ "$current" != "$(git rev-parse HEAD^)" ]]; then
    # From a shallow checkout this fetches the commits after BASE_SHA.
    git fetch --quiet --no-tags "$remote" "$current"
    moved="$(git log --first-parent --diff-merges=first-parent --format= --name-only --no-renames \
      --invert-grep --grep="$autofix_subject" "$base..$current" | grep . | sort -u || true)"
    both="$(comm -12 <(printf '%s\n' "$repaired") <(printf '%s\n' "$moved") | grep . || true)"
    gone=""
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      git cat-file -e "$base:$path" 2>/dev/null && continue # not added by the repair
      dir="$(dirname "$path")"
      [[ "$dir" == . ]] && continue
      if git cat-file -e "$base:$dir" 2>/dev/null && ! git cat-file -e "$current:$dir" 2>/dev/null; then
        gone+="$path"$'\n'
      fi
    done <<<"$repaired"
    if [[ -n "$both$gone" ]]; then
      echo "::error::$branch moved to ${current:0:12} after ${base:0:12}, and a newer commit wrote files this repair writes (or removed their directory); the next run repairs them:" >&2
      printf '%s\n%s' "$both" "$gone" | grep . | sed 's/^/  /' >&2
      exit 1
    fi
    echo "$branch moved to ${current:0:12} after ${base:0:12}; writing the repair onto it (no newer commit wrote its files)."
    git checkout --quiet --detach "$current"
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      if git cat-file -e "$repair:$path" 2>/dev/null; then
        git checkout --quiet "$repair" -- "$path"
      else
        git rm --quiet --cached --ignore-unmatch -- "$path"
        rm -f -- "$path"
      fi
    done <<<"$repaired"
    if git diff --cached --quiet; then
      echo "$branch at ${current:0:12} already holds this repair; nothing to push."
      exit 0
    fi
    git commit --quiet -C "$repair"
  fi
  # A plain push: it fails rather than overwrite a commit pushed meanwhile.
  if git push --quiet "$remote" "HEAD:refs/heads/$branch"; then
    echo "Pushed $(git rev-parse --short HEAD) to $branch."
    exit 0
  fi
  echo "$branch moved during the push (attempt $attempt of $attempts); trying again."
  git checkout --quiet --detach "$repair"
done
echo "::error::$branch kept moving; the next run repairs it." >&2
exit 1
