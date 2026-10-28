#!/usr/bin/env python3
"""scripts/ci/delivery_workflows.py: when a nightly run may be cancelled (no network).

Leo, 2026-10-26: "SKIP THE OLD NIGHTLY BUILDS THEN WE'RE JUST BUILDING FROM THE TIP". The cancel guard read these
rules from origin/main and refused runs 40628145226, 40624308094 and 40623450445 with "not certain to fail: its
publish job may still run"; the replay below records what GitHub and git showed for them.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("delivery_workflows", ROOT / "scripts/ci/delivery_workflows.py")
dw = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["delivery_workflows"] = dw
SPEC.loader.exec_module(dw)

MAC, LINUX = "cmux-mac-mini", "blacksmith-4vcpu-ubuntu-2404"
BAD = "4b5c86ed0aefeb897c46f44957b232c864243383"
FIX = "1daea6030cb126fca4ada7e9687d2d9cc96d45f9"
TIP = "39f472b834f329401aaceb934591b74cafcf9536"
PUBLISHED = "0c8336391b32df85bcdd7db7eac2f3f0f82a54d8"


def sha(c: str) -> str:
    return (c * 40)[:40]


def run(head, *, attempt=1, status="queued", created="2026-10-28T03:00:00Z", branch="nightly-next", ident=1,
        conclusion=None):
    return {"id": ident, "path": ".github/workflows/nightly.yml", "name": "Nightly macOS build",
            "display_title": "x", "status": status, "conclusion": conclusion, "head_sha": head,
            "head_branch": branch, "event": "push", "run_attempt": attempt, "workflow_id": 234270400,
            "created_at": created, "head_repository": {"full_name": "manaflow-ai/cmux"}}


def job(name, status="completed", conclusion="success", *, labels=(LINUX,), attempt=None, runner="r",
        start="2026-10-28T03:01:00Z", end="2026-10-28T03:02:00Z"):
    out = {"name": name, "status": status, "conclusion": conclusion if status == "completed" else None,
           "labels": list(labels), "runner_name": runner if status != "queued" else None,
           "started_at": start, "completed_at": end if status == "completed" else None}
    if attempt is not None:
        out["run_attempt"] = attempt
    return out


def gates(attempt=None):
    return [job("decide", attempt=attempt), job("pick-nightly-app-runner", attempt=attempt),
            job("pick-nightly-sign-runner", "completed", "skipped", attempt=attempt),
            job("build-nightly-app", "queued", labels=(MAC,), attempt=attempt)]


def history(edges):
    """contains() over a recorded ancestry: {descendant: set of ancestors}."""
    return lambda ancestor, descendant: (ancestor == descendant or ancestor in edges.get(descendant, set())
                                         if descendant in edges else None)


class PickerAndAttemptTests(unittest.TestCase):
    def judge(self, old, jobs):
        new = run(sha("b"), created="2026-10-28T04:00:00Z", ident=2)
        return dw.superseded_unstarted(old, jobs, [old, new], lambda other: gates())

    def test_a_picker_job_that_ran_is_not_the_build(self):
        self.assertFalse(dw.is_build_job(job("pick-nightly-app-runner")))
        self.assertIsNone(dw.build_started(gates()))
        ok, why = self.judge(run(sha("a")), gates())
        self.assertTrue(ok, why)
        # The real build job is still the build.
        self.assertIn("build-nightly-app", dw.build_started([job("build-nightly-app")]) or "")

    def test_queued_attempt_one(self):
        self.assertTrue(self.judge(run(sha("a")), gates())[0])

    def test_queued_attempt_two_after_an_attempt_that_never_built(self):
        jobs = [job("decide", attempt=1), *gates(attempt=2)]
        ok, why = self.judge(run(sha("a"), attempt=2), jobs)
        self.assertTrue(ok, why)

    def test_queued_attempt_two_after_an_attempt_that_built(self):
        # A re-run of a build that ran is a new build: until a job of this attempt starts, it has not started.
        jobs = [job("build-nightly-app", "completed", "failure", labels=(MAC,), attempt=1), *gates(attempt=2)]
        ok, why = self.judge(run(sha("a"), attempt=2), jobs)
        self.assertTrue(ok, why)

    def test_a_started_build_in_this_attempt_is_kept(self):
        jobs = [*gates(attempt=2)[:-1], job("build-nightly-app", "in_progress", labels=(MAC,), attempt=2)]
        ok, why = self.judge(run(sha("a"), attempt=2, status="in_progress"), jobs)
        self.assertFalse(ok)
        self.assertIn("started", why)

    def test_a_rerun_whose_job_attempts_are_unread_is_kept(self):
        for jobs in (gates(), [*gates(attempt=2), job("decide", attempt=3)]):
            with self.subTest(jobs=jobs):
                ok, why = self.judge(run(sha("a"), attempt=2), jobs)
                self.assertFalse(ok)
                self.assertIn("attempt 2", why)


class LatestWinsTests(unittest.TestCase):
    old = run(sha("a"), status="in_progress")
    edges = {sha("c"): {sha("a")}, sha("b"): {sha("a")}}

    def judge(self, runs=(), tip=None, published=None, edges=None, tip_jobs=..., old_jobs=...):
        # `...` is the default (the gate shape); None is unread.
        return dw.never_publishes(self.old, [self.old, *runs], tip_sha=tip, published_sha=published,
                                  contains=history(self.edges if edges is None else edges),
                                  jobs=gates() if old_jobs is ... else old_jobs,
                                  jobs_of=lambda other: gates() if tip_jobs is ... else tip_jobs)

    def test_the_feed_already_has_a_newer_build(self):
        ok, why = self.judge(published=sha("c"))
        self.assertTrue(ok, why)
        self.assertIn("feed already has", why)

    def test_a_newer_tip_with_its_own_run(self):
        for status, conclusion in (("queued", None), ("in_progress", None), ("completed", "success")):
            with self.subTest(status=status):
                tip_run = run(sha("b"), status=status, conclusion=conclusion, ident=2)
                ok, why = self.judge([tip_run], tip=sha("b"))
                self.assertTrue(ok, why)
                self.assertIn(str(tip_run["id"]), why)
        rerun = run(sha("b"), ident=4, attempt=2)
        ok, why = self.judge([rerun], tip=sha("b"), tip_jobs=[job("build-nightly-app", attempt=1), *gates(attempt=2)])
        self.assertTrue(ok, why)

    def test_kept(self):
        failed = run(sha("b"), status="completed", conclusion="failure", ident=2)
        other_branch = run(sha("b"), branch="main", ident=3)
        cases = {
            "the tip is its head": dict(runs=[run(sha("a"), ident=2)], tip=sha("a")),
            "the tip has no run": dict(tip=sha("b")),
            "the tip's run failed": dict(runs=[failed], tip=sha("b")),
            "the tip's run is elsewhere": dict(runs=[other_branch], tip=sha("b")),
            "the tip is unread": dict(runs=[run(sha("b"), ident=2)], tip=None),
            "the ancestry is unread": dict(runs=[run(sha("b"), ident=2)], tip=sha("b"), edges={}),
            "the tip is not after it": dict(runs=[run(sha("b"), ident=2)], tip=sha("b"), edges={sha("b"): set()}),
            "the feed is older": dict(published=sha("d"), edges={sha("d"): set()}),
            "the tip run skipped the build": dict(runs=[run(sha("b"), ident=2)], tip=sha("b"), tip_jobs=[
                *gates()[:-1], job("build-nightly-app", "completed", "skipped")]),
            "the tip run's build failed": dict(runs=[run(sha("b"), ident=2)], tip=sha("b"), tip_jobs=[
                *gates()[:-1], job("build-nightly-app", "completed", "failure")]),
            "the tip run's jobs are unread": dict(runs=[run(sha("b"), ident=2)], tip=sha("b"), tip_jobs=None),
            "its own jobs are unread": dict(runs=[run(sha("b"), ident=2)], tip=sha("b"), old_jobs=None),
            "the tip re-run built only in an earlier attempt": dict(
                runs=[run(sha("b"), ident=2, attempt=2)], tip=sha("b"),
                tip_jobs=[job("build-nightly-app", attempt=1), job("decide", attempt=2)]),
            "the tip re-run's job attempts are unread": dict(runs=[run(sha("b"), ident=2, attempt=2)], tip=sha("b")),
            "its head repository is unread": dict(runs=[{**run(sha("b"), ident=2), "head_repository": None}],
                                                  tip=sha("b")),
        }
        for label, kwargs in cases.items():
            with self.subTest(label):
                self.assertFalse(self.judge(**kwargs)[0])
        unread_repo = {**self.old, "head_repository": None}
        self.assertFalse(dw.never_publishes(unread_repo, [unread_repo, {**run(sha("b"), ident=2), "head_repository": None}],
                                            tip_sha=sha("b"), published_sha=None, contains=history(self.edges),
                                            jobs=gates(), jobs_of=lambda other: gates())[0])
        main = {**self.old, "head_branch": "main"}
        self.assertFalse(dw.never_publishes(main, [], tip_sha=sha("b"), published_sha=sha("c"),
                                            contains=history(self.edges))[0])
        self.assertFalse(dw.never_publishes({**self.old, "status": "completed"}, [], tip_sha=sha("b"),
                                            published_sha=sha("c"), contains=history(self.edges))[0])

    def test_published_marker(self):
        self.assertEqual(dw.published_commit(f"notes\n<!-- cmux-published-sha: {PUBLISHED} -->"), PUBLISHED)
        self.assertIsNone(dw.published_commit("no marker"))
        self.assertEqual(dw.latest_wins_feed(self.old), "nightly-next")


class KnownBadTests(unittest.TestCase):
    def entries(self):
        return dw.known_bad_entries((ROOT / dw.KNOWN_BAD_PATH).read_text())

    def test_the_checked_in_list_is_well_formed_and_seeded(self):
        entries = self.entries()
        self.assertIsNotNone(entries)
        self.assertIn({"bad_since": BAD, "fixed_by": FIX, "reason": "Home first-run NSStackView crash at launch",
                       "filed_by": "teamleaderleo"}, entries)

    def test_malformed_lists_are_unread(self):
        good = {"bad_since": BAD, "fixed_by": None, "reason": "r", "filed_by": "f"}
        for broken in ("", "[]", "{}", json.dumps({"entries": [{**good, "bad_since": "4b5c86ed"}]}),
                       json.dumps({"entries": [{**good, "reason": " "}]}),
                       json.dumps({"entries": [{**good, "extra": 1}]})):
            with self.subTest(broken=broken):
                self.assertIsNone(dw.known_bad_entries(broken))
        self.assertEqual(dw.known_bad_entries(json.dumps({"entries": [good]})), [good])

    def test_a_head_with_the_bad_commit_and_without_its_fix_is_certain_to_fail(self):
        head = sha("a")
        entry, why = dw.known_bad(run(head), self.entries(), history({head: {BAD}}))
        self.assertIsNotNone(entry, why)
        self.assertIn("certain to fail", why)

    def test_kept(self):
        head = sha("a")
        cases = {"fixed": {head: {BAD, FIX}}, "never bad": {head: set()}, "unread": {}}
        for label, edges in cases.items():
            with self.subTest(label):
                self.assertIsNone(dw.known_bad(run(head), self.entries(), history(edges))[0])
        not_fixed = [{"bad_since": BAD, "fixed_by": None, "reason": "r", "filed_by": "f"}]
        self.assertIsNotNone(dw.known_bad(run(head), not_fixed, history({head: {BAD}}))[0])
        dev = {**run(head), "path": ".github/workflows/cmux-next-dev-daily.yml"}
        self.assertIsNone(dw.known_bad(dev, self.entries(), history({head: {BAD}}))[0])
        self.assertIsNone(dw.known_bad(run(head), None, history({head: {BAD}}))[0])


class LiveReplayTests(unittest.TestCase):
    """Runs the guard refused on 2026-10-28. Recorded: each head contains BAD and lacks FIX (git merge-base
    --is-ancestor), the nightly-next tip was TIP with run 40631810292 done, and the feed had PUBLISHED, which
    precedes all three."""

    HEADS = {40628145226: ("d7cf72ee56554e2bbefeb3ac71ea158aea7b4b35", 2, "2026-10-28T03:41:43Z"),
             40624308094: ("9fc2bb455930926cc3bc42f785f5b4f13dfc70f1", 3, "2026-10-28T03:01:35Z"),
             40623450445: ("2aafb0fcdee5de336881214697cc35263992d0aa", 3, "2026-10-28T02:52:23Z")}

    # The tip run 40631810292 skipped its build (decide chose no build), so latest-wins by the tip does not
    # apply; the feed (PUBLISHED) precedes all three heads. The known-bad list is what allows them.

    def setUp(self):
        heads = [head for head, _, _ in self.HEADS.values()]
        self.contains = history({**{h: {BAD, PUBLISHED} for h in heads}, TIP: {BAD, PUBLISHED, *heads},
                                 PUBLISHED: {BAD}})
        self.tip_run = run(TIP, status="completed", conclusion="success", ident=40631810292,
                           created="2026-10-28T04:20:54Z")

    def test_all_three_are_allowed(self):
        entries = dw.known_bad_entries((ROOT / dw.KNOWN_BAD_PATH).read_text())
        for ident, (head, attempt, created) in self.HEADS.items():
            with self.subTest(run=ident):
                live = run(head, attempt=attempt, status="in_progress", created=created, ident=ident)
                entry, why = dw.known_bad(live, entries, self.contains)
                self.assertIsNotNone(entry, why)
                own = [{**j, "run_attempt": attempt} for j in gates()]
                skipped = [{**j, "status": "completed", "conclusion": "skipped" if j["name"] != "decide" else "success"}
                           for j in gates()]
                ok, why = dw.never_publishes(live, [live, self.tip_run], tip_sha=TIP, published_sha=PUBLISHED,
                                             contains=self.contains, jobs=own, jobs_of=lambda other: skipped)
                self.assertFalse(ok)
                self.assertIn("does not show the same build", why)
                ok, why = dw.never_publishes(live, [live, self.tip_run], tip_sha=TIP, published_sha=PUBLISHED,
                                             contains=self.contains, jobs=own,
                                             jobs_of=lambda other: [{**j, "status": "completed", "conclusion": "success"}
                                                                    for j in gates()])
                self.assertTrue(ok, why)


if __name__ == "__main__":
    unittest.main()
