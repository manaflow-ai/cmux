#!/usr/bin/env bash
# Prepare the GitHub-signed pin before moving the PR's stable head (#33943).
set -euo pipefail
branch=app-ffi-repin
staging="${branch}-stage-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
pin_file=Packages/macOS/CmuxNext/app-ffi-pin.json
# The pin file and Package.swift's checksum line move together (scripts/ci/app_ffi_pin.py).
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
# A release built from the FFI inputs already pinned is not re-pinned (2026-11-10: the bot moved #39863 to a release
# of the same sources with a new checksum, since the archive is not byte-reproducible): neither the base's pin nor the
# pin at the head of the open re-pin PR is moved to it. Any failed read re-pins as before.
pin_of() { # pin_of DIR: "SOURCE_SHA CHECKSUM" of the pin files in DIR, read as the pin check reads them
  python3 -I scripts/ci/app_ffi_pin.py read-pin-file "$1/app-ffi-pin.json" "$1/Package.swift"
}
pin_err="$RUNNER_TEMP/current-pin.err"
current="$(pin_of Packages/macOS/CmuxNext 2>"$pin_err" | awk '{print $1}' || true)"
[[ "$current" =~ ^[0-9a-f]{40}$ ]] ||
  echo "::notice title=Re-pin::could not read the current pin ($(head -c 300 "$pin_err")); re-pinning as before"
# The inputs as the tip's pin check lists them (its Cargo graph): a crate that left the graph since an older pin is
# not compared, but a dependency change is itself a change to a listed input (a crate's Cargo.toml), so it still counts.
input_paths=()
if inputs="$(bash scripts/cmux-next/check-app-ffi-pin.sh --list-inputs)" && [[ -n "$inputs" ]]; then
  mapfile -t input_paths <<<"$inputs"
fi
same_inputs() { # same_inputs A B: exit 0 when the app FFI inputs of commits A and B are the same (a failed read: no)
  [[ "$1" =~ ^[0-9a-f]{40}$ && ${#input_paths[@]} -gt 0 ]] || return 1
  [[ "$1" == "$2" ]] || git diff --quiet "$1" "$2" -- "${input_paths[@]}"
}
previous="$(remote_head "$branch")"
# The pin at the re-pin branch's head (fetched, since its signed commit may be newer than this checkout).
pr_pin="" pr_sum=""
if [[ -n "$previous" ]] && git fetch --quiet --no-tags origin "$previous" 2>/dev/null; then
  pr_dir="$(mktemp -d)"
  # A head without a canonical pin file (one from before the pin moved to app-ffi-pin.json) pins nothing here.
  if git show "$previous:$manifest" >"$pr_dir/Package.swift" 2>/dev/null &&
      git show "$previous:$pin_file" >"$pr_dir/app-ffi-pin.json" 2>/dev/null; then
    read -r pr_pin pr_sum < <(pin_of "$pr_dir" 2>/dev/null || true) || true
    [[ "$pr_pin" =~ ^[0-9a-f]{40}$ && "$pr_sum" =~ ^[0-9a-f]{64}$ ]] || pr_pin="" pr_sum=""
  fi
  rm -rf "$pr_dir"
fi
open_pr() { # the number of the open re-pin PR at $previous, or nothing
  local number state head
  [[ -n "$previous" && -n "${GH_TOKEN:-}" ]] || return 1
  number="$(gh api "repos/$GITHUB_REPOSITORY/pulls?state=open&base=feat-cmux-next&head=${GITHUB_REPOSITORY%/*}:$branch" --jq '.[0].number // empty')" || return 1
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  read -r state head < <(gh api "repos/$GITHUB_REPOSITORY/pulls/$number" --jq '"\(.state) \(.head.sha)"') || return 1
  [[ "$state" == open && "$head" == "$previous" ]] || return 1
  echo "$number"
}
if [[ "$current" != "$pin_sha" ]] && same_inputs "$current" "$pin_sha"; then
  # The base already has these inputs. An open re-pin PR whose pin is older than the picked release (a revert brought
  # the base's inputs back) is stale, so it closes. One that pins a newer commit is left: the picker falls back to an
  # older release when a newer one reads as unpublished (a 404), and that PR may be right.
  if [[ -n "$pr_pin" && "$pr_pin" != "$current" ]] && git merge-base --is-ancestor "$pr_pin" "$pin_sha" 2>/dev/null &&
      number="$(open_pr)"; then
    if gh pr close "$number" --comment "feat-cmux-next already pins ${current:0:12}, which has the same app FFI inputs as the newest published release $TAG; this pull request pins the older ${pr_pin:0:12}, so it is closed (run $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)."; then
      echo "closed #$number, which pins ${pr_pin:0:12}: the base's pin ${current:0:12} has the inputs of $TAG"
    else
      echo "::warning title=Re-pin::could not close the stale re-pin pull request #$number"
    fi
  fi
  echo "$TAG has the same app FFI inputs as the pinned ${current:0:12}: nothing to re-pin"
  exit 0
fi
# Wait for a newer release that is still building (2026-11-10: #39863 at 8c29468b pinned 1818fd17 while the run for
# the newer input commit b2fb62c7 was queued, so the re-pin was stale on arrival). Another app-ffi-release.yml run on
# feat-cmux-next holds this re-pin when all hold:
# - its commit is newer than the picked release (not its ancestor, or not in this checkout: pushed after it). Its age
#   against this run's commit does not matter: in app-ffi-repin.yml that commit is the pin merge, newer than every run
#   still building, and a run whose publish failed may still be overtaken by an older run that publishes;
# - its own re-pin job is still to come (missing, or not completed): a run stays in progress after that job ended
#   while its macOS cross-compile shadow runs, and its re-pin job runs even when the run ends with no release, so the
#   pin always has an owner. Two runs never hold for each other: the app-ffi-repin group runs one re-pin job at a
#   time, so the one that ran first is completed when the other reads it (a cancelled pending job is completed too,
#   and the newer one that cancelled it re-pins later);
# - it was created at most REPIN_PENDING_MAX_MIN ago: a run stuck waiting for a runner never holds for long. The
#   hold plus the build's timeout-minutes (45) stays under the 120 min "Check the app FFI pin" grace
#   (cmux-next.yml --stale-grace 7200), so a held release never waits on a newer run that cannot publish inside the
#   grace. It was 180 min, longer than the grace itself (2026-11-14, hq#10943: ead26e75 held for a run queued on a
#   stalled Blacksmith label). test_app_ffi_release_workflow.py test_the_re_pin_hold_ends_inside_the_pin_grace keeps
#   the sum under the grace.
# Nothing holds once this release's own commit is older than REPIN_PENDING_MAX_MIN: the base's oldest unpinned FFI
# commit is at least that old, so waiting for a newer run would run it past the grace, while pinning this release now
# restarts the clock at the next FFI commit, which the newer run then covers.
# A failed read re-pins as before. When the holding run's re-pin job fails, its failure step starts app-ffi-repin.yml.
pending_max_min="${REPIN_PENDING_MAX_MIN:-60}"
read_runs() { GH_TOKEN="${READ_TOKEN:?READ_TOKEN reads the release runs}" gh api "$@"; }
pending_newer() {
  local runs id head age jobs pin_time pin_age
  if pin_time="$(git show -s --format=%ct "$pin_sha" 2>/dev/null)" && [[ "$pin_time" =~ ^[0-9]+$ ]]; then
    pin_age=$(( ($(date +%s) - pin_time) / 60 ))
    if (( pin_age > pending_max_min )); then
      echo "$TAG's commit is $pin_age min old (bound $pending_max_min min): no newer run holds its re-pin" >&2
      return 1
    fi
  fi
  if ! runs="$(read_runs \
      "repos/$GITHUB_REPOSITORY/actions/workflows/app-ffi-release.yml/runs?branch=feat-cmux-next&per_page=100" \
      --jq '.workflow_runs[] | select(.status != "completed")
        | "\(.id) \(.head_sha) \((now - ((.created_at // "") | if . == "" then now else fromdateiso8601 end)) / 60 | floor)"')"; then
    echo "::warning title=Re-pin::could not read the app FFI release runs; re-pinning $TAG as before" >&2
    return 1
  fi
  while read -r id head age; do
    [[ "$id" =~ ^[0-9]+$ && "$head" =~ ^[0-9a-f]{40}$ && "$age" =~ ^-?[0-9]+$ ]] || continue
    [[ "$id" != "${GITHUB_RUN_ID:-}" && "$head" != "$pin_sha" ]] || continue
    git merge-base --is-ancestor "$head" "$pin_sha" 2>/dev/null && continue
    if (( age > pending_max_min )); then
      echo "release run $id for ${head:0:12} was created $age min ago (bound $pending_max_min min): ignored" >&2
      continue
    fi
    if ! jobs="$(read_runs "repos/$GITHUB_REPOSITORY/actions/runs/$id/jobs?per_page=100" \
        --jq '[.jobs[] | select(.name == "open the re-pin pull request") | .status] | if length == 0 then "to-come"
          elif all(. == "completed") then "done" else "to-come" end')"; then
      echo "::warning title=Re-pin::could not read release run $id's jobs; it does not hold the re-pin" >&2
      continue
    fi
    [[ "$jobs" == to-come ]] || continue
    echo "$id $head"
    return 0
  done <<<"$runs"
  return 1
}
if newer="$(pending_newer)"; then
  read -r newer_run newer_sha <<<"$newer"
  echo "::notice title=Re-pin held::release run $newer_run for ${newer_sha:0:12}, newer than $TAG, has its re-pin still to come: run $newer_run re-pins; this run leaves $branch alone ($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$newer_run)"
  exit 0
fi
# A re-pin branch that already pins these inputs keeps its release: the normal path below then keeps a young head
# with no failed check, and rebuilds an older or failing head, or replaces a closed PR, with that same release, so the
# checksum does not churn and the pin keeps an owner.
if [[ -n "$pr_pin" && "$pr_pin" != "$pin_sha" ]] && same_inputs "$pr_pin" "$pin_sha"; then
  echo "the re-pin branch pins ${pr_pin:0:12}, with the same app FFI inputs as $TAG: keeping that release"
  pin_sha="$pr_pin" CHECKSUM="$pr_sum" TAG="cmux-app-ffi-$pr_pin"
fi

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
if git diff --quiet -- "$pin_file" "$manifest"; then
  echo "feat-cmux-next already pins $TAG, the newest published release"
  exit 0
fi
tip="$(git rev-parse HEAD)"

# Hold a head under CI. Each force push cancels the open PR's checks, and its
# CI (the Mac queue, the fleet compile, daemon tests) takes longer than the gap
# between FFI publishes: on 2026-11-09 #39384 was moved at 08:22, 10:38, 11:49,
# 12:13 and 12:45, no head finished its checks, nothing landed for 6 hours and
# the pin fell 359 min behind (goal fix-running-ffi-pin, bound 120). So an open
# PR whose head is younger than REPIN_HOLD_MIN and has no failed check keeps
# its head and lands first; its merge changes app-ffi-pin.json, and
# app-ffi-repin.yml then re-pins the newest release at once. A failed check of
# its own or an older head moves the head (held_pr returns 1). A failed read
# leaves the branch alone (returns 2), and the next re-pin run decides: a move
# costs the head its whole CI, a wait costs nothing while the PR stays open. On
# 2026-11-16 the open-PR read hit the App's rate limit and moved #44074 from
# 8f7f9e7d to 1b93c4a6 (run 43937628010).
hold_min="${REPIN_HOLD_MIN:-90}"
# The head's commit, check runs and statuses are read with the job's
# GITHUB_TOKEN (contents, checks and statuses: read): the pull-request token
# has none of these, and a failed read would quietly turn the hold off.
read_api() { GH_TOKEN="${READ_TOKEN:?READ_TOKEN reads the checks at the head}" gh api "$@"; }
held_pr() {
  local number state head age failed status
  number="$(gh api "repos/$GITHUB_REPOSITORY/pulls?state=open&base=feat-cmux-next&head=${GITHUB_REPOSITORY%/*}:$branch" --jq '.[0].number // empty')" || return 2
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  read -r state head < <(gh api "repos/$GITHUB_REPOSITORY/pulls/$number" --jq '"\(.state) \(.head.sha)"') || return 2
  [[ "$state" == open && "$head" == "$previous" ]] || return 1
  age="$(read_api "repos/$GITHUB_REPOSITORY/commits/$previous" --jq '(now - (.commit.committer.date | fromdateiso8601)) / 60 | floor')" || return 2
  [[ "$age" =~ ^[0-9]+$ ]] || return 2
  if (( age >= hold_min )); then
    echo "#$number's head ${previous:0:12} is $age min old (hold $hold_min min): moving it" >&2
    return 1
  fi
  # Every page of check runs, at the head and at the base commit it was staged on: a check that fails the same way
  # on the base is not the head's own, so it does not move the head. One page, any failure counted: #44074
  # (2026-11-16) had about 200 check runs and the cmux-next checks job red on base reds, so every publish moved it
  # (6f1d36c1, fe47e481, a30893db, c5a8aa57) and no head finished its CI. A failed base read counts every failure.
  # One bounded page per call (scripts/ci/gh_pages.py): the gh quota wrapper refuses an unbounded paginating call.
  # A cancelled check run is not a failure of the head. This script's own PR edit (the title and body below) starts a
  # pull_request `edited` run, and a workflow whose group cancels in progress (cmux-next-size-budget.yml) cancels the
  # head's run with it: on 2026-11-17 #45149's head df6ee657 had its size budget checks cancelled at 08:01Z, a minute
  # after its push, and at 08:53Z re-pin run 44042861860 moved it for "8 failed check(s) of its own" while its Mac jobs
  # had been queued 47 minutes. The move cancelled those, the CI started over, and feat-cmux-next stayed red on "Check
  # the app FFI pin". A head whose cancelled check never runs again is still moved once it is older than the hold.
  failed_names() {
    local runs
    runs="$(GH_TOKEN="${READ_TOKEN:?READ_TOKEN reads the checks at the head}" \
      python3 scripts/ci/gh_pages.py "repos/$GITHUB_REPOSITORY/commits/$1/check-runs")" || return 1
    jq -r '.[] | select(.conclusion as $c
      | ["failure", "timed_out", "action_required", "startup_failure", "stale"] | index($c)) | .name' <<<"$runs"
  }
  local head_failed base_failed="" staged_on
  head_failed="$(failed_names "$previous")" || return 2
  if staged_on="$(git merge-base "$previous" "$tip" 2>/dev/null)" && [[ "$staged_on" =~ ^[0-9a-f]{40}$ ]]; then
    base_failed="$(failed_names "$staged_on")" || base_failed=""
  fi
  failed="$(comm -23 <(sed '/^$/d' <<<"$head_failed" | sort -u) <(sed '/^$/d' <<<"$base_failed" | sort -u) | wc -l)"
  failed="${failed//[[:space:]]/}"
  [[ "$failed" =~ ^[0-9]+$ ]] || return 2
  status="$(read_api "repos/$GITHUB_REPOSITORY/commits/$previous/status" --jq '.state')" || return 2
  [[ "$status" =~ ^(success|pending|failure|error)$ ]] || return 2
  [[ "$status" == failure || "$status" == error ]] && failed=$((failed + 1))
  if (( failed > 0 )); then
    echo "#$number's head ${previous:0:12} has $failed failed check(s) of its own: moving it" >&2
    return 1
  fi
  echo "kept #$number at ${previous:0:12}: pushed $age min ago (hold $hold_min min), no check failed; it lands first and its merge re-pins $TAG (app-ffi-repin.yml)"
}
if [[ -n "$previous" && -n "${GH_TOKEN:-}" ]]; then
  held=0
  held_pr || held=$?
  if (( held == 0 )); then
    exit 0
  elif (( held == 2 )); then
    echo "::warning title=Re-pin::could not read the re-pin pull request's state at ${previous:0:12}; left $branch alone, and the next re-pin run decides"
    exit 0
  fi
fi
# Resetting the stable head to the unpinned base auto-closes its PR. Only this
# run's staging ref may hold that base while the contents API signs the pin.
cleanup() {
  git push origin --delete "$staging" >/dev/null 2>&1 ||
    echo "::warning::could not remove this run's staging ref $staging"
}
trap cleanup EXIT
git push origin "$tip:refs/heads/$staging"
# One signed contents-API commit per file, the pin file first: a reviewer of the
# PR sees both, and merge_hold's pin-only rule reads the PR's whole diff.
put_file() {
  local file="$1" blob pinned on_branch attempt
  blob="$(git rev-parse "$tip:$file")"
  base64 -w0 "$file" > "$RUNNER_TEMP/pin-file.b64"
  jq -n --arg branch "$staging" --arg sha "$blob" --arg message "cmux-next: pin CCmuxAppFFI to $TAG ($file)" \
    --rawfile content "$RUNNER_TEMP/pin-file.b64" '{$branch, $sha, $message, $content}' > "$RUNNER_TEMP/repin.json"
  pinned="$(git hash-object "$file")"
  for attempt in 1 2 3 4 5; do
    if pin_commit="$(GH_TOKEN="$APP_TOKEN" gh api -X PUT "repos/$GITHUB_REPOSITORY/contents/$file" \
        --input "$RUNNER_TEMP/repin.json" --jq '.commit.sha')"; then
      return 0
    fi
    # A successful write whose response was lost must not be repeated with the
    # old blob SHA. Find both the file and its signed commit on the staging ref.
    on_branch="$(GH_TOKEN="$APP_TOKEN" gh api "repos/$GITHUB_REPOSITORY/contents/$file?ref=$staging" --jq '.sha' || true)"
    if [[ "$on_branch" == "$pinned" ]]; then
      pin_commit="$(GH_TOKEN="$APP_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$staging" --jq '.object.sha')"
      return 0
    fi
    if [[ "$attempt" -eq 5 ]]; then
      echo "::error::the contents API refused the pin commit of $file 5 times; $branch is unchanged" >&2
      exit 1
    fi
    sleep $((attempt * 10))
  done
}
pin_commit=""
for file in "$pin_file" "$manifest"; do
  if ! git diff --quiet "$tip" -- "$file"; then put_file "$file"; fi
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
