#!/usr/bin/env python3
"""Which tier of CI a pull request head gets: `full` or `cheap` (cmuxterm-hq docs/ci/ci-cut-ledger.md, "draft tier").

    head_tier.py            reads $GITHUB_EVENT_NAME and $GITHUB_EVENT_PATH, writes tier=full|cheap|none and
                            reason=... to $GITHUB_OUTPUT (or prints them), one line to the step summary
    head_tier.py tier       the same decision, only the word (full, cheap or none) on stdout, for a shell `if`
    head_tier.py explain EVENT_JSON [EVENT_NAME]
                            the same decision for a saved event payload, printed

A draft pull request cannot merge, so the expensive half of CI on a draft head buys only an early look: over
11-13..19 heads that a later head replaced were about half of PR runner-minutes, and most heads of a PR come
before it is ready. A draft head runs the cheap tier (each workflow says which of its jobs that is; most
run nothing); the full tier runs when the PR is marked ready for review (every workflow that skips drafts
listens to `ready_for_review`), on any non-draft head, with the `full-ci` label, and for every event that is
not a pull request. Nothing a draft skips can land unchecked: marking it ready runs the full tier on the same
head before any merge. How a draft gets the full tier: mark it ready for review (every gated workflow listens to
`ready_for_review`), or add `full-ci`; the router and ci.yml re-run on that `labeled` event, but cmux-next.yml does
not listen to `labeled` (it would start on every label of every PR), so there the label takes effect at the next
push: push a commit (an empty one does) after adding it.

Heavy-at-land rule (on unless the repository variable CI_HEAVY_AT_LAND is 0; Leo, 2026-11-26: "de facto, im asking
for 99% fewer minutes of ci time, period."): a pull request from this repository runs the full tier only on the
`labeled` event that adds `ready-to-land` or `full-ci`; every other head that would be full (later pushes while
`full-ci` stays on, stacked pull requests on other bases, ask-rule heads) gets the cheap tier. Off, nothing changes.

Post-merge tier rule (off unless the repository variable CI_POST_MERGE_TIER_PR is 1; cmuxterm-hq
docs/rfd/0200-ci-four-tiers.md, tier 3; Leo, 2026-11-28: "de facto, im asking for 99% fewer minutes of ci time,
period."): a feat-cmux-next pull request head gets the tier `none` in a workflow that RFD 0013's merge tiers put after
the merge (`merge_tier.post_merge` in .github/post-merge-checks.json, with `merge_tier.switch` on) and that a suite of
.github/post-merge-batch.json runs. The check still starts and reports on the PR; its heavy jobs run once per
post-merge batch instead of on each landing head, and a red there is bisected to the PR. `full-ci` still runs it on
the PR. Unreadable config, a called workflow (its $GITHUB_WORKFLOW_REF is the caller's) or a fork's head: unchanged.

Idle rule (cmuxterm-hq docs/ci/idle-pr-heads-2026-11-21.md, hq#16419): a head that only merges the base into a
pull request whose own last commit is more than 24 hours old gets the tier `none`: the router starts nothing, and
ci.yml and cmux-next.yml run it like a draft. Base merges were 37% of PR runner-minutes over 11-13..19, most on
PRs nobody was working on. A PR that is landing runs its full tier at the land's own merge run, a fresh commit
brings the full tier back, and so does the `full-ci` label.

Land rule (cmuxterm-hq goals/ci-runner-min-per-day-50k.md, cut 1): a ready head into feat-cmux-next from this
repository, without the `ready-to-land` label (next-autoland's handoff label; land-judge adds it when asked to land),
gets the cheap tier too. Only the head that lands needs the full tier's verdict: on 11-23..24, 79% of the heads of
merged PRs ran the full tier, about 3.4 full-tier heads per merge against the one that landed. Such a head carries
the commit status `cmux/land-tier` pending (pr-router.yml posts it; `success` once a head runs the full tier), so
land-judge waits for the full tier instead of landing on the cheap one. Adding `ready-to-land` (or `full-ci`) re-runs
ci.yml, cmux-next.yml and the router on the full tier at the same head. Leo, 2026-11-21: "whatever we need to cut,
we cut."

Hourly full tier rule (cmuxterm-hq goals/ci-runner-min-per-day-50k.md, cut 2): with the land rule on, a landing
head (`ready-to-land`, not a draft) gets the cheap tier as well, the tier its changed paths call for, and
`cmux/land-tier` is `success` at once, so land-judge lands when that tier's checks are green. The full tier runs once an hour
on feat-cmux-next's own head instead (cmux-next-hourly-full-tier.yml, .github/hourly-full-tier.json), only when the
head moved; a red names the PRs merged since the last green hourly run (first-parent log), and the base-breaker's
owner reverts or fixes forward. On 11-25..26, about 100k runner-minutes a day were full-tier runs on
`ready-to-land` heads whose branch never merged. Leo, 2026-11-26: "de facto, im asking for 99% fewer minutes of ci
time, period." `full-ci` still gives a head the full tier. The repository variable CI_LAND_FULL_PER_PR=1 restores
the full tier on every landing head (and turns the hourly run off).

Sync rule: a head that only merges the base into a pull request, and that an agent's own `git merge` made (the
merge commit's committer is not GitHub), runs the cheap tier. On 2026-11-24, 115 of 600 cmux-next heads were such merges, each
a whole suite, and 80% of those runs were cancelled by the next head (34% of all cancelled workflow minutes). The
merge rides up with the branch's next own commit, which runs the full tier; a merge GitHub made (update-branch,
which land asks for) keeps the full tier, since land waits for its checks.

Green-head base merge rule (goal ci-min-per-pr-14): into feat-cmux-next, a head that only merges the base onto a
previous head whose every Actions run passed gets the tier `none` too, however recent the PR's own commits. The
previous head already proved the PR's own change; nothing the base merge could break is the PR's to fix until it
lands, and the land runs the full tier on the exact head it merges anyway (`ready-to-land` above; such a head's
`cmux/land-tier` stays pending), so a mid-flight base merge or update-branch only re-ran what that later run must
repeat. It is checked before the sync rule: such a head runs nothing instead of the cheap tier. Base merges were
58% of cmux PR runner-minutes on 11-24 14Z..17Z, about half of them onto a green head. The previous head's verdict
comes from the Actions runs API (`actions: read`, $GH_TOKEN): the newest run of each workflow at that commit must
have ended success, skipped or neutral; any other conclusion, a run still going, none at all or an unread answer keeps the
head's usual tier. A head that merges something else, carries its own commit, or targets another base is unchanged.

One-shot full-ci rule (goal ci-runner-min-per-day-500k): into feat-cmux-next, the `full-ci` label gives the full tier
only on its own `labeled` event, at the head it was added on, not on every later head. Nothing took the label off, so
each push and base merge after it re-ran the full suite: over 11-25 09Z..11-26 09Z the 265 open feat-cmux-next PRs
carrying it spent about 246k GitHub runner-min (27% of PR minutes, about 69 runs per PR). A later head of such a PR
gets the tier it would get without the label (the land rule's cheap tier until `ready-to-land`), and the land runs
the full tier at the head it merges, as before. Another base keeps the sticky label. Leo, 2026-11-25: "de facto, im
asking for 99% fewer minutes of ci time, period."

Land carry rule (goal ci-runner-min-per-day-50k): a `ready-to-land` head into feat-cmux-next that only merges the base
(GitHub's update-branch, which land asks for, or an agent's own merge of feat-cmux-next) onto a previous head whose
full tier passed runs the cheap tier, and pr-router.yml carries `cmux/land-tier` success to it. "Passed" means the
previous head carries `cmux/land-tier` success (it ran the full tier) and its every Actions run ended green
(green_previous). About 48% of PR commits were base merges on 11-24, about half of them update-branch, and a landing
head's update-branch re-ran the whole full tier only to re-prove the change its previous head had proved. An unread
status or runs answer, a run still going, a red one, a commit of its own or `full-ci` keeps the full tier. Leo:
"de facto, im asking for 99% fewer minutes of ci time, period."

Same-patch rule (goal ci-min-per-pr-30): into feat-cmux-next, a head whose own change (the diff from its merge base with
feat-cmux-next, compared without line numbers) is the same as the previous head's, and whose previous head's every
Actions run passed, gets the tier `none` as well: a rebase, a force-push of the same commits onto a newer base, or a
base merge with resolved conflicts. Over the last 50 merged cmux PRs, 144 heads (42% of their job-minutes) carried
the same own patch as an earlier head of their PR, most of them a rebase rather than a plain base merge, which the
green-head rule does not see. It shares that rule's switch, its labels and its `cmux/land-tier` pending. The two
diffs come from the compare API (`contents: read`); a compare of 300 files or more, a file without a patch, or an
unread answer keeps the head's usual tier.

Labelled base merge rule (goal ci-runner-min-per-day-500k, cut a): the green-head base merge rule and the same-patch
rule apply to a `ready-to-land` head too. On 11-25 13Z..11-26 13Z, 83% of cmux PR heads were base merges (about
792k of 932k PR-head runner-min/day), and base merges onto a green previous head of a labelled PR, which those rules
left alone, cost about 185k runner-min/day: most were heads a later push or update-branch replaced before land. Such
a head runs nothing and its `cmux/land-tier` stays pending with the cheap tier's description, so land-judge pulses
`ready-to-land` (tools/land_judge/rules/land_tier.py: off, then on) and the land tier runs on the exact head it merges,
on that `labeled` event (the green rule only reads a synchronize). `full-ci` still gives a head the full tier.
CI_LABELLED_BASE_MERGE_SKIP=0 turns this off (a labelled base merge runs its usual tier again).

Red-head base merge rule (goal ci-runner-min-per-day-500k, cut b): into feat-cmux-next, a head that only merges the
base onto a previous head where some Actions run did not pass reruns only what was not green there. Per workflow:
a workflow whose newest run at the previous head ended `success` gets the tier `none` for this head (head_tier reads
its own workflow from $GITHUB_WORKFLOW_REF); one that was red, cancelled, skipped, still going or missing runs its
usual tier. Inside the router (pr-router.yml), when its own previous run was not green, the callees and pr pipeline
table jobs whose jobs all passed there, and took a minute or more, stay off (pr_router.rerun_plan); a red, cancelled
or short one starts. On 11-25 13Z..11-26 13Z base merges onto a red head were about 362k runner-min/day, most of it
jobs that had passed at the previous head. Anything unread (the runs or jobs answer, the workflow's own name) runs
everything: the rule fails open. `full-ci` runs everything; the land tier runs at the land as above.
CI_RED_BASE_MERGE_RERUN=0 turns this off.

Same-head land carry rule (goal ci-min-per-pr-30; Leo, 2026-11-26: "de facto, im asking for 99% fewer minutes of ci
time, period."): `ready-to-land` added again to a head whose land tier already ran and passed there gets the tier
`none`. Land's bots take the label off a head they cannot merge yet and land adds it back on the same head every
20-40 min (cmux#54931 at 5034377d: added 11:54, 12:25, 13:02, 13:52, 14:37Z on 11-27), and every re-add ran the land
tier again on a commit that had passed it: on 11-26 21Z..11-27 21Z, 443 such re-adds onto an all-green head were
about 12.4k GitHub runner-min (6.5k of it the nightly pr build's compile) and the fleet compile behind it. The proof
is read at the head, from before this event (the payload's pull_request.updated_at): `cmux/land-tier` success and
every other commit status success, and every check run's newest run that was not skipped completed `success` or
`neutral` (a red, cancelled, timed-out, still-running or queued one runs the tier as before). `full-ci` added or on
the PR keeps its own rule (land-judge reads pr pipeline jobs that ran for it). Anything unread runs the tier: the rule
fails open. CI_SAME_HEAD_LAND_CARRY=0 turns this off.

Full-ci base merge carry rule (goal ci-runner-min-per-day-500k): a `full-ci` pulse or an added `ready-to-land` (the
`labeled` event) into feat-cmux-next, on a head that only merges the base onto a previous head whose land tier ran
(`cmux/land-tier` success) carries that run's results. Every run there green: this workflow runs nothing (tier `none`,
and pr-router.yml posts `cmux/land-tier` success). Some run red: a workflow whose newest run there ended `success`
runs nothing, and the rest run as usual, the router starting only its callees and pr pipeline table jobs that were not
green there (pr_router.rerun_plan) with `cmux/land-tier` success. The full set runs anyway when (1) the base merge
touched a file of the PR's own change, (2) the merge had conflicts or edits beyond the merge itself, or (3) the
previous head has no land tier run: the PR's own change (the compare API, from its base, at each head) must be the same
files with the same blobs and the same added and removed lines before and after the merge. On 11-26 15Z..21Z, full-ci
heads that only merged the base were about 46k runner-min/day in cmux-tui-spec, cmux-next-guards and rust-workspaces
alone. Anything unread runs everything. Leo, 2026-11-26: "de facto, im asking for 99% fewer minutes of ci time,
period." CI_FULL_CI_BASE_MERGE_CARRY=0 turns this off.

Ask rule (goal ask-to-nightly-under-2h): a ready pull request whose body names one of Leo's asks (`ask-` and ten hex
digits, the id leo-asks gives it) is handed off to land from its first head, as if `ready-to-land` were on it: it runs
the landing tier and `cmux/land-tier` is `success` at once. Agents waited for green before asking to land, so an ask's
real CI started only at the label: on 11-25..26, cmux#57020 waited 137 min, #57341 121, #57515 55 and #57798 41 with no
landing-tier CI before `ready-to-land`. Only the head GitHub sends with `opened`, `reopened` or `ready_for_review`
gets it: a later push (`synchronize`) falls back to the usual rule (cheap until `ready-to-land`), so an ask PR pays one
landing tier at open, the same minutes as asking to land at open (lane-9's CI-minutes goal: a push after open must not
pay the tier again). About 12 ask PRs a day. A draft stays cheap. CI_ASK_LANDING=0 turns it off.

Switches: the repository variable CI_FULL_CI_ONE_SHOT=0 makes `full-ci` sticky again (every head of a labelled PR
full); the repository variable CI_LAND_TIER=0 turns the land rule off (every ready head is full again); the
repository variable CI_DRAFT_CHEAP_TIER=0 (passed in as $CI_DRAFT_CHEAP_TIER) gives every draft head
the full tier again; CI_IDLE_BASE_MERGE_SKIP=0 turns the idle rule off; CI_SYNC_MERGE_CHEAP=0 turns the sync rule
off; CI_GREEN_BASE_MERGE_SKIP=0 turns the green-head base merge rule and the same-patch rule off; CI_LAND_CARRY=0 turns the land carry rule
off (a landing base merge runs the full tier again); CI_LABELLED_BASE_MERGE_SKIP=0 turns the labelled base merge rule
off; CI_RED_BASE_MERGE_RERUN=0 turns the red-head base merge rule off; CI_CONTENT_BASE_MERGE=0 counts a merge as a
base merge by its message only again (same_change_as); CI_FULL_CI_BASE_MERGE_CARRY=0 turns the full-ci base
merge carry rule off; CI_LAND_FULL_PER_PR=1 turns the hourly full tier rule off (a
landing head runs the full tier again). Stdlib only; anything unreadable gives
`full`.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.parse
import urllib.request
import sys
import time

FULL_CI = "full-ci"
# The start of the red-head base merge rule's reason (head_tier docstring, cut b).
RERUN_REASON = "rerun red only"
LAND_LABEL = "ready-to-land"  # next_autoland.LABEL: the PR is handed off to land
LAND_BASE = "feat-cmux-next"
# A Leo ask's id (leo-asks): a pull request body naming one is handed off to land from its first head (the ask rule).
ASK_ID = re.compile(r"\bask-[0-9a-f]{10}\b")
# The pull_request actions whose head the ask rule hands off: the head at open or at ready, never a later push.
ASK_ACTIONS = frozenset({"opened", "reopened", "ready_for_review"})
LAND_STATUS = "cmux/land-tier"  # the commit status the land rule's heads carry (pr-router.yml posts it)
ONE_SHOT_VAR = "CI_FULL_CI_ONE_SHOT"  # 0: full-ci is sticky again (the one-shot full-ci rule above)
# The start of the land carry rule's reason: pr_router.land_status posts success for a head whose reason starts so.
CARRY_REASON = "land tier carried"
# The full-ci base merge carry rule's reasons: FULL_CARRY_REASON for a workflow that runs nothing (pr_router.land_status
# posts success), FULL_RERUN_REASON for a router that reruns only what was not green (pr_router.main keeps success).
FULL_CARRY_REASON = "full run carried"
FULL_RERUN_REASON = "full run rerun red only"
SAME_HEAD_REASON = "same head land carried"  # the same-head land carry rule's reason prefix
SAME_HEAD_VAR = "CI_SAME_HEAD_LAND_CARRY"  # 0: the same-head land carry rule is off
CHECK_PAGES = 5  # check-run pages (100 each) the same-head rule reads at most; more is not judged
FULL_CARRY_LABELS = frozenset({"full-ci", "ready-to-land"})
IDLE_HOURS = 24
LAND_AFFECTED_REASON = "landing on the affected tier"  # the hourly full tier rule's reason prefix
# Conclusions of a previous head's runs that count as green for the green-head base merge rule.
GREEN = frozenset({"success", "skipped", "neutral"})
API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
# Seconds the previous head's verdict may take before the head keeps its usual tier.
VERDICT_SECONDS = 20.0


def base_merge_message(base: str) -> re.Pattern:
    """The first line of a commit that merges BASE: git's and GitHub's update-branch wording
    (`Merge branch 'B'`, `Merge remote-tracking branch 'origin/B'`) and the short forms agents write
    (`Merge B`, `Merge origin/B into lane/x`)."""
    b = re.escape(base)
    return re.compile(rf"^Merge ((remote-tracking )?branch '(origin/)?{b}'|(origin/)?{b}( into \S+)?\s*$)")


def idle(facts: dict | None, now: float, hours: float = IDLE_HOURS) -> bool:
    """Whether a head only merged the base into a pull request whose own last commit is older than HOURS.
    FACTS: {"base_merge_only": bool, "own_last": epoch seconds or None} (head_facts); None is not idle."""
    if not facts or not facts.get("base_merge_only"):
        return False
    own_last = facts.get("own_last")
    return isinstance(own_last, (int, float)) and now - own_last > hours * 3600


def labels_of(event: dict) -> set[str]:
    """The pull request's labels for EVENT: its payload's, plus the label a `labeled` event adds. The payload is built
    when GitHub delivers the event, so a label taken off right after it was added is already gone from it:
    land-judge's full-ci pulse on a lane VM (add full-ci, then remove it a second later; cmux#52441, router run
    45831524947) reached the router with no full-ci in its labels, ran the affected tier and skipped pr-pipeline.yml."""
    pr = event.get("pull_request") or {}
    labels = {str(label.get("name") or "") for label in pr.get("labels") or []}
    if event.get("action") == "labeled":
        added = str((event.get("label") or {}).get("name") or "")
        if added:
            labels.add(added)
    return labels


def full_ci_applies(event: dict, one_shot: str | None = None) -> bool:
    """Whether EVENT's head gets the full tier from the `full-ci` label: the label is on the pull request and either
    this is its own `labeled` event, the base is not feat-cmux-next, or ONE_SHOT (default $CI_FULL_CI_ONE_SHOT, on)
    is 0. The workflows' `if:` gates read the same three conditions (tests/test_feat_ci_guard_group.py FULL_CI_ON)."""
    pr = event.get("pull_request") or {}
    if FULL_CI not in labels_of(event):
        return False
    switch = os.environ.get(ONE_SHOT_VAR, "1") if one_shot is None else one_shot
    return ((switch or "1").strip() == "0" or str((pr.get("base") or {}).get("ref") or "") != LAND_BASE
            or (event.get("action") == "labeled" and str((event.get("label") or {}).get("name") or "") == FULL_CI))


def land_rule_applies(event: dict) -> bool:
    """Whether the land rule can hold EVENT's head: a ready pull request into feat-cmux-next from this repository.
    A fork's head keeps the full tier (it cannot be handed off the same way)."""
    pr = event.get("pull_request") or {}
    if pr.get("draft") is not False:
        return False
    base = pr.get("base") or {}
    head = pr.get("head") or {}
    base_repo = str((base.get("repo") or {}).get("full_name") or "")
    head_repo = str((head.get("repo") or {}).get("full_name") or "")
    return base.get("ref") == LAND_BASE and bool(base_repo) and base_repo == head_repo


def sync_merge(facts: dict | None) -> bool:
    """Whether a head only merges the base and the merge commit is an agent's own (not GitHub's update-branch).
    FACTS: head_facts. An unread committer (None) is not a sync merge."""
    return bool(facts and facts.get("base_merge_only") and facts.get("by_github") is False)


def green_previous(runs: list | None) -> bool:
    """Whether a commit's Actions runs (the runs API's `workflow_runs`) are all green: the newest run of each
    workflow ended in GREEN. No runs, or any run not completed, is not green."""
    newest: dict = {}
    for run in runs or []:
        if not isinstance(run, dict):
            return False
        key = str(run.get("path") or run.get("workflow_id") or run.get("name") or "")
        if key not in newest or int(run.get("id") or 0) > int(newest[key].get("id") or 0):
            newest[key] = run
    return bool(newest) and all(run.get("status") == "completed" and run.get("conclusion") in GREEN
                                for run in newest.values())


def runs_at(repo: str, sha: str, token: str) -> list | None:
    """The Actions runs at commit SHA (up to 100, newest first), or None when they cannot be read."""
    if not (re.fullmatch(r"[\w.-]+/[\w.-]+", repo) and re.fullmatch(r"[0-9a-f]{40}", sha) and token):
        return None
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import deadline_http  # the router's sparse checkout carries it beside this file
        query = urllib.parse.urlencode({"head_sha": sha, "per_page": 100, "exclude_pull_requests": "true"})
        req = urllib.request.Request(f"{API}/repos/{repo}/actions/runs?{query}", headers={
            "Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28"})
        status, body, _ = deadline_http.request(req, VERDICT_SECONDS)
        data = json.loads(body) if status == 200 else None
    except Exception:  # fail open: an unread verdict keeps the usual tier
        return None
    if not isinstance(data, dict) or not isinstance(data.get("workflow_runs"), list):
        return None
    if int(data.get("total_count") or 0) > len(data["workflow_runs"]):
        return None  # more runs than one page: not judged
    return data["workflow_runs"]


def own_patch_key(repo: str, base: str, sha: str, token: str, blobs: bool = False) -> str | None:
    """A key for the change commit SHA makes over its merge base with BASE: each changed file's name, status and
    added and removed lines, without the hunk line numbers a newer base shifts (what `git patch-id` ignores too).
    None when the compare cannot be read whole."""
    if not (re.fullmatch(r"[\w.-]+/[\w.-]+", repo) and re.fullmatch(r"[0-9a-f]{40}", sha) and token
            and re.fullmatch(r"[\w./-]+", base)):
        return None
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import deadline_http  # the router's sparse checkout carries it beside this file
        req = urllib.request.Request(
            f"{API}/repos/{repo}/compare/{urllib.parse.quote(base, safe='')}...{sha}?per_page=300", headers={
                "Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
                "X-GitHub-Api-Version": "2022-11-28"})
        status, body, _ = deadline_http.request(req, VERDICT_SECONDS)
        data = json.loads(body) if status == 200 else None
    except Exception:  # fail open: an unread diff keeps the usual tier
        return None
    return patch_key(data, blobs)


def patch_key(compare: dict | None, blobs: bool = False) -> str | None:
    """own_patch_key's key for one compare answer, or None when it is not whole: no files, 300 or more (the
    API's cap), or a changed file with no patch (binary or too large). BLOBS: each file's blob too (the full-ci base
    merge carry rule: a base change merged into the same file keeps the patch lines but not the blob)."""
    files = compare.get("files") if isinstance(compare, dict) else None
    if not isinstance(files, list) or not files or len(files) >= 300:
        return None
    parts = []
    for item in files:
        if not isinstance(item, dict) or not isinstance(item.get("patch"), str):
            return None
        lines = [line for line in item["patch"].splitlines() if line[:1] in ("+", "-")]
        parts.append("\0".join([str(item.get("filename") or ""), str(item.get("previous_filename") or ""),
                                 str(item.get("status") or ""), *([str(item.get("sha") or "")] if blobs else []),
                                 *lines]))
    import hashlib
    return hashlib.sha256("\1".join(sorted(parts)).encode()).hexdigest()


def land_status_at(repo: str, sha: str, token: str) -> str | None:
    """The state of the `cmux/land-tier` commit status at SHA (success, pending, ...), "" when it has none, or None
    when it cannot be read."""
    if not (re.fullmatch(r"[\w.-]+/[\w.-]+", repo) and re.fullmatch(r"[0-9a-f]{40}", sha) and token):
        return None
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import deadline_http  # the router's sparse checkout carries it beside this file
        req = urllib.request.Request(f"{API}/repos/{repo}/commits/{sha}/status?per_page=100", headers={
            "Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28"})
        status, body, _ = deadline_http.request(req, VERDICT_SECONDS)
        data = json.loads(body) if status == 200 else None
    except Exception:  # fail open: an unread status keeps the full tier
        return None
    if not isinstance(data, dict) or not isinstance(data.get("statuses"), list):
        return None
    states = [str(item.get("state") or "") for item in data["statuses"]
              if isinstance(item, dict) and item.get("context") == LAND_STATUS]
    return states[0] if states else ""  # the combined status lists each context's newest status once


def labels_of(event: dict) -> set[str]:
    """The PR's labels for EVENT: the payload's list, plus the label a `labeled` event added. GitHub fills the payload's
    list when it sends the event, not when the label went on, so a label taken off right after (land-judge's full-ci
    pulse on a lane VM, label_lane_pulse: added and taken off 2 s later) is missing from it. cmux#53671 at c52da39d,
    2026-11-26 14:13Z: the pulse's `labeled` run read no full-ci, routed the land-affected cheap tier, skipped pr
    pipeline, and land-judge refused matrix_missing again; every lane VM land of an iOS link PR stopped there."""
    pr = event.get("pull_request") or {}
    labels = {str(label.get("name") or "") for label in pr.get("labels") or []}
    if event.get("action") == "labeled":
        added = str((event.get("label") or {}).get("name") or "")
        if added:
            labels.add(added)
    return labels


def for_ask(event: dict, switch: str | None = None) -> bool:
    """Whether EVENT is the head at open or ready (ASK_ACTIONS) of a pull request whose body names a Leo ask (ASK_ID),
    with the ask rule on (CI_ASK_LANDING, default 1). A later push (synchronize) is never handed off by the ask rule."""
    on = os.environ.get("CI_ASK_LANDING", "1") if switch is None else switch
    if (on or "1").strip() == "0" or event.get("action") not in ASK_ACTIONS:
        return False
    body = (event.get("pull_request") or {}).get("body")
    return isinstance(body, str) and bool(ASK_ID.search(body))


def carry_rule_applies(event: dict, carry_switch: str = "1", land_switch: str = "0",
                       one_shot: str | None = None) -> bool:
    """Whether the land carry rule can apply to EVENT (before reading any fact): a synchronize of a `ready-to-land`
    head into feat-cmux-next (land_rule_applies), without a `full-ci` that applies (full_ci_applies), with both switches on."""
    labels = labels_of(event)
    return ((carry_switch or "1").strip() != "0" and (land_switch or "0").strip() not in ("0", "")
            and event.get("action") == "synchronize" and land_rule_applies(event)
            and LAND_LABEL in labels and not full_ci_applies(event, one_shot))


def carried(decided: tuple[str, str]) -> bool:
    """Whether a decide() answer is the land carry rule's (its head carries `cmux/land-tier` success)."""
    return decided[0] == "cheap" and decided[1].startswith(CARRY_REASON)


def green_rule_applies(event: dict, green_switch: str = "1", land_switch: str = "0",
                       labelled_switch: str = "1", one_shot: str | None = None) -> bool:
    """Whether the green-head base merge rule can apply to EVENT (before reading any fact): a synchronize into
    feat-cmux-next (land_rule_applies) with both switches on, without a `full-ci` that applies (full_ci_applies),
    and (with LABELLED_SWITCH off, the labelled base merge rule) without `ready-to-land`."""
    labels = labels_of(event)
    held = set() if (labelled_switch or "1").strip() != "0" else {LAND_LABEL}
    return ((green_switch or "1").strip() != "0" and (land_switch or "0").strip() not in ("0", "")
            and event.get("action") == "synchronize" and land_rule_applies(event)
            and not labels & held and not full_ci_applies(event, one_shot))


def rerun_rule_applies(event: dict, rerun_switch: str = "1", land_switch: str = "0",
                       one_shot: str | None = None) -> bool:
    """Whether the red-head base merge rule can apply to EVENT (before reading any fact): a synchronize into
    feat-cmux-next (land_rule_applies) with both switches on and without a `full-ci` that applies (full_ci_applies)."""
    return ((rerun_switch or "1").strip() != "0" and (land_switch or "0").strip() not in ("0", "")
            and event.get("action") == "synchronize" and land_rule_applies(event)
            and not full_ci_applies(event, one_shot))


def full_carry_rule_applies(event: dict, switch: str = "1") -> bool:
    """Whether the full-ci base merge carry rule can apply to EVENT (before reading any fact): `full-ci` or
    `ready-to-land` added (a `labeled` event) to a ready head into feat-cmux-next (land_rule_applies), switch on."""
    added = str((event.get("label") or {}).get("name") or "")
    return ((switch or "1").strip() != "0" and event.get("action") == "labeled" and added in FULL_CARRY_LABELS
            and land_rule_applies(event))


def full_carried(decided: tuple[str, str]) -> bool:
    """Whether DECIDED is the full-ci base merge carry rule's `none` (its head carries `cmux/land-tier` success)."""
    return decided[0] == "none" and str(decided[1]).startswith(FULL_CARRY_REASON)


def same_head_rule_applies(event: dict, switch: str = "1") -> bool:
    """Whether the same-head land carry rule can apply to EVENT (before reading any fact): `ready-to-land` added (a
    `labeled` event) to a ready head into feat-cmux-next from this repository (land_rule_applies), no `full-ci` on the
    PR, switch on."""
    added = str((event.get("label") or {}).get("name") or "")
    return ((switch or "1").strip() != "0" and event.get("action") == "labeled" and added == LAND_LABEL
            and FULL_CI not in labels_of(event) and land_rule_applies(event))


def same_head_carried(decided: tuple[str, str]) -> bool:
    """Whether DECIDED is the same-head land carry rule's `none` (its head carries `cmux/land-tier` success)."""
    return decided[0] == "none" and str(decided[1]).startswith(SAME_HEAD_REASON)


def _epoch(stamp: object) -> float | None:
    try:
        return time.mktime(time.strptime(str(stamp), "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
    except (TypeError, ValueError, OverflowError):
        return None


def head_green_before(checks: list | None, statuses: list | None, cutoff: float | None) -> bool:
    """Whether a head passed everything that ran on it before CUTOFF (epoch seconds): STATUSES (the combined status's
    `statuses`, each context's newest) hold `cmux/land-tier` success and nothing but success, and of CHECKS (check
    runs) started before CUTOFF, each name's newest run that was not skipped completed `success` or `neutral`. A check
    run with no start time, any unread input, or no check run at all is not green."""
    if cutoff is None or not isinstance(checks, list) or not isinstance(statuses, list):
        return False
    states: dict[str, str] = {}
    for item in statuses:
        if not isinstance(item, dict):
            return False
        states.setdefault(str(item.get("context") or ""), str(item.get("state") or ""))
    if states.get(LAND_STATUS) != "success" or any(state != "success" for state in states.values()):
        return False
    newest: dict[str, tuple[float, int, dict]] = {}
    for run in checks:
        if not isinstance(run, dict):
            return False
        started = _epoch(run.get("started_at"))
        if started is None:
            return False
        if started >= cutoff or run.get("conclusion") == "skipped":
            continue
        name = str(run.get("name") or "")
        key = (started, int(run.get("id") or 0))
        if name not in newest or key > newest[name][:2]:
            newest[name] = (started, int(run.get("id") or 0), run)
    return bool(newest) and all(run.get("status") == "completed" and run.get("conclusion") in ("success", "neutral")
                                for _, _, run in newest.values())


def _get_json(url: str, token: str) -> object | None:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import deadline_http  # the router's sparse checkout carries it beside this file
        req = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28"})
        status, body, _ = deadline_http.request(req, VERDICT_SECONDS)
        return json.loads(body) if status == 200 else None
    except Exception:  # fail open: unread is not green
        return None


def checks_at(repo: str, sha: str, token: str) -> list | None:
    """Every check run at commit SHA (up to CHECK_PAGES pages), or None when they cannot all be read."""
    if not (re.fullmatch(r"[\w.-]+/[\w.-]+", repo) and re.fullmatch(r"[0-9a-f]{40}", sha) and token):
        return None
    runs: list = []
    for page in range(1, CHECK_PAGES + 1):
        query = urllib.parse.urlencode({"filter": "all", "per_page": 100, "page": page})
        data = _get_json(f"{API}/repos/{repo}/commits/{sha}/check-runs?{query}", token)
        if not isinstance(data, dict) or not isinstance(data.get("check_runs"), list):
            return None
        runs.extend(data["check_runs"])
        if len(runs) >= int(data.get("total_count") or 0) or not data["check_runs"]:
            return runs if len(runs) >= int(data.get("total_count") or 0) else None
    return None


def statuses_at(repo: str, sha: str, token: str) -> list | None:
    """The combined status's `statuses` at SHA (each context's newest), or None when unread or more than one page."""
    if not (re.fullmatch(r"[\w.-]+/[\w.-]+", repo) and re.fullmatch(r"[0-9a-f]{40}", sha) and token):
        return None
    data = _get_json(f"{API}/repos/{repo}/commits/{sha}/status?per_page=100", token)
    if not isinstance(data, dict) or not isinstance(data.get("statuses"), list):
        return None
    if int(data.get("total_count") or 0) > len(data["statuses"]):
        return None
    return data["statuses"]


def same_head_facts(event: dict) -> dict:
    """{"same_head_landed"}: whether the event's head passed its land tier and everything else before this event
    (head_green_before at the payload's pull_request.updated_at, when the label went on)."""
    pr = event.get("pull_request") or {}
    sha = str((pr.get("head") or {}).get("sha") or "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    cutoff = _epoch(pr.get("updated_at"))
    statuses = statuses_at(repo, sha, token) if cutoff is not None else None
    checks = checks_at(repo, sha, token) if statuses is not None else None
    return {"same_head_landed": head_green_before(checks, statuses, cutoff)}


def full_rerun(decided: tuple[str, str]) -> bool:
    """Whether DECIDED is that rule's `full` that reruns only what was not green (the router keeps the land success)."""
    return decided[0] == "full" and str(decided[1]).startswith(FULL_RERUN_REASON)


def full_carry(facts: dict | None) -> tuple[str, str] | None:
    """The full-ci base merge carry rule's answer for FACTS (head_facts plus full_carry_facts), or None when the full
    set runs: not a base merge, no land tier run at the previous head, the PR's own change moved, anything unread."""
    if not (facts and facts.get("base_merge_only") and facts.get("full_landed") is True
            and facts.get("own_change_kept") is True and isinstance(facts.get("previous_runs"), list)):
        return None
    previous = str(facts.get("previous") or "")[:10]
    if facts.get("previous_green") is True:
        return "none", (f"{FULL_CARRY_REASON}: this head only merges the base onto {previous}, whose land tier ran "
                        f"all green, and the merge touched none of the PR's own files: nothing runs again; "
                        f"{LAND_STATUS} carries success")
    if facts.get("previous_green") is False and facts.get("workflow_passed") is True:
        return "none", (f"{FULL_CARRY_REASON}: this head only merges the base onto {previous}, where "
                        f"{facts.get('workflow')} passed in the land tier run: only what was not green there runs")
    if facts.get("previous_green") is False:
        return "full", (f"{FULL_RERUN_REASON}: this head only merges the base onto {previous}, whose land tier run had "
                        f"reds: what was not green there runs again")
    return None


def workflow_file(ref: str | None) -> str:
    """The workflow file a run is of, from $GITHUB_WORKFLOW_REF (`owner/repo/.github/workflows/F@ref`), or ""."""
    m = re.search(r"\.github/workflows/([^/@]+)@", str(ref or ""))
    return m.group(1) if m else ""


def newest_runs(runs: list | None) -> dict:
    """{workflow path: the newest run of it} for a commit's Actions runs; {} when a run is not a dict."""
    newest: dict = {}
    for run in runs or []:
        if not isinstance(run, dict):
            return {}
        key = str(run.get("path") or run.get("workflow_id") or run.get("name") or "")
        if key not in newest or int(run.get("id") or 0) > int(newest[key].get("id") or 0):
            newest[key] = run
    return newest


def passed_there(runs: list | None, workflow: str) -> bool:
    """Whether WORKFLOW (a file name) ran at a commit and its newest run there ended `success`. Skipped, neutral,
    any other conclusion, a run still going, no run, or no workflow name is not passed."""
    if not workflow:
        return False
    for path, run in newest_runs(runs).items():
        if path.split("@")[0].rsplit("/", 1)[-1] == workflow:
            return run.get("status") == "completed" and run.get("conclusion") == "success"
    return False


def rerun(decided: tuple[str, str]) -> bool:
    """Whether a decide() answer is the red-head base merge rule's (this workflow passed at the previous head)."""
    return decided[0] == "none" and str(decided[1]).startswith(RERUN_REASON)


def land_affected(decided: tuple[str, str]) -> bool:
    """Whether DECIDED is the hourly full tier rule's cheap tier for a landing head: its green verdict is the land's
    (pr_router.land_status posts cmux/land-tier success on it)."""
    return decided[0] == "cheap" and str(decided[1]).startswith(LAND_AFFECTED_REASON)


HEAVY_AT_LAND_REASON = "heavy at land (CI_HEAVY_AT_LAND=1)"


def same_repo(event: dict) -> bool:
    """Whether EVENT's pull request comes from this repository (a fork's head keeps its tier)."""
    pr = event.get("pull_request") or {}
    base_repo = str(((pr.get("base") or {}).get("repo") or {}).get("full_name") or "")
    head_repo = str(((pr.get("head") or {}).get("repo") or {}).get("full_name") or "")
    return bool(base_repo) and base_repo == head_repo


def land_handoff(event: dict) -> bool:
    """Heavy-at-land rule (CI_HEAVY_AT_LAND, default on; cmux#ci-min-per-pr-30): whether EVENT is the one event
    that hands a ready pull request to land, `ready-to-land` or `full-ci` being added. Only that event keeps the
    full tier; every other push of the pull request, the landing ones and stacked pull requests on other bases
    included, runs the cheap tier, so a heavy job runs once per landing attempt instead of on every head (merged
    PRs' superseded heads and never-merged PRs were 93% of PR-head minutes on 11-25..26)."""
    pr = event.get("pull_request") or {}
    added = str((event.get("label") or {}).get("name") or "")
    return event.get("action") == "labeled" and added in (LAND_LABEL, FULL_CI) and pr.get("draft") is not True


def tier(event_name: str, event: dict, switch: str = "1", facts: dict | None = None, now: float | None = None,
         idle_switch: str = "1", land_switch: str = "0", sync_switch: str = "1",
         green_switch: str = "1", carry_switch: str = "1", land_full_switch: str = "1",
         labelled_switch: str = "1", rerun_switch: str = "1", full_carry_switch: str = "1",
         heavy_at_land_switch: str = "0", one_shot: str | None = None,
         same_head_switch: str = "1") -> tuple[str, str]:
    """(tier, reason) for one event. Anything not a draft, idle, green-head or agent-made base merge or (with
    LAND_SWITCH on) not-yet-landing pull request head is `full`. With HEAVY_AT_LAND_SWITCH on, a full head of a pull
    request from this repository is `cheap` unless its event is the land handoff itself (see heavy_at_land)."""
    if event_name not in ("pull_request", "pull_request_target"):
        return "full", f"event {event_name or 'unknown'} is not a pull request"
    if (heavy_at_land_switch or "0").strip() not in ("0", "") and same_repo(event) and not land_handoff(event):
        decided = tier(event_name, event, switch, facts, now, idle_switch, land_switch, sync_switch, green_switch,
                       carry_switch, land_full_switch, labelled_switch, rerun_switch, full_carry_switch,
                       one_shot=one_shot, same_head_switch=same_head_switch)
        if decided[0] == "full":
            return "cheap", (f"{HEAVY_AT_LAND_REASON}: heavy jobs run once, on the event that hands this pull "
                             f"request to land (adding `{LAND_LABEL}` or `{FULL_CI}`), not on every push; "
                             f"without CI_HEAVY_AT_LAND this head would be full ({decided[1]})")
        return decided
    pr = event.get("pull_request") or {}
    labels = labels_of(event)
    carried_run = full_carry(facts) if full_carry_rule_applies(event, full_carry_switch) else None
    if carried_run:
        return carried_run
    if facts and facts.get("same_head_landed") is True and same_head_rule_applies(event, same_head_switch):
        return "none", (f"{SAME_HEAD_REASON}: {LAND_LABEL} added again to "
                        f"{str((pr.get('head') or {}).get('sha') or '')[:10]}, whose land tier already ran and "
                        f"passed here with every check green: nothing runs again and {LAND_STATUS} stays success; "
                        f"a new commit or {FULL_CI} runs it")
    if full_ci_applies(event, one_shot):
        return "full", "full-ci label"
    land_on = (land_switch or "0").strip() not in ("0", "") and land_rule_applies(event)
    landing = (LAND_LABEL in labels or for_ask(event)) and pr.get("draft") is not True
    if (idle_switch or "1").strip() != "0" and not landing and event.get("action") == "synchronize" and idle(
            facts, time.time() if now is None else now):
        return "none", (f"this head only merges the base into a pull request with no commit of its own for "
                        f"{IDLE_HOURS} h: nothing runs until a new commit, the land's merge run, or full-ci")
    if (facts and facts.get("base_merge_only") and facts.get("previous_green") is True
            and green_rule_applies(event, green_switch, land_switch, labelled_switch, one_shot)):
        return "none", (f"this head only merges the base onto {str(facts.get('previous') or '')[:10]}, whose every "
                        f"run passed: nothing runs until a new commit, {LAND_LABEL} (the land), or {FULL_CI}; "
                        f"{LAND_STATUS} stays pending")
    if (facts and facts.get("same_patch_green") is True
            and green_rule_applies(event, green_switch, land_switch, labelled_switch, one_shot)):
        return "none", (f"this head carries the same change as {str(facts.get('before') or '')[:10]} (rebased or "
                        f"merged onto a newer base), whose every run passed: nothing runs until a new change, "
                        f"{LAND_LABEL} (the land), or {FULL_CI}; {LAND_STATUS} stays pending")
    if (facts and facts.get("base_merge_only") and facts.get("previous_green") is False
            and facts.get("workflow_passed") is True and rerun_rule_applies(event, rerun_switch, land_switch, one_shot)):
        return "none", (f"{RERUN_REASON}: this head only merges the base onto "
                        f"{str(facts.get('previous') or '')[:10]}, where {facts.get('workflow')} passed and another "
                        f"run did not: only what was not green there runs again; {FULL_CI} or {LAND_LABEL} (the "
                        f"land) runs everything, {LAND_STATUS} stays pending")
    if (sync_switch or "1").strip() != "0" and not landing and event.get("action") == "synchronize"\
            and sync_merge(facts):
        return "cheap", ("this head only merges the base into the pull request, with a merge commit that was made "
                         "by git, not GitHub: the cheap tier runs, and the branch's next commit of its own, "
                         "`full-ci`, or land's update-branch runs the full tier")
    if (landing and facts and facts.get("base_merge_only") and facts.get("previous_landed") is True
            and carry_rule_applies(event, carry_switch, land_switch, one_shot)):
        return "cheap", (f"{CARRY_REASON}: this head only merges the base onto "
                         f"{str(facts.get('previous') or '')[:10]}, whose full tier passed ({LAND_STATUS} success, "
                         f"every run green): the cheap tier runs and {LAND_STATUS} carries success; a commit of its "
                         f"own or {FULL_CI} runs the full tier")
    if (switch or "1").strip() == "0" and pr.get("draft") is True:
        return "full", "CI_DRAFT_CHEAP_TIER=0"
    if pr.get("draft") is True:
        return "cheap", "draft pull request: the full tier runs when it is marked ready for review (or with full-ci)"
    if land_on and not landing:
        # Name what really gives this head the full tier: with CI_LAND_FULL_PER_PR off, `ready-to-land` lands on the
        # affected tier below (the hourly base run), so only full-ci runs the full tier on the pull request itself.
        when = (f"`{LAND_LABEL}` is added (land-judge adds it when asked to land) or with {FULL_CI}"
                if (land_full_switch or "0").strip() == "1" else
                f"{FULL_CI} is added (`{LAND_LABEL}` lands on the affected tier: the full tier runs hourly on "
                f"{LAND_BASE}'s head)")
        return "cheap", f"not handed off to land yet: the full tier runs when {when}; {LAND_STATUS} stays pending until then"
    if landing and land_on and (land_full_switch or "0").strip() != "1":
        return "cheap", (f"{LAND_AFFECTED_REASON}: the full tier runs once an hour on {LAND_BASE}'s head "
                         f"(cmux-next-hourly-full-tier.yml); {FULL_CI} gives this head the full tier, and "
                         f"CI_LAND_FULL_PER_PR=1 restores it for every landing head; {LAND_STATUS} is success, so "
                         f"land waits on this tier's checks")
    if landing:
        return "full", (f"{LAND_LABEL} label" if LAND_LABEL in labels else "names a Leo ask: handed off to land")
    return "full", "ready for review"


def _git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True, timeout=60).stdout


def head_facts(event: dict, depth: int = 30, actions: tuple[str, ...] = ("synchronize",)) -> dict | None:
    """{"base_merge_only", "own_last", "by_github", "previous", "base_parent"} for the head of an event whose action
    is in ACTIONS, read with git from the current checkout (fetching commits only, no trees, when they are missing).
    None when anything is unreadable."""
    pr = event.get("pull_request") or {}
    sha = str((pr.get("head") or {}).get("sha") or "")
    base = str((pr.get("base") or {}).get("ref") or "")
    if event.get("action") not in actions or not re.fullmatch(r"[0-9a-f]{40}", sha) or not base:
        return None
    merge = base_merge_message(base)
    try:
        github_made = False

        def commit(rev: str) -> tuple[list[str], int, str]:
            nonlocal github_made
            raw = _git("cat-file", "commit", rev)
            header, _, message = raw.partition("\n\n")
            parents = [line.split()[1] for line in header.splitlines() if line.startswith("parent ")]
            stamp = next(line for line in header.splitlines() if line.startswith("committer "))
            github_made = "<noreply@github.com>" in stamp
            return parents, int(stamp.split()[-2]), message.strip()

        def have(rev: str) -> bool:
            return subprocess.run(["git", "cat-file", "-e", f"{rev}^{{commit}}"], capture_output=True,
                                  timeout=30).returncode == 0

        # A depth only bounds the download in a checkout that is already shallow (CI's); in a full clone it would
        # write .git/shallow for every worktree (tests/test_ci_no_shallow_dev_fetch.py).
        shallow = _git("rev-parse", "--is-shallow-repository").strip() == "true"

        def fetch(rev: str, depth_wanted: int) -> None:
            _git("fetch", "--no-tags", "--quiet", *([f"--depth={depth_wanted}"] if shallow else []),
                 "--filter=tree:0", "origin", rev)

        if not have(sha):
            fetch(sha, 1)
        parents, _, message = commit(sha)
        by_github = github_made  # the head's own committer; the walk below reads older commits
        read = "message"
        if len(parents) == 2 and not merge.match(message):
            read = "content" if same_change_as(base, sha, parents[0]) else ""
        if len(parents) != 2 or not read:
            return {"base_merge_only": False, "own_last": None, "by_github": by_github}
        more = {"merge_read": "content"} if read == "content" else {}
        previous = rev = parents[0]
        base_parent = parents[1]
        for _ in range(depth):  # first parents: past earlier base merges to the branch's own last commit
            if not have(rev):
                fetch(rev, depth)
            parents, when, message = commit(rev)
            if not (len(parents) == 2 and merge.match(message)):
                return {"base_merge_only": True, "own_last": when, "by_github": by_github, "previous": previous,
                        "base_parent": base_parent, **more}
            rev = parents[0]
    except (subprocess.SubprocessError, OSError, StopIteration, ValueError, IndexError):
        return None
    return {"base_merge_only": True, "own_last": None, "by_github": by_github, "previous": previous,
            "base_parent": base_parent, **more}


def full_carry_facts(event: dict, facts: dict) -> dict:
    """The full-ci base merge carry rule's facts for a base merge head (FACTS, head_facts): full_landed (the previous
    head carries `cmux/land-tier` success), own_change_kept (the PR's own change from the merged base at the head is
    the change from its old base at the previous head: same files, blobs and lines, so the merge touched none of
    them and edited nothing else), and previous_runs, previous_green, workflow, workflow_passed. A fact it cannot read
    is missing or None, and full_carry runs the full set."""
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    sha = str(((event.get("pull_request") or {}).get("head") or {}).get("sha") or "")
    previous = str(facts.get("previous") or "")
    base_parent = str(facts.get("base_parent") or "")
    landed = land_status_at(repo, previous, token)
    out: dict = {"full_landed": None if landed is None else landed == "success"}
    if landed != "success":
        return out
    runs = runs_at(repo, previous, token)
    if runs is None:
        return out
    key = own_patch_key(repo, base_parent, sha, token, blobs=True)
    kept = None if key is None else own_patch_key(repo, base_parent, previous, token, blobs=True) == key
    workflow = workflow_file(os.environ.get("GITHUB_WORKFLOW_REF"))
    return {**out, "own_change_kept": kept, "previous_runs": runs, "previous_green": green_previous(runs),
            "workflow": workflow, "workflow_passed": passed_there(runs, workflow)}


def same_change_as(base: str, sha: str, first_parent: str) -> bool:
    """Whether merge commit SHA only merged the base into FIRST_PARENT, read by its content, not its message: the
    change SHA makes over its merge base with BASE is the change FIRST_PARENT made (own_patch_key, the same-patch
    rule's key). So nothing was hand-resolved or edited in the merge and nothing but base commits came in (a merge of
    another branch adds that branch's change). An agent's `git merge` with its own wording ("Merge commit 'SHA' into
    lane/x", "Merge feat-cmux-next to resync PR head") did not match base_merge_message, so the head ran every tier
    as a new change: 238 such heads on 2026-11-25 22Z..11-26 22Z, about 24k runner-min (ci-min-per-pr-140). Two
    compare reads, made only for a two-parent head whose message is not a base merge's; unread is no."""
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if (os.environ.get("CI_CONTENT_BASE_MERGE", "1").strip() == "0"
            or not re.fullmatch(r"[0-9a-f]{40}", first_parent)):
        return False
    key = own_patch_key(repo, base, sha, token)
    return key is not None and own_patch_key(repo, base, first_parent, token) == key


def same_patch_facts(event: dict) -> dict:
    """{"before", "same_patch_green"} for a synchronize event: whether the head's own change equals the previous
    head's (`before`) and every run at `before` passed. Reads nothing when `before` is not a commit."""
    pr = event.get("pull_request") or {}
    sha = str((pr.get("head") or {}).get("sha") or "")
    before = str(event.get("before") or "")
    base = str((pr.get("base") or {}).get("ref") or "")
    if not (re.fullmatch(r"[0-9a-f]{40}", before) and re.fullmatch(r"[0-9a-f]{40}", sha) and before != sha):
        return {}
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    key = own_patch_key(repo, base, sha, token)
    if key is None or own_patch_key(repo, base, before, token) != key:
        return {"before": before, "same_patch_green": False}
    runs = runs_at(repo, before, token)
    return {"before": before, "same_patch_green": runs is not None and green_previous(runs)}


POST_MERGE_TIER_VAR = "CI_POST_MERGE_TIER_PR"  # 1: batch-covered post-merge-tier workflows skip PR heads
POST_MERGE_TIER_REASON = "post-merge tier (CI_POST_MERGE_TIER_PR=1)"


def _repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def batch_post_merge_workflows(root: str | None = None) -> set[str]:
    """Workflow files that RFD 0013 puts after the merge (merge_tier.post_merge, switch on) and that a post-merge
    batch suite runs. Empty when either file is unreadable or the switch is off."""
    root = root or _repo_root()
    checks = _load(os.path.join(root, ".github", "post-merge-checks.json")).get("merge_tier")
    batch = _load(os.path.join(root, ".github", "post-merge-batch.json")).get("suites")
    if not isinstance(checks, dict) or str(checks.get("switch") or "") != "on" or not isinstance(batch, dict):
        return set()
    listed = checks.get("post_merge")
    listed = set(listed) if isinstance(listed, (dict, list)) else set()
    run = {str(v.get("workflow") or "") for v in batch.values() if isinstance(v, dict)}
    return {str(w) for w in listed} & run


def post_merge_tier(event_name: str, event: dict, workflow: str, switch: str | None = None,
                    root: str | None = None) -> tuple[str, str] | None:
    """The post-merge tier rule (docstring): ("none", reason) for a feat-cmux-next pull request head in a
    batch-covered post-merge-tier WORKFLOW with SWITCH on; None when the rule does not apply."""
    switch = os.environ.get(POST_MERGE_TIER_VAR, "0") if switch is None else switch
    if (switch or "0").strip() != "1" or event_name not in ("pull_request", "pull_request_target"):
        return None
    pr = event.get("pull_request") or {}
    if str((pr.get("base") or {}).get("ref") or "") != "feat-cmux-next" or not same_repo(event):
        return None
    if FULL_CI in labels_of(event) or not workflow or workflow not in batch_post_merge_workflows(root):
        return None
    return "none", (f"{POST_MERGE_TIER_REASON}: {workflow} is in RFD 0013's post-merge tier and the "
                    f"feat-cmux-next post-merge batch runs it on every merge, bisecting a red to its pull request; "
                    f"`{FULL_CI}` runs it here")


def decide(event_name: str, event: dict) -> tuple[str, str]:
    """tier() for this run: its switches from the environment, the head's facts read only when they can matter."""
    return decide_with_facts(event_name, event)[0]


def decide_with_facts(event_name: str, event: dict) -> tuple[tuple[str, str], dict | None]:
    """(decide()'s answer, the facts it read): pr_router.rerun_plan reads `previous_runs` from them."""
    post_merge = post_merge_tier(event_name, event, workflow_file(os.environ.get("GITHUB_WORKFLOW_REF")))
    if post_merge:
        return post_merge, None
    switch = os.environ.get("CI_DRAFT_CHEAP_TIER", "1")
    idle_switch = os.environ.get("CI_IDLE_BASE_MERGE_SKIP", "1")
    land_switch = os.environ.get("CI_LAND_TIER", "1")
    sync_switch = os.environ.get("CI_SYNC_MERGE_CHEAP", "1")
    green_switch = os.environ.get("CI_GREEN_BASE_MERGE_SKIP", "1")
    land_full_switch = os.environ.get("CI_LAND_FULL_PER_PR", "0")
    carry_switch = os.environ.get("CI_LAND_CARRY", "1")
    labelled_switch = os.environ.get("CI_LABELLED_BASE_MERGE_SKIP", "1")
    rerun_switch = os.environ.get("CI_RED_BASE_MERGE_RERUN", "1")
    one_shot = os.environ.get(ONE_SHOT_VAR, "1")
    full_carry_switch = os.environ.get("CI_FULL_CI_BASE_MERGE_CARRY", "1")
    heavy_at_land_switch = os.environ.get("CI_HEAVY_AT_LAND", "1")
    labels = labels_of(event)
    pull = event_name in ("pull_request", "pull_request_target")
    same_head_switch = os.environ.get(SAME_HEAD_VAR, "1")
    if pull and same_head_rule_applies(event, same_head_switch):
        facts = same_head_facts(event)
        if facts.get("same_head_landed") is True:
            return tier(event_name, event, switch, facts, None, idle_switch, land_switch, sync_switch, green_switch,
                        carry_switch, land_full_switch, labelled_switch, rerun_switch, "0", heavy_at_land_switch,
                        one_shot, same_head_switch), facts
    if pull and full_carry_rule_applies(event, full_carry_switch):
        facts = head_facts(event, actions=("labeled",))
        if facts and facts.get("base_merge_only"):
            facts = {**facts, **full_carry_facts(event, facts)}
            decided = tier(event_name, event, switch, facts, None, idle_switch, land_switch, sync_switch,
                           green_switch, carry_switch, land_full_switch, labelled_switch, rerun_switch,
                           full_carry_switch, one_shot=one_shot)
            if full_carry(facts):
                return decided, facts
    green_wanted = pull and green_rule_applies(event, green_switch, land_switch, labelled_switch, one_shot)
    carry_wanted = pull and carry_rule_applies(event, carry_switch, land_switch, one_shot)
    rerun_wanted = pull and rerun_rule_applies(event, rerun_switch, land_switch, one_shot)
    wanted = (pull and (idle_switch.strip() != "0" or sync_switch.strip() != "0" or green_wanted or carry_wanted
                        or rerun_wanted) and not full_ci_applies(event, one_shot))
    facts = head_facts(event) if wanted else None
    if facts and facts.get("base_merge_only") and (green_wanted or rerun_wanted):
        if idle_switch.strip() == "0" or not idle(facts, time.time()):
            runs = runs_at(os.environ.get("GITHUB_REPOSITORY", ""), str(facts.get("previous") or ""),
                           os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or "")
            facts = {**facts, "previous_green": green_previous(runs) if runs is not None else None}
            if rerun_wanted and runs is not None:
                workflow = workflow_file(os.environ.get("GITHUB_WORKFLOW_REF"))
                facts = {**facts, "previous_runs": runs, "workflow": workflow,
                         "workflow_passed": passed_there(runs, workflow)}
    if green_wanted and not (facts and facts.get("previous_green")) and (
            idle_switch.strip() == "0" or not idle(facts, time.time())):
        facts = {**(facts or {}), **same_patch_facts(event)}
    if facts and facts.get("base_merge_only") and carry_wanted:
        repo = os.environ.get("GITHUB_REPOSITORY", "")
        previous = str(facts.get("previous") or "")
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
        landed = land_status_at(repo, previous, token) == "success"
        runs = runs_at(repo, previous, token) if landed else None
        facts = {**facts, "previous_landed": landed and runs is not None and green_previous(runs)}
    return tier(event_name, event, switch, facts, None, idle_switch, land_switch, sync_switch, green_switch,
                carry_switch, land_full_switch, labelled_switch, rerun_switch, "0", heavy_at_land_switch,
                one_shot), facts


def _load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def main(argv: list[str]) -> int:
    if argv[:1] == ["explain"]:
        if len(argv) < 2:
            print(__doc__, file=sys.stderr)
            return 2
        name = argv[2] if len(argv) > 2 else "pull_request"
        result = decide(name, _load(argv[1]))
        print(f"tier={result[0]}\nreason={result[1]}")
        return 0
    if argv[:1] == ["tier"]:
        print(decide(os.environ.get("GITHUB_EVENT_NAME", ""), _load(os.environ.get("GITHUB_EVENT_PATH", "")))[0])
        return 0
    if argv:
        print(__doc__, file=sys.stderr)
        return 2
    name = os.environ.get("GITHUB_EVENT_NAME", "")
    event = _load(os.environ.get("GITHUB_EVENT_PATH", ""))
    value, reason = decide(name, event)
    lines = f"tier={value}\nreason={reason}\n"
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as handle:
            handle.write(lines)
    else:
        sys.stdout.write(lines)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"CI tier: **{value}** ({reason}).\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
