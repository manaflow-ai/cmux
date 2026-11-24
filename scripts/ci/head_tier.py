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

Switches: the repository variable CI_LAND_TIER=0 turns the land rule off (every ready head is full again); the
repository variable CI_DRAFT_CHEAP_TIER=0 (passed in as $CI_DRAFT_CHEAP_TIER) gives every draft head
the full tier again; CI_IDLE_BASE_MERGE_SKIP=0 turns the idle rule off. Stdlib only; anything unreadable gives
`full`.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

FULL_CI = "full-ci"
LAND_LABEL = "ready-to-land"  # next_autoland.LABEL: the PR is handed off to land
LAND_BASE = "feat-cmux-next"
LAND_STATUS = "cmux/land-tier"  # the commit status the land rule's heads carry (pr-router.yml posts it)
IDLE_HOURS = 24


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


def tier(event_name: str, event: dict, switch: str = "1", facts: dict | None = None, now: float | None = None,
         idle_switch: str = "1", land_switch: str = "0") -> tuple[str, str]:
    """(tier, reason) for one event. Anything not a draft, idle or (with LAND_SWITCH on) not-yet-landing pull request
    head is `full`."""
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
    if (switch or "1").strip() == "0" and pr.get("draft") is True:
        return "full", "CI_DRAFT_CHEAP_TIER=0"
    if pr.get("draft") is True:
        return "cheap", "draft pull request: the full tier runs when it is marked ready for review (or with full-ci)"
    if land_on and not landing:
        return "cheap", (f"not handed off to land yet: the full tier runs when `{LAND_LABEL}` is added (land-judge "
                         f"adds it when asked to land) or with full-ci; {LAND_STATUS} stays pending until then")
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
    merge = re.compile(rf"^Merge (remote-tracking )?branch '(origin/)?{re.escape(base)}'")
    try:
        def commit(rev: str) -> tuple[list[str], int, str]:
            raw = _git("cat-file", "commit", rev)
            header, _, message = raw.partition("\n\n")
            parents = [line.split()[1] for line in header.splitlines() if line.startswith("parent ")]
            stamp = next(line for line in header.splitlines() if line.startswith("committer "))
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
        if len(parents) != 2 or not merge.match(message):
            return {"base_merge_only": False, "own_last": None}
        rev = parents[0]
        for _ in range(depth):  # first parents: past earlier base merges to the branch's own last commit
            if not have(rev):
                fetch(rev, depth)
            parents, when, message = commit(rev)
            if not (len(parents) == 2 and merge.match(message)):
                return {"base_merge_only": True, "own_last": when}
            rev = parents[0]
    except (subprocess.SubprocessError, OSError, StopIteration, ValueError, IndexError):
        return None
    return {"base_merge_only": True, "own_last": None}


def decide(event_name: str, event: dict) -> tuple[str, str]:
    """tier() for this run: its switches from the environment, the head's facts read only when they can matter."""
    switch = os.environ.get("CI_DRAFT_CHEAP_TIER", "1")
    idle_switch = os.environ.get("CI_IDLE_BASE_MERGE_SKIP", "1")
    land_switch = os.environ.get("CI_LAND_TIER", "1")
    labels = {str(label.get("name") or "") for label in (event.get("pull_request") or {}).get("labels") or []}
    wanted = (event_name in ("pull_request", "pull_request_target") and idle_switch.strip() != "0"
              and FULL_CI not in labels)
    return tier(event_name, event, switch, head_facts(event) if wanted else None, None, idle_switch, land_switch)


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
