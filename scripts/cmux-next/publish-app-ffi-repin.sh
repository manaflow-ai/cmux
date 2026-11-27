#!/usr/bin/env bash
# Prepare the GitHub-signed pin before moving the PR's stable head (#33943).
set -euo pipefail
branch=app-ffi-repin
staging="${branch}-stage-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
pin_file=Packages/macOS/CmuxNext/app-ffi-pin.json
# The pin file and Package.swift's checksum line move together (scripts/ci/app_ffi_pin.py).
manifest=Packages/macOS/CmuxNext/Package.swift

# A GitHub call refused for the rate limit waits and asks again. On 2026-11-20 a read of the held PR got "API rate
# limit exceeded for installation" (HTTP 403) in runs 44804668946, 44820694017 and 44823028309; held_pr took it for a
# failed read, and each job ended green with "left app-ffi-repin alone", so #48065 kept an older pin while every
# agent's Mac build lost the prebuilt FFI. The wait is the refusal's retry-after, else its x-ratelimit-reset when
# x-ratelimit-remaining is 0, else 60 s doubling. REPIN_RATE_LIMIT_WAIT_S (600) bounds all the waits of one run. A
# refusal past that bound, or one whose reset is further off, fails the job with the reason (rate_limit_gate), and a
# pushed run's failure step starts app-ffi-repin.yml: a silent green hid this. Any other failure is answered as before.
rate_limit_max="${REPIN_RATE_LIMIT_WAIT_S:-600}"
rate_limit_waited="$RUNNER_TEMP/rate-limit-waited"  # seconds waited so far: files, since most calls run in subshells
rate_limit_failed="$RUNNER_TEMP/rate-limit-failed"  # why a call gave up
echo 0 >"$rate_limit_waited"
: >"$rate_limit_failed"
exec 3>&2  # the job log, for the wait notes of a call whose stderr its caller captures or drops
# split_include OUT: OUT.headers gets the status line and headers that `gh api --include` prints before the first
# blank line, OUT.body the rest, byte for byte: gh prints a failed call's JSON error body with no final newline, and
# held_pr's `read ... < <(...)` fails on that (a failed read: the branch is left alone), as it did before gh_retry.
# Output with no status line (any other command) is all body.
split_include() {
  local blank
  : >"$1.headers"
  : >"$1.body"
  if ! head -n 1 "$1" | grep -qE '^HTTP/[0-9.]+ [0-9]{3}'; then
    cp "$1" "$1.body"
    return 0
  fi
  blank="$(awk '{ sub(/\r$/, "") } $0 == "" { print NR; exit }' "$1")"
  if [[ -z "$blank" ]]; then
    tr -d '\r' <"$1" >"$1.headers"
    return 0
  fi
  head -n "$((blank - 1))" "$1" | tr -d '\r' >"$1.headers"
  tail -n "+$((blank + 1))" "$1" >"$1.body"
}
header() { # header FILE NAME: the value of header NAME (any case) in FILE, anchored at the line's start
  awk -v name="$2" 'BEGIN { name = tolower(name) ":" }
    tolower(substr($0, 1, length(name))) == name { v = substr($0, length(name) + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }' "$1"
}
# error_lines OUT: what GitHub and gh said of a failed call in OUT, without gh's `hint:` block (gh 2.105 prints one
# on stderr, indented lines after it), so a hint's wording never reads as the refusal.
error_lines() { cat "$1.err" "$1.body" | grep -vE '^(hint:|[[:space:]])' || true; }
# rate_limited OUT: the failed call in OUT (.headers, .body, .err) was refused for the rate limit: an HTTP 429, a
# message that names a rate limit (primary, secondary or GraphQL), or a 403 with x-ratelimit-remaining 0. A 403 or
# 404 for anything else is not.
rate_limited() {
  local status
  status="$(sed -nE '1s/^HTTP\/[0-9.]+ ([0-9]{3}).*/\1/p' "$1.headers")"
  [[ -n "$status" ]] || status="$(grep -oE '\(HTTP [0-9]{3}\)' "$1.err" | tail -n 1 | tr -dc 0-9)"
  [[ "$status" == 429 ]] && return 0
  error_lines "$1" | grep -qiE 'rate limit|abuse detection|submitted too quickly' && return 0
  [[ "$status" == 403 && "$(header "$1.headers" x-ratelimit-remaining)" == 0 ]]
}
# rate_limit_wait HEADERS ATTEMPT: sets wait_s and wait_why for the next ask, or fails when the run's bound is spent
# or the limit lifts after it.
rate_limit_wait() {
  local retry remaining reset waited left
  waited="$(cat "$rate_limit_waited" 2>/dev/null || echo 0)"
  [[ "$waited" =~ ^[0-9]+$ ]] || waited=0
  left=$((rate_limit_max - waited))
  retry="$(header "$1" retry-after)" remaining="$(header "$1" x-ratelimit-remaining)" reset="$(header "$1" x-ratelimit-reset)"
  if [[ "$retry" =~ ^[0-9]+$ ]]; then
    wait_s=$((retry > 0 ? retry : 1)) wait_why="retry-after ${retry}s"
  elif [[ "$remaining" == 0 && "$reset" =~ ^[0-9]+$ ]]; then
    wait_s=$((reset - $(date +%s) + 1))
    ((wait_s > 0)) || wait_s=1
    wait_why="the limit resets at $(date -u -d "@$reset" +%H:%M:%SZ 2>/dev/null || date -u -r "$reset" +%H:%M:%SZ), in ${wait_s}s"
  else
    wait_s=$((60 << (($2 > 5 ? 5 : $2) - 1))) wait_why="no retry-after or reset, so a backoff"
    ((wait_s <= left)) || wait_s=$left
  fi
  if ((left <= 0 || wait_s > left)); then
    wait_why="$wait_why, past this run's ${rate_limit_max}s rate-limit wait (${waited}s waited)"
    return 1
  fi
  echo $((waited + wait_s)) >"$rate_limit_waited"
}
# gh_retry CMD ARGS...: CMD (gh, or a script that calls gh) answered as it answered, after waiting out GitHub's
# rate limit. `gh api` is asked with --include, so a refusal's headers say how long to wait; only its body is printed.
gh_retry() {
  local out status attempt=0 what="${*:1:3}" arg wait_s wait_why
  # A call that already gave up on the rate limit ends this run (rate_limit_gate): no more calls into the limit.
  [[ -s "$rate_limit_failed" ]] && return 1
  out="$(mktemp "$RUNNER_TEMP/gh-retry.XXXXXX")"
  for arg in "$@"; do [[ "$arg" == repos/* ]] && { what="$arg"; break; }; done
  while :; do
    status=0
    if [[ "$1" == gh && "${2:-}" == api ]]; then
      "$1" api --include "${@:3}" >"$out" 2>"$out.err" || status=$?
    else
      "$@" >"$out" 2>"$out.err" || status=$?
    fi
    split_include "$out"
    if ((status == 0)) || ! rate_limited "$out"; then
      break
    fi
    attempt=$((attempt + 1))
    if ! rate_limit_wait "$out.headers" "$attempt"; then
      echo "GitHub rate-limited $what: $(error_lines "$out" | grep -iE 'rate limit|abuse detection|submitted too quickly|HTTP [0-9]{3}' | head -n 1 | cut -c1-200); $wait_why" >"$rate_limit_failed"
      echo "::error title=Re-pin rate-limited::$(cat "$rate_limit_failed")" >&3
      break
    fi
    echo "rate limit: GitHub refused $what (attempt $attempt); asking again in ${wait_s}s ($wait_why)" >&3
    sleep "$wait_s"
  done
  cat "$out.body"
  cat "$out.err" >&2
  rm -f "$out" "$out.err" "$out.headers" "$out.body"
  return "$status"
}
# rate_limit_gate: after a call gave up on the rate limit, the job fails here, never a silent green.
rate_limit_gate() {
  [[ -s "$rate_limit_failed" ]] || return 0
  echo "the re-pin stopped: $(cat "$rate_limit_failed"); $branch is unchanged by this run"
  exit 1
}

# Read heads from GitHub itself, not `git ls-remote origin`: the runner serves
# git reads of origin from a cache that can lag a push made a second earlier
# (run 42493097381 failed "the re-pin head moved" right after its own push).
# Prints nothing for a missing branch; any other failed read fails loud.
# gh prints a failed call's error body on stdout too, so print only a head read.
remote_head() {
  local err="$RUNNER_TEMP/remote-head.err" head
  if head="$(GH_TOKEN="$APP_TOKEN" gh_retry gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$1" --jq '.object.sha' 2>"$err")"; then
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
# land-judge accepts the pin once the app compiles against it.
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
  number="$(gh_retry gh api "repos/$GITHUB_REPOSITORY/pulls?state=open&base=feat-cmux-next&head=${GITHUB_REPOSITORY%/*}:$branch" --jq '.[0].number // empty')" || return 1
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  read -r state head < <(gh_retry gh api "repos/$GITHUB_REPOSITORY/pulls/$number" --jq '"\(.state) \(.head.sha)"') || return 1
  [[ "$state" == open && "$head" == "$previous" ]] || return 1
  echo "$number"
}
if [[ "$current" != "$pin_sha" ]] && same_inputs "$current" "$pin_sha"; then
  # The base already has these inputs. An open re-pin PR whose pin is older than the picked release (a revert brought
  # the base's inputs back) is stale, so it closes. One that pins a newer commit is left: the picker falls back to an
  # older release when a newer one reads as unpublished (a 404), and that PR may be right.
  if [[ -n "$pr_pin" && "$pr_pin" != "$current" ]] && git merge-base --is-ancestor "$pr_pin" "$pin_sha" 2>/dev/null &&
      number="$(open_pr)"; then
    if gh_retry gh pr close "$number" --comment "feat-cmux-next already pins ${current:0:12}, which has the same app FFI inputs as the newest published release $TAG; this pull request pins the older ${pr_pin:0:12}, so it is closed (run $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)."; then
      echo "closed #$number, which pins ${pr_pin:0:12}: the base's pin ${current:0:12} has the inputs of $TAG"
    else
      rate_limit_gate
      echo "::warning title=Re-pin::could not close the stale re-pin pull request #$number"
    fi
  fi
  rate_limit_gate
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
read_runs() { GH_TOKEN="${READ_TOKEN:?READ_TOKEN reads the release runs}" gh_retry gh api "$@"; }
pending_newer() {
  local runs id head age jobs pin_time pin_age oldest
  # The clock is the base's oldest unpinned FFI commit, not only this release's: a release run holds for the next one
  # while every release's own commit is young, so with FFI pushes under REPIN_PENDING_MAX_MIN apart each run held for
  # the next and nothing pinned (2026-11-18: 44262749842, 44269219861 and 44272641346 each held, 07:56Z to 09:48Z,
  # and the pin trailed past the 120 min grace). A failed read keeps this release's commit time.
  if pin_time="$(git show -s --format=%ct "$pin_sha" 2>/dev/null)" && [[ "$pin_time" =~ ^[0-9]+$ ]]; then
    if [[ "$current" =~ ^[0-9a-f]{40}$ && ${#input_paths[@]} -gt 0 ]] &&
        oldest="$(git log --format=%ct "$current..$pin_sha" -- "${input_paths[@]}" 2>/dev/null | tail -n 1)" &&
        [[ "$oldest" =~ ^[0-9]+$ ]] && (( oldest < pin_time )); then
      pin_time="$oldest"
    fi
    pin_age=$(( ($(date +%s) - pin_time) / 60 ))
    if (( pin_age > pending_max_min )); then
      echo "$TAG's commit is $pin_age min old (bound $pending_max_min min): no newer run holds its re-pin" >&2
      return 1
    fi
  fi
  # Both workflows check out the feat-cmux-next tip. When it has this release's FFI inputs, every release run still
  # building is for a commit with those inputs or for a push after this checkout, which re-pins on its own: nothing to
  # hold for, and no read of the runs list, which the installation rate limit refused on 2026-11-25 (HTTP 403).
  if same_inputs "$(git rev-parse HEAD)" "$pin_sha"; then
    echo "feat-cmux-next's tip has $TAG's FFI inputs: no newer release run holds its re-pin" >&2
    return 1
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
newer="$(pending_newer)" || newer=""
rate_limit_gate
if [[ -n "$newer" ]]; then
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
pin_on_base() { # pin_on_base SHA CHECKSUM [PROVEN_PIN]: sets base_result
  : > "$RUNNER_TEMP/pin-base.out"
  base_result=""
  if base_out="$(PROVEN_PIN="${3:-}" TOKEN="${BASE_TOKEN:-}" ENABLED="$([[ "${BASE_PIN_ENABLED:-}" == true && -n "${BASE_TOKEN:-}" ]] && echo true)" \
      GITHUB_OUTPUT="$RUNNER_TEMP/pin-base.out" bash scripts/cmux-next/pin-app-ffi-on-base.sh "$1" "$2" 2>&1)"; then
    base_result="$(sed -n 's/^result=//p' "$RUNNER_TEMP/pin-base.out" | tail -n 1)"
  fi
  echo "$base_out"
  git checkout --quiet --force "$start"
}
# The re-pin PR's head proves its pin when the build fleet's compile of that head passed (the tip check's Release
# compile, scripts/ci/fleet_compile_result.py: no GitHub quota, and no --pr, which would submit a compile) and its
# cmux-next fast tier, which runs HandlerCoverageTests, succeeded with none of its jobs failed. The PR's whole rollup
# is not the proof: on 2026-11-25 release b6be67e4 changed a declaration over the pin (run 45645816280), went to
# #55633, whose rollup never went green on infra reds while base merges restarted its CI, and the pin sat about 11
# hours behind. A head that pins the base's own pin proves nothing new.
proven_pr_pin() {
  local verdict runs
  [[ -n "$pr_pin" && "$pr_pin" != "$current" && -n "$previous" ]] || return 1
  verdict="$(python3 -I scripts/ci/fleet_compile_result.py --sha "$previous" --repo "$GITHUB_REPOSITORY" \
    --wait 45 --no-record 0)" || verdict=none
  if [[ "$verdict" != pass ]]; then
    echo "the re-pin branch's head ${previous:0:12} has no passing app compile (${verdict:-none}); its pin stays on the pull request"
    return 1
  fi
  runs="$(GH_TOKEN="${READ_TOKEN:?READ_TOKEN reads the checks at the head}" \
    gh_retry python3 scripts/ci/gh_pages.py "repos/$GITHUB_REPOSITORY/commits/$previous/check-runs")" || return 1
  if ! jq -e '[.[] | select(.name | startswith("cmux-next fast tier"))]
      | any(.conclusion == "success") and all(.conclusion == "success" or .conclusion == "skipped")' <<<"$runs" >/dev/null; then
    echo "the re-pin branch's head ${previous:0:12} has no passing cmux-next fast tier yet; its pin stays on the pull request"
    return 1
  fi
}
pin_on_base "$pin_sha" "$CHECKSUM"
if [[ "$base_result" == pr ]] && proven_pr_pin; then
  # The head may pin an older release than the picked one: that one lands now, and the base's pin push starts
  # app-ffi-repin.yml, which re-pins the newer release from there.
  echo "the re-pin branch's head ${previous:0:12} passed its app compile and fast tier: pinning ${pr_pin:0:12} on feat-cmux-next"
  pin_on_base "$pr_pin" "$pr_sum" "$pr_pin"
  [[ "$base_result" == pinned || "$base_result" == already ]] && TAG="cmux-app-ffi-$pr_pin"
fi
rate_limit_gate
case "$base_result" in
  pinned|already)
    echo "feat-cmux-next pins $TAG ($base_result); no re-pin pull request"
    # An open re-pin pull request now pins an older release (its diff conflicts
    # with the base's pin, so it cannot land): close it, best effort.
    if [[ -n "${GH_TOKEN:-}" ]] && stale="$(gh_retry gh api "repos/$GITHUB_REPOSITORY/pulls?state=open&base=feat-cmux-next&head=${GITHUB_REPOSITORY%/*}:$branch" --jq '.[0].number // empty' 2>/dev/null)" \
        && [[ "$stale" =~ ^[0-9]+$ ]]; then
      gh_retry gh pr close "$stale" --comment "feat-cmux-next now pins $TAG directly (scripts/cmux-next/pin-app-ffi-on-base.sh), so this re-pin is no longer needed." \
        || { rate_limit_gate; echo "::warning::could not close the stale re-pin pull request #$stale"; }
    fi
    rate_limit_gate
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
# 8f7f9e7d to 1b93c4a6 (run 43937628010). A rate-limited read is not a failed
# read: it waits and asks again (gh_retry), and one still refused after the
# wait fails the job (rate_limit_gate) instead of leaving a stale head behind a
# green run (2026-11-20: #48065, runs 44804668946 and 44820694017).
hold_min="${REPIN_HOLD_MIN:-90}"
# The head's commit, check runs and statuses are read with the job's
# GITHUB_TOKEN (contents, checks and statuses: read): the pull-request token
# has none of these, and a failed read would quietly turn the hold off.
read_api() { GH_TOKEN="${READ_TOKEN:?READ_TOKEN reads the checks at the head}" gh_retry gh api "$@"; }
held_pr() {
  local number state head age failed status
  number="$(gh_retry gh api "repos/$GITHUB_REPOSITORY/pulls?state=open&base=feat-cmux-next&head=${GITHUB_REPOSITORY%/*}:$branch" --jq '.[0].number // empty')" || return 2
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  read -r state head < <(gh_retry gh api "repos/$GITHUB_REPOSITORY/pulls/$number" --jq '"\(.state) \(.head.sha)"') || return 2
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
      gh_retry python3 scripts/ci/gh_pages.py "repos/$GITHUB_REPOSITORY/commits/$1/check-runs")" || return 1
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
  # A workflow run that never started at the head has no check run, so the count above misses it, and the check it
  # owns stays pending for good. 2026-11-26: #58251's head a04b30c8 sat on a base whose cmux-next.yml was over GitHub's
  # 512,000-byte limit (fixed on the base by #59284), so next-autoland's cmux-next.yml dispatch 45880000763 ended
  # startup_failure, cmux-next/compile never left pending, and this hold kept the head while the pin fell 402 min
  # behind. The head's own workflow file is what failed, so a move onto the newer base is the fix.
  local unstarted
  unstarted="$(read_api "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$previous&per_page=100" \
    --jq '[.workflow_runs[] | select(.conclusion == "startup_failure")] | length')" || return 2
  [[ "$unstarted" =~ ^[0-9]+$ ]] || return 2
  failed=$((failed + unstarted))
  if (( failed > 0 )); then
    echo "#$number's head ${previous:0:12} has $failed failed check(s) of its own: moving it" >&2
    return 1
  fi
  echo "kept #$number at ${previous:0:12}: pushed $age min ago (hold $hold_min min), no check failed; it lands first and its merge re-pins $TAG (app-ffi-repin.yml)"
}
if [[ -n "$previous" && -n "${GH_TOKEN:-}" ]]; then
  held=0
  held_pr || held=$?
  rate_limit_gate
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
# PR sees both, and land-judge's pin-only rule reads the PR's whole diff.
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
pr_number="$(gh_retry gh api "repos/$GITHUB_REPOSITORY/pulls?state=open&base=feat-cmux-next&head=${GITHUB_REPOSITORY%/*}:$branch" --jq '.[0].number // empty')"
if [[ -n "$pr_number" ]]; then
  # A stale list may name a CLOSED PR; editing its title does not reopen it.
  state="$(gh_retry gh api "repos/$GITHUB_REPOSITORY/pulls/$pr_number" --jq '.state')"
  [[ "$state" == open ]] || pr_number=""
fi
if [[ -n "$pr_number" ]]; then
  # REST, not `gh pr edit`: the gh on the lane VMs still reads repository.pullRequest.projectCards, which GitHub
  # now answers with "Projects (classic) is being deprecated", so the edit failed after the push (run 44655157417).
  gh_retry gh api -X PATCH "repos/$GITHUB_REPOSITORY/pulls/$pr_number" -f title="cmux-next: pin CCmuxAppFFI to $TAG" \
    -f body="$body" --jq '.number' >/dev/null
else
  url="$(gh_retry gh pr create --base feat-cmux-next --head "$branch" --title "cmux-next: pin CCmuxAppFFI to $TAG" --body "$body")"
  pr_number="${url##*/}"
fi
[[ "$pr_number" =~ ^[0-9]+$ ]] || { echo "::error::no re-pin PR number" >&2; exit 1; }
# GitHub syncs a pull request's head some time after a push: on 2026-11-25 the PR still read 4910b844 after the
# force-push to 38e0d0d2, and the job failed here though the branch held the new pin (and its failure step spent the
# rate-limited quota on a dispatch). The PR is re-read a few times; an open PR on this branch whose branch GitHub
# serves at the published commit is published, and a head that still lags is a warning. A closed PR, another base or
# another branch still fails.
for attempt in 1 2 3 4; do
  gh_retry gh api "repos/$GITHUB_REPOSITORY/pulls/$pr_number" > "$RUNNER_TEMP/repin-pr.json"
  jq -e --arg branch "$branch" '.state == "open" and .base.ref == "feat-cmux-next" and .head.ref == $branch' \
    "$RUNNER_TEMP/repin-pr.json" >/dev/null || { echo "::error::re-pin PR is not open at the published head" >&2; exit 1; }
  if jq -e --arg sha "$pin_commit" '.head.sha == $sha' "$RUNNER_TEMP/repin-pr.json" >/dev/null; then
    echo "verified open re-pin pull request #$pr_number at $pin_commit"
    exit 0
  fi
  (( attempt < 4 )) && sleep $((attempt * 15))
done
[[ "$(remote_head "$branch")" == "$pin_commit" ]] || { echo "::error::re-pin PR is not open at the published head" >&2; exit 1; }
echo "::warning title=Re-pin::#$pr_number is open, and $branch is at ${pin_commit:0:12}, but GitHub still reads the pull request's head as $(jq -r '.head.sha[:12]' "$RUNNER_TEMP/repin-pr.json"); its head sync lags the push"
