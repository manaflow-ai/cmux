#!/usr/bin/env bash
# Prepare the GitHub-signed pin before moving the PR's stable head (#33943).
set -euo pipefail
branch=app-ffi-repin
staging="${branch}-stage-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
manifest=Packages/macOS/CmuxNext/Package.swift
# Read heads from GitHub itself, not `git ls-remote origin`: the runner serves
# git reads of origin from a cache that can lag a push made a second earlier
# (run 42493097381 failed "the re-pin head moved" right after its own push).
# Prints nothing for a missing branch; any other failed read fails loud.
remote_head() {
  local err="$RUNNER_TEMP/remote-head.err"
  if GH_TOKEN="$APP_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$1" --jq '.object.sha' 2>"$err"; then
    return 0
  fi
  grep -q 'HTTP 404' "$err" && return 0
  echo "::error::could not read refs/heads/$1 from GitHub: $(cat "$err")" >&2
  return 1
}

# Latest wins: pin the newest published release on feat-cmux-next, whichever run
# published it, never this run's tag by default and never an unpublished head.
# Step-A pushes change the FFI sources faster than releases publish, so the
# base's sources may be ahead of the release picked here; it reads that
# release's SOURCE_SHA and SHA256SUMS itself (a 404 skips the release), and
# merge_hold accepts the pin once the app compiles against it.
picked="$(python3 scripts/cmux-next/newest_app_ffi_release.py)"
read -r pin_sha CHECKSUM <<<"$picked"
[[ "$pin_sha" =~ ^[0-9a-f]{40}$ && "$CHECKSUM" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "::error::no published app FFI release to pin (picked: $picked)" >&2; exit 1; }
TAG="cmux-app-ffi-$pin_sha"
scripts/cmux-next/repin-app-ffi.sh "$pin_sha" "$CHECKSUM"
if git diff --quiet -- "$manifest"; then
  echo "feat-cmux-next already pins $TAG, the newest published release"
  exit 0
fi
tip="$(git rev-parse HEAD)"
previous="$(remote_head "$branch")"
# Resetting the stable head to the unpinned base auto-closes its PR. Only this
# run's staging ref may hold that base while the contents API signs the pin.
cleanup() {
  git push origin --delete "$staging" >/dev/null 2>&1 ||
    echo "::warning::could not remove this run's staging ref $staging"
}
trap cleanup EXIT
git push origin "$tip:refs/heads/$staging"
blob="$(git rev-parse "$tip:$manifest")"
base64 -w0 "$manifest" > "$RUNNER_TEMP/manifest.b64"
jq -n --arg branch "$staging" --arg sha "$blob" --arg message "cmux-next: pin CCmuxAppFFI to $TAG" \
  --rawfile content "$RUNNER_TEMP/manifest.b64" '{$branch, $sha, $message, $content}' > "$RUNNER_TEMP/repin.json"
pinned="$(git hash-object "$manifest")"
for attempt in 1 2 3 4 5; do
  if pin_commit="$(GH_TOKEN="$APP_TOKEN" gh api -X PUT "repos/$GITHUB_REPOSITORY/contents/$manifest" \
      --input "$RUNNER_TEMP/repin.json" --jq '.commit.sha')"; then
    break
  fi
  # A successful write whose response was lost must not be repeated with the
  # old blob SHA. Find both the file and its signed commit on the staging ref.
  on_branch="$(GH_TOKEN="$APP_TOKEN" gh api "repos/$GITHUB_REPOSITORY/contents/$manifest?ref=$staging" --jq '.sha' || true)"
  if [[ "$on_branch" == "$pinned" ]]; then
    pin_commit="$(GH_TOKEN="$APP_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$staging" --jq '.object.sha')"
    break
  fi
  if [[ "$attempt" -eq 5 ]]; then
    echo "::error::the contents API refused the pin commit 5 times; $branch is unchanged" >&2
    exit 1
  fi
  sleep $((attempt * 10))
done
[[ "$pin_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::no signed pin commit" >&2; exit 1; }
git fetch --no-tags origin "$pin_commit"
if ! git push --force-with-lease="refs/heads/$branch:$previous" origin "$pin_commit:refs/heads/$branch"; then
  # A lost push response is harmless only if the intended commit is published.
  [[ "$(remote_head "$branch")" == "$pin_commit" ]] || exit 1
fi
[[ "$(remote_head "$branch")" == "$pin_commit" ]] || { echo "::error::the re-pin head moved" >&2; exit 1; }

body="Pins CCmuxAppFFI to [$TAG]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/releases/tag/$TAG) (checksum \`$CHECKSUM\`), the newest published app FFI release on feat-cmux-next (latest wins: newer FFI commits whose release is not published are skipped). Run $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID read its SOURCE_SHA and SHA256SUMS. A newer publish updates this branch.

## Changelog

none"
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "::warning title=Open the re-pin pull request::the release App has no pull-requests permission; open $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/compare/feat-cmux-next...$branch?expand=1"
  exit 0
fi
pr_number="$(gh api "repos/$GITHUB_REPOSITORY/pulls?state=open&base=feat-cmux-next&head=${GITHUB_REPOSITORY%/*}:$branch" --jq '.[0].number // empty')"
if [[ -n "$pr_number" ]]; then
  # A stale list may name a CLOSED PR; editing its title does not reopen it.
  state="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$pr_number" --jq '.state')"
  [[ "$state" == open ]] || pr_number=""
fi
if [[ -n "$pr_number" ]]; then
  gh pr edit "$pr_number" --title "cmux-next: pin CCmuxAppFFI to $TAG" --body "$body"
else
  url="$(gh pr create --base feat-cmux-next --head "$branch" --title "cmux-next: pin CCmuxAppFFI to $TAG" --body "$body")"
  pr_number="${url##*/}"
fi
[[ "$pr_number" =~ ^[0-9]+$ ]] || { echo "::error::no re-pin PR number" >&2; exit 1; }
gh api "repos/$GITHUB_REPOSITORY/pulls/$pr_number" > "$RUNNER_TEMP/repin-pr.json"
jq -e --arg sha "$pin_commit" --arg branch "$branch" \
  '.state == "open" and .base.ref == "feat-cmux-next" and .head.ref == $branch and .head.sha == $sha' \
  "$RUNNER_TEMP/repin-pr.json" >/dev/null || { echo "::error::re-pin PR is not open at the published head" >&2; exit 1; }
echo "verified open re-pin pull request #$pr_number at $pin_commit"
