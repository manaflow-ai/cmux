#!/usr/bin/env python3
"""A push trigger names the branches it needs; arbitrary branch pushes start nothing.

On 2026-10-27 about 1,357 Actions runs sat queued behind a push flood: 974
cp/* patch refs, none with a pull request, each started every push workflow
whose filter matched any branch. A branch that needs CI gets it from its pull
request (pull_request, pull_request_target); push triggers are for the base
branches and the named branch families a workflow serves (preview deploys,
pin refs, nightly, rc). A new `push:` with no branch filter, a branches-ignore
filter or a catch-all pattern fails here unless ARBITRARY_BRANCH_PUSH says why.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# Branch names no workflow has a reason to know: a push to one of these must
# start nothing, except in the workflows listed below.
ARBITRARY_BRANCHES = (
    "some-lane",
    "fix/some-lane",
    "codex/some-lane",
    "claude/some-lane",
    "feat/some-lane",
)
# The cp/ patch refs never open a pull request. No workflow runs on them.
PATCH_REFS = ("cp/0", "cp/10-p12-perf-process-013", "cp/a/b")

# workflow -> why its push trigger may still match an arbitrary branch.
ARBITRARY_BRANCH_PUSH = {
    "cmux-tui-artifacts.yml": (
        "a same-repository pull request's checks fetch the cmux-tui tree its branch push "
        "published (cx-r2is); tree-preflight skips a push whose tree is already published"
    ),
}


def branch_pattern(glob: str) -> re.Pattern[str]:
    """GitHub's branch filter glob: ** crosses '/', * and ? do not, [] is a class."""
    out, i = [], 0
    while i < len(glob):
        c = glob[i]
        if glob.startswith("**", i):
            out.append(".*")
            i += 2
            continue
        if c == "*":
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            end = glob.find("]", i)
            if end < 0:
                out.append(re.escape(c))
            else:
                out.append(glob[i:end + 1])
                i = end + 1
                continue
        elif c == "+":
            out.append("+")
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("".join(out) + r"\Z")


def push_matches(push: dict, branch: str) -> bool:
    """Whether a push of `branch` starts this trigger (paths aside)."""
    if "branches-ignore" in push:
        return not any(branch_pattern(p).match(branch) for p in push["branches-ignore"])
    if "branches" not in push:
        # tags only: no branch push starts it; neither filter: every branch does.
        return "tags" not in push and "tags-ignore" not in push
    matched = False
    for pattern in push["branches"]:
        negated = pattern.startswith("!")
        if branch_pattern(pattern[1:] if negated else pattern).match(branch):
            matched = not negated
    return matched


def push_triggers() -> dict[str, dict]:
    found = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        on = doc.get("on", doc.get(True))
        if isinstance(on, str):
            on = {on: None}
        elif isinstance(on, list):
            on = dict.fromkeys(on)
        if isinstance(on, dict) and "push" in on:
            found[path.name] = on["push"] or {}
    return found


class PushTriggerBranchesTest(unittest.TestCase):
    def test_matcher(self) -> None:
        self.assertTrue(push_matches({"branches": ["**"]}, "cp/0"))
        self.assertFalse(push_matches({"branches": ["**", "!cp/**"]}, "cp/a/b"))
        self.assertTrue(push_matches({"branches": ["**", "!cp/**"]}, "some-lane"))
        self.assertFalse(push_matches({"branches": ["feat-cmux-next-*"]}, "feat-cmux-next"))
        self.assertTrue(push_matches({"branches": ["rc/**"]}, "rc/1.2/x"))
        self.assertFalse(push_matches({"branches": ["codex/vm-api-*"]}, "codex/some-lane"))
        self.assertTrue(push_matches({"branches-ignore": ["feat-cmux-next"]}, "some-lane"))
        self.assertTrue(push_matches({"paths": ["x/**"]}, "some-lane"))
        self.assertFalse(push_matches({"tags": ["v*"]}, "some-lane"))

    def test_no_push_trigger_runs_on_patch_refs(self) -> None:
        for name, push in push_triggers().items():
            for branch in PATCH_REFS:
                with self.subTest(workflow=name, branch=branch):
                    self.assertFalse(push_matches(push, branch), f"{name}: a push of {branch} starts it")

    def test_push_triggers_name_their_branches(self) -> None:
        triggers = push_triggers()
        for name, push in triggers.items():
            if name in ARBITRARY_BRANCH_PUSH:
                continue
            for branch in ARBITRARY_BRANCHES:
                with self.subTest(workflow=name, branch=branch):
                    self.assertFalse(
                        push_matches(push, branch),
                        f"{name}: a push of the arbitrary branch {branch} starts it; give the push a "
                        "branches filter for the base branches it needs and run branch CI on pull_request",
                    )

    def test_allowlist_is_current(self) -> None:
        triggers = push_triggers()
        for name in ARBITRARY_BRANCH_PUSH:
            with self.subTest(workflow=name):
                self.assertIn(name, triggers, f"{name} has no push trigger; drop it from ARBITRARY_BRANCH_PUSH")
                self.assertTrue(
                    any(push_matches(triggers[name], b) for b in ARBITRARY_BRANCHES),
                    f"{name} no longer matches arbitrary branches; drop it from ARBITRARY_BRANCH_PUSH",
                )


if __name__ == "__main__":
    unittest.main()
