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
# With nothing promoted in YIELD_MINUTES the run builds its own commit, as before. A fresh push run never waits.
# IN_SLOT=1: nightly-next-one's first step, once its group (nightly-next-one-push) admits it. A run that waited
# YIELD_STALE_MINUTES or more at that slot (from resolve's end) is stale the same way, and one that leaves sets
# LEFT_SLOT=1 in the job's env: every later build and publish step skips, so it ends green with nothing cancelled.
# Env: TIP_SHA, REPOSITORY, GH_TOKEN; LOOP_RETRY (nightly_next_loop_retry); SUPERSEDE_SKIP (vars.NIGHTLY_NEXT_SUPERSEDE_SKIP,
# a push run leaves without waiting only with 1); YIELD_STALE_MINUTES (5), YIELD_MINUTES (6), YIELD_POLL_SECONDS (15).
set -euo pipefail
next_head() { gh api "repos/$REPOSITORY/git/ref/heads/nightly-next" --jq .object.sha 2>/dev/null || true; }
# The wait reads the ref with git ls-remote against the public repository: no API budget
# (tests/test_ci_no_github_token_polling.py). It reads through origin-net.sh's remote_refs, one try per poll
# (the loop is the retry): a remote that does not answer is named and reads as "not moved yet", never as a ref.
# shellcheck source=scripts/cmux-next/lib/origin-net.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/lib/origin-net.sh"
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
stale=""
if [[ -n "${IN_SLOT:-}" ]]; then
  # The wait at the slot: since this run's resolve job ended (nightly-next-one queued then). A retry's age was
  # already counted before the slot; here only the slot wait counts, so a run admitted at once builds at once.
  if ended="$(gh api "repos/$REPOSITORY/actions/runs/${GITHUB_RUN_ID:-0}/attempts/${GITHUB_RUN_ATTEMPT:-1}/jobs?per_page=100" \
      --jq '.jobs[] | select(.name == "resolve-nightly-cmux-tui-client") | .completed_at' 2>/dev/null)" \
    && waited="$(minutes_since "$ended")" && (( waited >= ${YIELD_STALE_MINUTES:-5} )); then
    stale="a run that waited $waited min at nightly-next-one's push slot"
  fi
elif [[ -n "${LOOP_RETRY:-}" ]]; then
  stale="a loop retry of $TIP_SHA"
elif created="$(gh api "repos/$REPOSITORY/actions/runs/${GITHUB_RUN_ID:-0}" --jq .created_at 2>/dev/null)" \
  && waited="$(minutes_since "$created")" \
  && (( waited >= ${YIELD_STALE_MINUTES:-5} )); then
  stale="a push run that waited $waited min for the build slot"
fi
tip="$(gh api "repos/$REPOSITORY/git/ref/heads/feat-cmux-next" --jq .object.sha 2>/dev/null || true)"
if [[ -z "$stale" || ! "$tip" =~ ^[0-9a-f]{40}$ || "$tip" == "$TIP_SHA" ]]; then
  echo "superseded=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "$stale, and feat-cmux-next is at $tip: waiting up to ${YIELD_MINUTES:-6} min for the tick to promote the newest buildable commit"
deadline=$(( $(date -u +%s) + ${YIELD_MINUTES:-6} * 60 ))
while (( $(date -u +%s) < deadline )); do
  current="$(poll_head)"
  moved "$current" && leave "$current"
  sleep "${YIELD_POLL_SECONDS:-15}"
done
echo "nothing newer was promoted in ${YIELD_MINUTES:-6} min; building $TIP_SHA"
echo "superseded=false" >> "$GITHUB_OUTPUT"
