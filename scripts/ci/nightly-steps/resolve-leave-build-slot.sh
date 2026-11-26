#!/usr/bin/env bash
# nightly.yml resolve-nightly-cmux-tui-client: "Leave the build slot to a newer nightly-next push". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# Latest wins (docs/ci/nightly-workflow-notes.md#note-16). A run leaves the slot, before any build job starts, when
# nightly-next moved past its commit: the newer push's run is pending in the same group and builds the head.
# A stale run waits here for that move first: a loop retry (it rebuilds a commit that just failed), or a push run that
# sat YIELD_STALE_MINUTES or more in the group behind another build, while feat-cmux-next has commits after it.
# Main's tick does not count a run in this step as building (nightly_next_rolling.py, LEAVE_SLOT_STEP), so its
# next pass (the finished build's tick, or the 5-minute cron) promotes the newest buildable commit and this run
# leaves. Run 43558081148 of a22a4eb1 waited 23 min behind another build, started at 05:06 with 20 newer commits on
# feat-cmux-next and failed; its retry 43560964857 built a22a4eb1 again: 60.9 min from landing to the feed.
# With nothing promoted at the one read the run builds its own commit at once (no poll loop). A fresh push run never waits.
# A push run's wait is the time before its first job was queued (from this attempt's start: run_started_at) plus
# each started job's own queue time (created_at to started_at; a job is created when its needs end): its own decide
# and resolve steps are not waiting. Counted from creation to this step, run 44893172356 of 89a0aaea (2026-11-21) read 6 min (1.4 min
# of decide, 4.8 of "Build the tip while its tree publishes", in a group of its own: NIGHTLY_NEXT_ONE_JOB=on gives
# every push run one), waited the whole YIELD_MINUTES for a promotion nothing asked for and built its commit 6 min late.
# IN_SLOT=1: nightly-next-one's first step, once its group (nightly-next-one-push) admits it. A run that waited
# YIELD_STALE_MINUTES or more at that slot (from resolve's end) is stale the same way, and one that leaves sets
# LEFT_SLOT=1 in the job's env: every later build and publish step skips, so it ends green with nothing cancelled.
# At the slot (IN_SLOT=1) a stale run waits for nothing on the signing Mac (2026-11-19). Of 83.0 Mac-minutes that 29
# nightly-next runs with no feed held, 63.5 were this step waiting for main's next tick to promote (run 44014825385:
# 24.7 min, partly gh_budget_wait.sh's hour-long rate-limit wait). Leo: "if i wait for the nightly then i might as well
# just update to the thing". So it asks main's tick at once (gh workflow run nightly-next-tick.yml, bounded, fail-open)
# and leaves with pending=true; wake-nightly-next-tick, on a nightly-only mini, then dispatches the loop's retry of
# this commit unless nightly-next already moved (nightly-steps/slot-left-retry.sh). That retry waits for the promotion
# in resolve (this script without IN_SLOT, off the signing Mac) and leaves to it, or builds this commit after
# YIELD_MINUTES. The loop's last retry (LOOP_RETRY 2) has no retry after it, so at the slot it asks the tick and builds.
# It builds too when no commit after its own has a published tree (newer_marked, below): the tick promotes only those
# (or the tip, tree-pending), so leaving would only bring this commit back two retries later.
# Every gh call here is bounded (timeout.sh) and never waits through a rate limit (GH_BUDGET_WAIT_MAX_SECONDS=0): a
# refused or slow read is unknown, which keeps the slot and builds, as before.
# Env: TIP_SHA, REPOSITORY, GH_TOKEN; LOOP_RETRY (nightly_next_loop_retry); SUPERSEDE_SKIP (vars.NIGHTLY_NEXT_SUPERSEDE_SKIP,
# a push run leaves without waiting only with 1); YIELD_STALE_MINUTES (5), YIELD_MINUTES (6), YIELD_POLL_SECONDS (15);
# GH_CALL_SECONDS (30, each gh call's bound).
set -euo pipefail
export GH_BUDGET_WAIT_MAX_SECONDS=0
here="$(dirname "${BASH_SOURCE[0]}")"
gh_bounded() { bash "$here/../timeout.sh" "${GH_CALL_SECONDS:-30}" gh "$@"; }
next_head() { gh_bounded api "repos/$REPOSITORY/git/ref/heads/nightly-next" --jq .object.sha 2>/dev/null || true; }
# The wait reads the ref with git ls-remote against the public repository: no API budget
# (tests/test_ci_no_github_token_polling.py). It reads through origin-net.sh's remote_refs, one try per poll
# (the loop is the retry): a remote that does not answer is named and reads as "not moved yet", never as a ref.
# shellcheck source=scripts/cmux-next/lib/origin-net.sh
source "$here/../../cmux-next/lib/origin-net.sh"
poll_head() {
  local refs
  if refs="$(ORIGIN_NET_TRIES=1 remote_refs . "${NIGHTLY_NEXT_REMOTE:-https://github.com/$REPOSITORY}" refs/heads/nightly-next)"; then
    printf '%s\n' "$refs" | cut -f1
  fi
}
moved() { [[ "$1" =~ ^[0-9a-f]{40}$ && "$1" != "$TIP_SHA" ]]; }
leave() {
  echo "superseded=true" >> "$GITHUB_OUTPUT"
  if [[ -n "${IN_SLOT:-}" ]]; then echo "LEFT_SLOT=1" >> "$GITHUB_ENV"; fi
  echo "::notice title=Superseded::nightly-next moved from $TIP_SHA to $1; the newer push's run builds it"
  exit 0
}
current="$(next_head)"
if moved "$current" && [[ -n "${LOOP_RETRY:-}" || "${SUPERSEDE_SKIP:-}" == 1 ]]; then
  leave "$current"
fi
minutes_since() { python3 -c 'import datetime as d,sys; print(int((d.datetime.now(d.timezone.utc)-d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00"))).total_seconds()//60))' "$1" 2>/dev/null; }
# Whole minutes from ISO time $1 to ISO time $2; nothing when either is not a time.
minutes_between() { python3 -c 'import datetime as d,sys; t=lambda v: d.datetime.fromisoformat(v.replace("Z","+00:00")); print(int((t(sys.argv[2])-t(sys.argv[1])).total_seconds()//60))' "$1" "$2" 2>/dev/null; }
stale=""
if [[ -n "${IN_SLOT:-}" ]]; then
  # The wait at the slot: since this run's resolve job ended (nightly-next-one queued then). A retry's age was
  # already counted before the slot; here only the slot wait counts, so a run admitted at once builds at once.
  if ended="$(gh_bounded api "repos/$REPOSITORY/actions/runs/${GITHUB_RUN_ID:-0}/attempts/${GITHUB_RUN_ATTEMPT:-1}/jobs?per_page=100" \
      --jq '.jobs[] | select(.name == "resolve-nightly-cmux-tui-client") | .completed_at' 2>/dev/null)" \
    && waited="$(minutes_since "$ended")" && (( waited >= ${YIELD_STALE_MINUTES:-5} )); then
    stale="a run that waited $waited min at nightly-next-one's push slot"
  fi
elif [[ -n "${LOOP_RETRY:-}" ]]; then
  stale="a loop retry of $TIP_SHA"
elif created="$(gh_bounded api "repos/$REPOSITORY/actions/runs/${GITHUB_RUN_ID:-0}" --jq '.run_started_at // .created_at' 2>/dev/null)" \
  && queued="$(gh_bounded api "repos/$REPOSITORY/actions/runs/${GITHUB_RUN_ID:-0}/attempts/${GITHUB_RUN_ATTEMPT:-1}/jobs?per_page=100" \
    --jq '[.jobs[] | select(.started_at != null and .created_at != null)] | "\(map(.created_at) | min) \(map((.started_at | fromdateiso8601) - (.created_at | fromdateiso8601)) | add)"' 2>/dev/null)" \
  && [[ "$queued" =~ ^([0-9T:Z-]+)\ ([0-9]+)$ ]] \
  && before="$(minutes_between "$created" "${BASH_REMATCH[1]}")" \
  && waited=$(( before + BASH_REMATCH[2] / 60 )) \
  && (( waited >= ${YIELD_STALE_MINUTES:-5} )); then
  stale="a push run that waited $waited min for the build slot"
fi
tip="$(gh_bounded api "repos/$REPOSITORY/git/ref/heads/feat-cmux-next" --jq .object.sha 2>/dev/null || true)"
if [[ -z "$stale" || ! "$tip" =~ ^[0-9a-f]{40}$ || "$tip" == "$TIP_SHA" ]]; then
  echo "superseded=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
# Whether a commit after TIP_SHA, up to $tip, has a published tree (tree-commit-marker.sh: a public read, no API
# budget). Main's tick promotes only such commits (or the tip, tree-pending), so with none of them a run that leaves
# the slot comes back to build its own commit: run 44935705074 of c3ddff (2026-11-21) left at 18:40 with nothing
# marked, its two retries yielded 6 min each (one failed on another Mac) and built c3ddff at 19:03, 24 min after the
# slot was free. Prints "marked <sha>" for the first marked one, "none" when every read came back not marked;
# anything else (a compare or marker read failure, more than NEWER_CHECK_MAX commits, the NEWER_CHECK_SECONDS bound)
# prints nothing, and the run leaves as before.
newer_marked() {
  local marker="$here/../../cmux-next/tree-commit-marker.sh" shas sha rc deadline left
  [[ -f "$marker" ]] || return 0
  shas="$(gh_bounded api "repos/$REPOSITORY/compare/$TIP_SHA...$tip" \
    --jq 'select(.status == "ahead" and .ahead_by == (.commits | length)) | .commits[].sha' 2>/dev/null)" || return 0
  [[ -n "$shas" ]] || return 0
  (( $(wc -l <<<"$shas") <= ${NEWER_CHECK_MAX:-60} )) || return 0
  deadline=$(( $(date -u +%s) + ${NEWER_CHECK_SECONDS:-90} ))
  # Newest first: the tick promotes the newest buildable commit, and markers are written for a window from the tip.
  while IFS= read -r sha; do
    # Each read gets only the time left, so the reads together stay inside NEWER_CHECK_SECONDS.
    left=$(( deadline - $(date -u +%s) ))
    (( left > 0 )) || return 0
    (( left <= ${GH_CALL_SECONDS:-30} )) || left=${GH_CALL_SECONDS:-30}
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 0
    rc=0; bash "$here/../timeout.sh" "$left" bash "$marker" check "$sha" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) echo "marked $sha"; return 0 ;;
      1) ;;
      *) return 0 ;;
    esac
  done < <(awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' <<<"$shas")
  # A last read that ended past the bound is not a clean answer: leave as before.
  (( $(date -u +%s) <= deadline )) || return 0
  echo none
}
if [[ -n "${IN_SLOT:-}" ]]; then
  # Already promoted: the newer push's run builds it.
  current="$(poll_head)"
  moved "$current" && leave "$current"
  newer="$(newer_marked)"
  [[ -z "$newer" ]] || echo "newer buildable commits: $newer"
  # Main's tick, now: it counts this run as building nothing (LEAVE_ONE_STEP) and promotes the newest buildable commit.
  if gh_bounded workflow run nightly-next-tick.yml --repo "$REPOSITORY" --ref main; then
    echo "asked main's nightly-next tick to promote the newest buildable commit"
  else
    echo "::warning::could not ask main's nightly-next tick; wake-nightly-next-tick asks again when this job ends"
  fi
  if [[ "$newer" == none ]]; then
    echo "$stale, and feat-cmux-next is at $tip, but no commit after $TIP_SHA has a published tree: the tick has nothing newer to promote, so building $TIP_SHA now"
    echo "superseded=false" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  tries=0
  if [[ "${LOOP_RETRY:-}" =~ ^[0-9]+$ ]]; then tries="$LOOP_RETRY"; fi
  if (( tries < 2 )); then
    echo "superseded=true" >> "$GITHUB_OUTPUT"
    echo "pending=true" >> "$GITHUB_OUTPUT"
    echo "LEFT_SLOT=1" >> "$GITHUB_ENV"
    echo "::notice title=Left the slot::$stale, and feat-cmux-next is at $tip: the signing Mac is free now. Main's tick promotes the newest buildable commit; wake-nightly-next-tick retries $TIP_SHA (retry $(( tries + 1 )) of 2) unless nightly-next moves"
    exit 0
  fi
  echo "$stale, and feat-cmux-next is at $tip, but this is the loop's last retry: building $TIP_SHA now"
  echo "superseded=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
# One read, no wait (Leo: "no slot handoff waits"): a stale run used to poll here up to 6 min for the tick to promote
# a newer commit (run 45562645699 sat 6.2 min and built its own commit). Now it leaves only when nightly-next has
# already moved; otherwise it builds at once. The newer push's own run still builds the head and publishes after it.
echo "$stale, and feat-cmux-next is at $tip: one read of nightly-next, no wait"
current="$(poll_head)"
moved "$current" && leave "$current"
echo "nightly-next has not moved past $TIP_SHA; building it"
echo "superseded=false" >> "$GITHUB_OUTPUT"
