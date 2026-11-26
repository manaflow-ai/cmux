#!/usr/bin/env bash
# Repo archive publisher (hq RFD 0065 piece 1): on the controller, for each active repo and branch,
# put a depth-1 `.git` archive (or the increment since it) into the repo archive store, from the
# fleet's `wt` mirrors. Run by cmux-repo-archive-publish.timer; one JSON line per branch.
#
# Off until configured: with no store (CMUX_REPO_ARCHIVE_STORE, or `store` in
# /etc/cmux/repo-archive.json) it says so and exits 0. Its environment file
# (~/.config/cmux-repo-archive-publish.env) names:
#   CMUX_REPO_ARCHIVE_STORE   a folder, file:// URL, or bucket URL (https://ACCOUNT.r2.cloudflarestorage.com/BUCKET)
#   CMUX_PROJECTION_S3_ACCESS_KEY_ID / CMUX_PROJECTION_S3_SECRET_ACCESS_KEY  write keys for a bucket
#   CMUX_REPO_ARCHIVE_REPOS   space-separated OWNER/NAME:BRANCH[,BRANCH...]; the first branch is the
#                             repo's default (default: manaflow-ai/cmux:feat-cmux-next,main)
#   CMUX_REPO_ARCHIVE_MIRRORS the mirrors folder (default ~/Projects/.wt-mirrors)
#   CMUX_PROJECTION_BIN       the cmux-projection binary (default: on PATH)
set -uo pipefail

mirrors=${CMUX_REPO_ARCHIVE_MIRRORS:-$HOME/Projects/.wt-mirrors}
repos=${CMUX_REPO_ARCHIVE_REPOS:-manaflow-ai/cmux:feat-cmux-next,main}
bin=${CMUX_PROJECTION_BIN:-cmux-projection}

if [ -z "${CMUX_REPO_ARCHIVE_STORE:-}" ] && ! [ -s /etc/cmux/repo-archive.json ]; then
  echo "repo-archive: no store configured (CMUX_REPO_ARCHIVE_STORE); nothing published"
  exit 0
fi

status=0
for entry in $repos; do
  repo=${entry%%:*}
  branches=${entry#*:}
  [ "$branches" = "$entry" ] && branches=main
  source="$mirrors/$repo.git"
  if ! [ -d "$source" ]; then
    echo "repo-archive: no mirror $source for $repo; skipped" >&2
    status=1
    continue
  fi
  args=(repo-archive-publish --source "$source" --url "https://github.com/$repo.git" --default "${branches%%,*}")
  IFS=, read -r -a list <<<"$branches"
  for branch in "${list[@]}"; do args+=(--branch "$branch"); done
  # The mirror's own lock keeps `wt`'s fetch from repacking under the read.
  if [ -e "$source.fetch.lock" ] && command -v flock >/dev/null; then
    flock -s -w 600 "$source.fetch.lock" "$bin" "${args[@]}" || status=1
  else
    "$bin" "${args[@]}" || status=1
  fi
done
exit "$status"
