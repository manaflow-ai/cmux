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

Switches: the repository variable CI_LAND_TIER=0 turns the land rule off (every ready head is full again); the
repository variable CI_DRAFT_CHEAP_TIER=0 (passed in as $CI_DRAFT_CHEAP_TIER) gives every draft head
the full tier again; CI_IDLE_BASE_MERGE_SKIP=0 turns the idle rule off; CI_SYNC_MERGE_CHEAP=0 turns the sync rule
off; CI_GREEN_BASE_MERGE_SKIP=0 turns the green-head base merge rule off; CI_LAND_FULL_PER_PR=1 turns the
hourly full tier rule off (a landing head runs the full tier again). Stdlib only; anything unreadable gives
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
LAND_LABEL = "ready-to-land"  # next_autoland.LABEL: the PR is handed off to land
LAND_BASE = "feat-cmux-next"
LAND_STATUS = "cmux/land-tier"  # the commit status the land rule's heads carry (pr-router.yml posts it)
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


def green_rule_applies(event: dict, green_switch: str = "1", land_switch: str = "0") -> bool:
    """Whether the green-head base merge rule can apply to EVENT (before reading any fact): a synchronize into
    feat-cmux-next (land_rule_applies) with both switches on and neither full-tier label."""
    pr = event.get("pull_request") or {}
    labels = {str(label.get("name") or "") for label in pr.get("labels") or []}
    base = str((pr.get("base") or {}).get("ref") or "")
    return ((green_switch or "1").strip() != "0" and (land_switch or "0").strip() not in ("0", "")
            and event.get("action") == "synchronize" and land_rule_applies(event)
            and not labels & {FULL_CI, LAND_LABEL})


def land_affected(decided: tuple[str, str]) -> bool:
    """Whether DECIDED is the hourly full tier rule's cheap tier for a landing head: its green verdict is the land's
    (pr_router.land_status posts cmux/land-tier success on it)."""
    return decided[0] == "cheap" and str(decided[1]).startswith(LAND_AFFECTED_REASON)


def tier(event_name: str, event: dict, switch: str = "1", facts: dict | None = None, now: float | None = None,
         idle_switch: str = "1", land_switch: str = "0", sync_switch: str = "1",
         green_switch: str = "1", land_full_switch: str = "1") -> tuple[str, str]:
    """(tier, reason) for one event. Anything not a draft, idle, green-head or agent-made base merge or (with
    LAND_SWITCH on) not-yet-landing pull request head is `full`."""
    if event_name not in ("pull_request", "pull_request_target"):
        return "full", f"event {event_name or 'unknown'} is not a pull request"
    pr = event.get("pull_request") or {}
    labels = {str(label.get("name") or "") for label in pr.get("labels") or []}
    if FULL_CI in labels:
        return "full", "full-ci label"
    land_on = (land_switch or "0").strip() not in ("0", "") and land_rule_applies(event)
    landing = LAND_LABEL in labels and pr.get("draft") is not True
    if (idle_switch or "1").strip() != "0" and not landing and event.get("action") == "synchronize" and idle(
            facts, time.time() if now is None else now):
        return "none", (f"this head only merges the base into a pull request with no commit of its own for "
                        f"{IDLE_HOURS} h: nothing runs until a new commit, the land's merge run, or full-ci")
    if (not landing and facts and facts.get("base_merge_only") and facts.get("previous_green") is True
            and green_rule_applies(event, green_switch, land_switch)):
        return "none", (f"this head only merges the base onto {str(facts.get('previous') or '')[:10]}, whose every "
                        f"run passed: nothing runs until a new commit, {LAND_LABEL} (the land), or {FULL_CI}; "
                        f"{LAND_STATUS} stays pending")
    if (sync_switch or "1").strip() != "0" and not landing and event.get("action") == "synchronize"\
            and sync_merge(facts):
        return "cheap", ("this head only merges the base into the pull request, with a merge commit that was made "
                         "by git, not GitHub: the cheap tier runs, and the branch's next commit of its own, "
                         "`full-ci`, or land's update-branch runs the full tier")
    if (switch or "1").strip() == "0" and pr.get("draft") is True:
        return "full", "CI_DRAFT_CHEAP_TIER=0"
    if pr.get("draft") is True:
        return "cheap", "draft pull request: the full tier runs when it is marked ready for review (or with full-ci)"
    if land_on and not landing:
        return "cheap", (f"not handed off to land yet: the full tier runs when `{LAND_LABEL}` is added (land-judge "
                         f"adds it when asked to land) or with full-ci; {LAND_STATUS} stays pending until then")
    if landing and land_on and (land_full_switch or "0").strip() != "1":
        return "cheap", (f"{LAND_AFFECTED_REASON}: the full tier runs once an hour on {LAND_BASE}'s head "
                         f"(cmux-next-hourly-full-tier.yml); {FULL_CI} gives this head the full tier, and "
                         f"CI_LAND_FULL_PER_PR=1 restores it for every landing head; {LAND_STATUS} is success, so "
                         f"land waits on this tier's checks")
    if landing:
        return "full", f"{LAND_LABEL} label"
    return "full", "ready for review"


def _git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True, timeout=60).stdout


def head_facts(event: dict, depth: int = 30) -> dict | None:
    """{"base_merge_only", "own_last"} for a synchronize event's head, read with git from the current checkout
    (fetching commits only, no trees, when they are missing). None when anything is unreadable."""
    pr = event.get("pull_request") or {}
    sha = str((pr.get("head") or {}).get("sha") or "")
    base = str((pr.get("base") or {}).get("ref") or "")
    if event.get("action") != "synchronize" or not re.fullmatch(r"[0-9a-f]{40}", sha) or not base:
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
        if len(parents) != 2 or not merge.match(message):
            return {"base_merge_only": False, "own_last": None, "by_github": by_github}
        previous = rev = parents[0]
        for _ in range(depth):  # first parents: past earlier base merges to the branch's own last commit
            if not have(rev):
                fetch(rev, depth)
            parents, when, message = commit(rev)
            if not (len(parents) == 2 and merge.match(message)):
                return {"base_merge_only": True, "own_last": when, "by_github": by_github, "previous": previous}
            rev = parents[0]
    except (subprocess.SubprocessError, OSError, StopIteration, ValueError, IndexError):
        return None
    return {"base_merge_only": True, "own_last": None, "by_github": by_github, "previous": previous}


def decide(event_name: str, event: dict) -> tuple[str, str]:
    """tier() for this run: its switches from the environment, the head's facts read only when they can matter."""
    switch = os.environ.get("CI_DRAFT_CHEAP_TIER", "1")
    idle_switch = os.environ.get("CI_IDLE_BASE_MERGE_SKIP", "1")
    land_switch = os.environ.get("CI_LAND_TIER", "1")
    sync_switch = os.environ.get("CI_SYNC_MERGE_CHEAP", "1")
    green_switch = os.environ.get("CI_GREEN_BASE_MERGE_SKIP", "1")
    land_full_switch = os.environ.get("CI_LAND_FULL_PER_PR", "0")
    labels = {str(label.get("name") or "") for label in (event.get("pull_request") or {}).get("labels") or []}
    pull = event_name in ("pull_request", "pull_request_target")
    green_wanted = pull and green_rule_applies(event, green_switch, land_switch)
    wanted = (pull and (idle_switch.strip() != "0" or sync_switch.strip() != "0" or green_wanted)
              and FULL_CI not in labels)
    facts = head_facts(event) if wanted else None
    if facts and facts.get("base_merge_only") and green_wanted:
        if idle_switch.strip() == "0" or not idle(facts, time.time()):
            runs = runs_at(os.environ.get("GITHUB_REPOSITORY", ""), str(facts.get("previous") or ""),
                           os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or "")
            facts = {**facts, "previous_green": green_previous(runs) if runs is not None else None}
    return tier(event_name, event, switch, facts, None, idle_switch, land_switch, sync_switch, green_switch,
                land_full_switch)


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
