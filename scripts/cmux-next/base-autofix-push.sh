#!/usr/bin/env bash
# Pushes base autofix's repair commit (HEAD, one commit on top of BASE_SHA) to
# BRANCH of REMOTE. feat-cmux-next takes a push every minute or two and the
# Mac export takes ten or more, so a run usually finds the branch moved. When
# it moved, the repair is replayed onto the new tip if no commit since touched
# a file the repair writes: the repair then never overwrites a newer edit, and
# a repaired output whose inputs moved meanwhile is still caught by its own
# freshness check and repaired by the next run. When a newer commit did touch
# one of those files, nothing is pushed and the run fails, so the next run
# (which diffs from the last successful one) repairs it.
#
# Usage: scripts/cmux-next/base-autofix-push.sh REMOTE BRANCH BASE_SHA
# Credentials come from the caller's environment (GIT_CONFIG_* extraheader).
set -euo pipefail
remote="${1:?usage: $0 REMOTE BRANCH BASE_SHA}"
branch="${2:?usage: $0 REMOTE BRANCH BASE_SHA}"
base="${3:?usage: $0 REMOTE BRANCH BASE_SHA}"
attempts="${CMUX_BASE_AUTOFIX_PUSH_ATTEMPTS:-5}"

repair="$(git rev-parse HEAD)"
[[ "$(git rev-parse HEAD^)" == "$(git rev-parse "$base^{commit}")" ]] || {
  echo "::error::the repair commit is not one commit on top of ${base:0:12}" >&2
  exit 1
}
repaired="$(git diff --name-only --no-renames "$base" "$repair" | sort -u)"

for (( attempt = 1; attempt <= attempts; attempt++ )); do
  current="$(git ls-remote "$remote" "refs/heads/$branch" | awk '{print $1}')"
  [[ -n "$current" ]] || { echo "::error::$branch is missing on the remote" >&2; exit 1; }
  if [[ "$current" != "$(git rev-parse HEAD^)" ]]; then
    git fetch --quiet --no-tags --depth=1 "$remote" "$current"
    moved="$(git diff --name-only --no-renames "$base" "$current" | sort -u)"
    both="$(comm -12 <(printf '%s\n' "$repaired") <(printf '%s\n' "$moved") | grep . || true)"
    if [[ -n "$both" ]]; then
      echo "::error::$branch moved to ${current:0:12} after ${base:0:12}, and a newer commit wrote files this repair writes; the next run repairs them:" >&2
      sed 's/^/  /' <<<"$both" >&2
      exit 1
    fi
    echo "$branch moved to ${current:0:12} after ${base:0:12}; replaying the repair onto it (no newer commit wrote its files)."
    git checkout --quiet --detach "$current"
    if ! git cherry-pick --allow-empty "$repair" > /dev/null; then
      git cherry-pick --abort || true
      echo "::error::the repair does not apply on ${current:0:12}; the next run repairs it." >&2
      exit 1
    fi
  fi
  # A plain push: it fails rather than overwrite a commit pushed meanwhile.
  if git push --quiet "$remote" "HEAD:refs/heads/$branch"; then
    echo "Pushed $(git rev-parse --short HEAD) to $branch."
    exit 0
  fi
  echo "$branch moved during the push (attempt $attempt of $attempts); trying again."
done
echo "::error::$branch kept moving; the next run repairs it." >&2
exit 1
