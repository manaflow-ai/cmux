#!/usr/bin/env python3
"""The fix-forward after a feed pull (scripts/ci/nightly_next_fix_forward.py,
nightly-next-rollback.yml job fix-forward)."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_next_fix_forward.py"
spec = importlib.util.spec_from_file_location("fix_forward", SCRIPT)
ff = importlib.util.module_from_spec(spec)
sys.modules["fix_forward"] = ff
spec.loader.exec_module(ff)

REPO = "manaflow-ai/cmux"
GOOD, BAD, NEWER = "3947349329001", "3947430561301", "3947500000001"
GOOD_SHA, BAD_SHA, CAR_SHA, NIGHTLY_HEAD = "a" * 40, "b" * 40, "c" * 40, "d" * 40

TRAIN = """name: nightly-next train
on:
  workflow_dispatch:
    inputs:
      pulled_build:
        description: x
        type: string
      good_build:
        type: string
      quarantine:
        type: string
        # nested keys are not inputs
      reason:
        type: string
      train:
        type: string
  push:
    branches: [x]
jobs: {}
"""


class FakeApi:
    def __init__(self, train: str | None = TRAIN, train_commit: bool = False, open_issue: int | None = None):
        self.train, self.train_commit, self.open_issue = train, train_commit, open_issue
        self.run_repo, self.run_extra = REPO, {}
        self.writes: list[tuple[str, str, dict]] = []

    def __call__(self, path, method="GET", fields=None, raw=False):
        if method != "GET":
            self.writes.append((method, path, dict(fields or {})))
            return {"number": 77} if path.endswith("/issues") else None
        if m := re.fullmatch(r"repos/[^/]+/[^/]+/actions/runs/(\d+)", path):
            run = {"39473493290": GOOD_SHA, "39474305613": BAD_SHA}.get(m.group(1))
            if run is None:
                raise RuntimeError("HTTP 404")
            return {"head_branch": "nightly-next", "head_sha": run, "event": "push",
                    "head_repository": {"full_name": self.run_repo}, **self.run_extra}
        if path.endswith(f"commits/{BAD_SHA}"):
            parents = [{"sha": NIGHTLY_HEAD}, {"sha": CAR_SHA}] if self.train_commit else [{"sha": GOOD_SHA}]
            return {"parents": parents, "author": {"login": "pusher"}, "commit": {"message": "direct push\n\nbody"}}
        if path.endswith(f"commits/{CAR_SHA}"):
            return {"parents": [{"sha": GOOD_SHA}], "author": {"login": "carauthor"}, "commit": {"message": "feat: car (#22590)"}}
        if path.endswith("/pulls"):
            if CAR_SHA in path:
                return [{"number": 22590, "merged_at": "2026-10-20T00:00:00Z", "user": {"login": "teamleaderleo"}}]
            return []
        if "contents/.github/workflows/nightly-next-train.yml" in path:
            assert raw
            if self.train is None:
                raise RuntimeError("HTTP 404")
            return self.train
        if path == "search/issues":
            items = [{"number": self.open_issue, "title": ff.ISSUE_TITLE}] if self.open_issue else []
            return {"items": items}
        raise AssertionError(f"unexpected GET {path}")


def go(api, pulled=(BAD, NEWER), dry=False):
    return ff.run(api, REPO, list(pulled), GOOD, "build failed the canary", "feat-cmux-next", "https://run", dry)


class Tests(unittest.TestCase):
    def test_declared_inputs_reads_only_dispatch_inputs(self):
        self.assertEqual(ff.declared_inputs(TRAIN), {"pulled_build", "good_build", "quarantine", "reason", "train"})
        self.assertEqual(ff.declared_inputs("on:\n  workflow_dispatch:\n"), set())

    def test_build_number_maps_to_its_run(self):
        self.assertEqual(ff.build_run(BAD), "39474305613")
        with self.assertRaises(ValueError):
            ff.build_run("12x")

    def test_a_fork_or_pull_request_run_is_no_nightly_next_build(self):
        # A fork's pull_request run on a branch named nightly-next reports the
        # same head_branch; its commit must never become the train's base.
        api = FakeApi()
        self.assertEqual(ff.build_commit(api, REPO, BAD), BAD_SHA)
        api.run_repo = "someone/cmux"
        self.assertIsNone(ff.build_commit(api, REPO, BAD))
        api.run_repo, api.run_extra = REPO, {"event": "pull_request"}
        self.assertIsNone(ff.build_commit(api, REPO, BAD))

    def test_dispatches_the_train_with_the_newest_car_quarantined(self):
        api = FakeApi(train_commit=True)
        plan = go(api)
        self.assertEqual(plan["pulled_build"], BAD, "the oldest pulled build is the first bad one")
        self.assertEqual((plan["good_commit"], plan["bad_commit"]), (GOOD_SHA, BAD_SHA))
        self.assertEqual(plan["suspect"], {"sha": CAR_SHA, "subject": "feat: car (#22590)", "pr": 22590, "owner": "teamleaderleo"})
        [(method, path, fields)] = api.writes
        self.assertEqual((method, path), ("POST", f"repos/{REPO}/actions/workflows/nightly-next-train.yml/dispatches"))
        self.assertEqual(fields, {"ref": "feat-cmux-next", "inputs[pulled_build]": BAD, "inputs[good_build]": GOOD,
                                  "inputs[quarantine]": CAR_SHA, "inputs[reason]": "build failed the canary"})

    def test_passes_only_inputs_the_train_declares(self):
        api = FakeApi(train=TRAIN.replace("      quarantine:\n        type: string\n        # nested keys are not inputs\n", ""))
        go(api)
        self.assertNotIn("inputs[quarantine]", api.writes[0][2])

    def test_a_direct_push_is_its_own_car(self):
        plan = go(FakeApi(), dry=True)
        self.assertEqual(plan["suspect"], {"sha": BAD_SHA, "subject": "direct push", "pr": None, "owner": "pusher"})

    def test_no_train_yet_opens_one_issue(self):
        api = FakeApi(train=None)
        plan = go(api)
        self.assertIn("not on feat-cmux-next yet", plan["action"]["why"])
        [(method, path, fields)] = api.writes
        self.assertEqual((method, path, fields["title"]), ("POST", f"repos/{REPO}/issues", ff.ISSUE_TITLE))
        self.assertIn(f"compare/{GOOD_SHA}...{BAD_SHA}", fields["body"])
        self.assertIn(f"cmux NEXT build {BAD} was pulled", fields["body"])

    def test_an_open_issue_gets_a_comment(self):
        api = FakeApi(train=None, open_issue=12)
        plan = go(api)
        self.assertEqual(api.writes[0][:2], ("POST", f"repos/{REPO}/issues/12/comments"))
        self.assertEqual(plan["action"]["number"], 12)

    def test_a_train_that_cannot_fix_forward_falls_back_to_the_issue(self):
        api = FakeApi(train="on:\n  workflow_dispatch:\n    inputs:\n      train:\n        type: string\n")
        plan = go(api)
        self.assertIn("no pulled_build input", plan["action"]["why"])
        self.assertTrue(api.writes[0][1].endswith("/issues"))

    def test_a_build_without_a_run_here_falls_back(self):
        api = FakeApi()
        plan = ff.run(api, REPO, ["3999999999901"], GOOD, "r", "feat-cmux-next", "u", False)
        self.assertIsNone(plan["bad_commit"])
        self.assertIn("no suspect car", plan["action"]["why"])
        self.assertIn("unknown", api.writes[0][2]["body"])

    def test_dry_run_writes_nothing(self):
        for api in (FakeApi(), FakeApi(train=None)):
            go(api, dry=True)
            self.assertEqual(api.writes, [])

    def test_bad_inputs_are_refused(self):
        with self.assertRaises(ValueError):
            ff.run(FakeApi(), REPO, [], GOOD, "r", "feat-cmux-next", "u", True)


class WiringTests(unittest.TestCase):
    text = (ROOT / ".github/workflows/nightly-next-rollback.yml").read_text()

    def test_every_real_pull_starts_the_fix_forward(self):
        job = self.text[self.text.index("\n  fix-forward:\n"):]
        self.assertIn("needs: rollback", job)
        self.assertIn("needs.rollback.outputs.changed == 'true' && !inputs.dry_run", job)
        self.assertIn("scripts/ci/nightly_next_fix_forward.py run", job)
        self.assertIn("actions: write", job)
        self.assertNotIn("environment:", job, "the fix-forward holds no feed secrets")
        self.assertNotIn("secrets.", job)
        for out in ("changed", "serving", "pulled"):
            self.assertIn(f"{out}: ${{{{ steps.plan.outputs.{out} }}}}", self.text)


if __name__ == "__main__":
    unittest.main()
