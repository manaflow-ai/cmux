#!/usr/bin/env python3
"""The PR runs what base runs: no new check may first run after the merge.

A workflow that a push to feat-cmux-next starts and a pull request into it cannot start
gives its verdict only once the change is on the base. In the 7 days to 2026-11-13 the
base took 140 fixes for 3,676 landings (3.81 per 100), and of the 44 fixes that name a
check about 14 name one a pull request never ran.

.github/post-merge-checks.json lists every such workflow as `publish` (a deploy, a
publish, a bot: nothing a pull request could have caught) or `check` (a verdict about
the code, which belongs on the pull request), each with a reason. This test fails when

  - a workflow runs after the merge only and is not in the list: give it a pull_request
    trigger (path-filtered is fine), or have a workflow that pull requests start call it;
  - a listed workflow is gone, lost its push trigger or gained a pull request path: drop
    its entry, so the list only shrinks;
  - the number of `check` entries is above `check_budget`, which only goes down.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
LIST = ROOT / ".github" / "post-merge-checks.json"
BASE = "feat-cmux-next"
KINDS = ("check", "publish")


def branch_pattern(glob: str) -> re.Pattern[str]:
    """GitHub's branch filter glob: ** crosses '/', * does not, [] is a class, and
    ? and + quantify the character before them."""
    out: list[str] = []
    i = 0
    while i < len(glob):
        c = glob[i]
        if glob.startswith("**", i):
            out.append(".*")
            i += 2
            continue
        if c == "*":
            out.append("[^/]*")
        elif c in "?+" and out:
            out[-1] = "(?:" + out[-1] + ")" + c
        elif c == "[":
            end = glob.find("]", i)
            if end < 0:
                out.append(re.escape(c))
            else:
                out.append(glob[i:end + 1])
                i = end + 1
                continue
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("".join(out) + r"\Z")


def branch_matches(trigger: dict | None, branch: str, *, push: bool) -> bool:
    """Whether `branch` passes the trigger's branch filter (paths aside): the pushed
    branch for push, the base branch for pull_request and pull_request_target."""
    trigger = trigger or {}
    if "branches-ignore" in trigger:
        return not any(branch_pattern(p).match(branch) for p in trigger["branches-ignore"])
    if "branches" not in trigger:
        # A push with only tag filters starts on no branch; a pull request has no tag filter.
        return not (push and ("tags" in trigger or "tags-ignore" in trigger))
    matched = False
    for pattern in trigger["branches"]:
        negated = pattern.startswith("!")
        if branch_pattern(pattern[1:] if negated else pattern).match(branch):
            matched = not negated
    return matched


def triggers(doc: dict) -> dict:
    on = doc.get("on", doc.get(True)) or {}
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return dict.fromkeys(on)
    return on


def called_workflows(doc: dict) -> set[str]:
    """The local reusable workflows this one's jobs call."""
    found = set()
    for job in (doc.get("jobs") or {}).values():
        uses = job.get("uses") if isinstance(job, dict) else None
        if isinstance(uses, str) and uses.startswith("./.github/workflows/"):
            found.add(uses.rsplit("/", 1)[1].split("@", 1)[0])
    return found


def post_merge_only(workflows: dict[str, dict], base: str = BASE) -> set[str]:
    """Workflows a push to `base` starts that no pull request into `base` can reach,
    directly or as a reusable workflow called (at any depth) from one that it starts."""
    on_pr = {
        name
        for name, doc in workflows.items()
        if any(
            event in triggers(doc) and branch_matches(triggers(doc)[event], base, push=False)
            for event in ("pull_request", "pull_request_target")
        )
    }
    reached, frontier = set(on_pr), list(on_pr)
    while frontier:
        for callee in called_workflows(workflows[frontier.pop()]):
            if callee in workflows and callee not in reached and "workflow_call" in triggers(workflows[callee]):
                reached.add(callee)
                frontier.append(callee)
    return {
        name
        for name, doc in workflows.items()
        if name not in reached
        and "push" in triggers(doc)
        and branch_matches(triggers(doc)["push"], base, push=True)
    }


def load_workflows() -> dict[str, dict]:
    return {
        path.name: yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for path in sorted(WORKFLOWS.glob("*.y*ml"))
    }


def load_list() -> dict:
    return json.loads(LIST.read_text(encoding="utf-8"))


class PostMergeOnlyMatcherTest(unittest.TestCase):
    def test_branch_filters(self) -> None:
        self.assertTrue(branch_matches({"branches": ["main", BASE]}, BASE, push=True))
        self.assertFalse(branch_matches({"branches": ["main"]}, BASE, push=True))
        self.assertFalse(branch_matches({"branches": ["feat-cmux-next-*"]}, BASE, push=True))
        self.assertTrue(branch_matches({"branches-ignore": ["main"]}, BASE, push=False))
        self.assertTrue(branch_matches(None, BASE, push=False))
        self.assertTrue(branch_matches({"paths": ["x/**"]}, BASE, push=False))
        self.assertFalse(branch_matches({"tags": ["v*"]}, BASE, push=True))
        self.assertFalse(branch_matches({"branches": ["**", "!feat-cmux-next"]}, BASE, push=True))

    def test_post_merge_only(self) -> None:
        push = {"push": {"branches": [BASE]}}
        both = {"on": {**push, "pull_request": {"paths": ["a/**"]}}}
        other_base = {"on": {**push, "pull_request": {"branches": ["main"]}}}
        target = {"on": {**push, "pull_request_target": None}}
        reusable = {"on": {**push, "workflow_call": None}}
        nested = {"on": {**push, "workflow_call": None}}
        not_callable = {"on": push}
        caller = {"on": "pull_request", "jobs": {"a": {"uses": "./.github/workflows/reusable.yml"}}}
        reusable["jobs"] = {"b": {"uses": "./.github/workflows/nested.yml"}, "c": {"uses": "./.github/workflows/plain.yml"}}
        found = post_merge_only({
            "only.yml": {"on": push},
            "main.yml": {"on": {"push": {"branches": ["main"]}}},
            "both.yml": both,
            "other.yml": other_base,
            "target.yml": target,
            "reusable.yml": reusable,
            "nested.yml": nested,
            "plain.yml": not_callable,
            "caller.yml": caller,
            "dispatch.yml": {"on": "workflow_dispatch"},
        })
        self.assertEqual(found, {"only.yml", "other.yml", "plain.yml"})


class PostMergeChecksListTest(unittest.TestCase):
    def setUp(self) -> None:
        self.found = post_merge_only(load_workflows())
        self.listed = load_list()
        self.entries = self.listed["workflows"]

    def test_every_post_merge_only_workflow_is_listed(self) -> None:
        for name in sorted(self.found - set(self.entries)):
            with self.subTest(workflow=name):
                self.fail(
                    f"{name} runs on a push to {BASE} and on no pull request into it, so it can "
                    "only go red after the merge. Give it a pull_request trigger (path-filtered "
                    "is fine) or call it from a workflow pull requests start. Only a deploy, a "
                    f"publish or a bot belongs in {LIST.relative_to(ROOT)}, as kind `publish`."
                )

    def test_the_list_only_shrinks(self) -> None:
        for name in sorted(set(self.entries) - self.found):
            with self.subTest(workflow=name):
                self.fail(
                    f"{name} is gone, no longer starts on a push to {BASE}, or now runs on pull "
                    f"requests: drop it from {LIST.relative_to(ROOT)} (and lower check_budget if "
                    "it was a check)."
                )

    def test_entries_say_what_they_are(self) -> None:
        for name, entry in self.entries.items():
            with self.subTest(workflow=name):
                self.assertIn(entry.get("kind"), KINDS)
                self.assertGreaterEqual(len(entry.get("why", "").split()), 4, "say why in a few words")

    def test_checks_stay_within_the_budget(self) -> None:
        checks = sorted(name for name, entry in self.entries.items() if entry.get("kind") == "check")
        budget = self.listed["check_budget"]
        print(f"post-merge-only checks: {len(checks)} (budget {budget}, target 0)")
        self.assertLessEqual(
            len(checks), budget,
            f"{len(checks)} checks first run after the merge, over the budget of {budget}: "
            f"{', '.join(checks)}. The budget only goes down.",
        )
        self.assertEqual(
            budget, len(checks),
            f"check_budget is {budget} and {len(checks)} checks are listed: lower it to "
            f"{len(checks)}, so a check that moved onto pull requests cannot be replaced.",
        )


if __name__ == "__main__":
    unittest.main()
