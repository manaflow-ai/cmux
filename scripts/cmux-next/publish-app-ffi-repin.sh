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
# gh prints a failed call's error body on stdout too, so print only a head read.
remote_head() {
  local err="$RUNNER_TEMP/remote-head.err" head
  if head="$(GH_TOKEN="$APP_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$1" --jq '.object.sha' 2>"$err")"; then
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::refs/heads/$1 read as '$head'" >&2; return 1; }
    echo "$head"
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

# First the pin straight on feat-cmux-next, the way the base autofix pins
# GhosttyKit (scripts/cmux-next/pin-app-ffi-on-base.sh): when the tip has this
# release's FFI sources and its C headers only add to the current pin's, the
# pin lands minutes after the release. Through the pull request below it waited
# for over an hour of CI, and an FFI change landing in that hour made it stale
# before it could land (#39863 re-pinned three times on 2026-11-10 and never
# landed, and base stayed red on "Check the app FFI pin"). Newer sources,
# changed headers, no BASE_TOKEN, a dry run (BASE_PIN_ENABLED is not true) or
# any failure there fall through to the pull request, as before.
start="$(git rev-parse HEAD)"
: > "$RUNNER_TEMP/pin-base.out"
base_result=""
if base_out="$(TOKEN="${BASE_TOKEN:-}" ENABLED="$([[ "${BASE_PIN_ENABLED:-}" == true && -n "${BASE_TOKEN:-}" ]] && echo true)" \
    GITHUB_OUTPUT="$RUNNER_TEMP/pin-base.out" bash scripts/cmux-next/pin-app-ffi-on-base.sh "$pin_sha" "$CHECKSUM" 2>&1)"; then
  base_result="$(sed -n 's/^result=//p' "$RUNNER_TEMP/pin-base.out" | tail -n 1)"
fi
echo "$base_out"
git checkout --quiet --force "$start"
case "$base_result" in
  pinned|already)
    echo "feat-cmux-next pins $TAG ($base_result); no re-pin pull request"
    # An open re-pin pull request now pins an older release (its diff conflicts
    # with the base's pin, so it cannot land): close it, best effort.
    if [[ -n "${GH_TOKEN:-}" ]] && stale="$(gh api "repos/$GITHUB_REPOSITORY/pulls?state=open&base=feat-cmux-next&head=${GITHUB_REPOSITORY%/*}:$branch" --jq '.[0].number // empty' 2>/dev/null)" \
        && [[ "$stale" =~ ^[0-9]+$ ]]; then
      gh pr close "$stale" --comment "feat-cmux-next now pins $TAG directly (scripts/cmux-next/pin-app-ffi-on-base.sh), so this re-pin is no longer needed." \
        || echo "::warning::could not close the stale re-pin pull request #$stale"
    fi
    exit 0 ;;
esac
echo "app FFI pin on feat-cmux-next: ${base_result:-failed}; the re-pin pull request carries it"
scripts/cmux-next/repin-app-ffi.sh "$pin_sha" "$CHECKSUM"
if git diff --quiet -- "$manifest"; then
  echo "feat-cmux-next already pins $TAG, the newest published release"
  exit 0
fi
tip="$(git rev-parse HEAD)"
previous="$(remote_head "$branch")"

# Hold a head under CI. Each force push cancels the open PR's checks, and its
# CI (the Mac queue, the fleet compile, daemon tests) takes longer than the gap
# between FFI publishes: on 2026-11-09 #39384 was moved at 08:22, 10:38, 11:49,
# 12:13 and 12:45, no head finished its checks, nothing landed for 6 hours and
# the pin fell 359 min behind (goal fix-running-ffi-pin, bound 120). So an open
# PR whose head is younger than REPIN_HOLD_MIN and has no failed check keeps
# its head and lands first; its merge changes Package.swift, and
# app-ffi-repin.yml then re-pins the newest release at once. A failed check, an
# older head or any failed read moves the head as before.
hold_min="${REPIN_HOLD_MIN:-90}"
# The head's commit, check runs and statuses are read with the job's
# GITHUB_TOKEN (contents, checks and statuses: read): the pull-request token
# has none of these, and a failed read would quietly turn the hold off.
read_api() { GH_TOKEN="${READ_TOKEN:?READ_TOKEN reads the checks at the head}" gh api "$@"; }
held_pr() {
  local number state head age failed status
  number="$(gh api "repos/$GITHUB_REPOSITORY/pulls?state=open&base=feat-cmux-next&head=${GITHUB_REPOSITORY%/*}:$branch" --jq '.[0].number // empty')" || return 1
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  read -r state head < <(gh api "repos/$GITHUB_REPOSITORY/pulls/$number" --jq '"\(.state) \(.head.sha)"') || return 1
  [[ "$state" == open && "$head" == "$previous" ]] || return 1
  age="$(read_api "repos/$GITHUB_REPOSITORY/commits/$previous" --jq '(now - (.commit.committer.date | fromdateiso8601)) / 60 | floor')" || return 1
  [[ "$age" =~ ^[0-9]+$ ]] || return 1
  if (( age >= hold_min )); then
    echo "#$number's head ${previous:0:12} is $age min old (hold $hold_min min): moving it" >&2
    return 1
  fi
  # One bounded page: a head with more check runs than it holds is moved.
  failed="$(read_api "repos/$GITHUB_REPOSITORY/commits/$previous/check-runs?per_page=100" \
    --jq 'if .total_count > (.check_runs | length) then "unread" else [.check_runs[] | select(.conclusion as $c
      | ["failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"] | index($c))] | length end')" ||
    return 1
  [[ "$failed" =~ ^[0-9]+$ ]] || return 1
  status="$(read_api "repos/$GITHUB_REPOSITORY/commits/$previous/status" --jq '.state')" || return 1
  [[ "$status" =~ ^(success|pending|failure|error)$ ]] || return 1
  [[ "$status" == failure || "$status" == error ]] && failed=$((failed + 1))
  if (( failed > 0 )); then
    echo "#$number's head ${previous:0:12} has $failed failed check(s): moving it" >&2
    return 1
  fi
  echo "kept #$number at ${previous:0:12}: pushed $age min ago (hold $hold_min min), no check failed; it lands first and its merge re-pins $TAG (app-ffi-repin.yml)"
}
if [[ -n "$previous" && -n "${GH_TOKEN:-}" ]] && held_pr; then
  exit 0
fi
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
