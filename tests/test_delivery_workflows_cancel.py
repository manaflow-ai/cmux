#!/usr/bin/env python3
"""scripts/ci/delivery_workflows.py: when a nightly run may be cancelled (no network).

Leo, 2026-10-26: "SKIP THE OLD NIGHTLY BUILDS THEN WE'RE JUST BUILDING FROM THE TIP". The cancel guard read these
rules from origin/main and refused runs 40628145226, 40624308094 and 40623450445 with "not certain to fail: its
publish job may still run"; the replay below records what GitHub and git showed for them.
"""

from __future__ import annotations

import importlib.util
import json
import re
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


def building(attempt=None):
    """A newer run's jobs with its app build running."""
    return [*gates(attempt)[:-1], job("build-nightly-app", "in_progress", labels=(MAC,), attempt=attempt)]


NOW = dw._time("2026-10-28T05:00:00Z")


class PickerAndAttemptTests(unittest.TestCase):
    def judge(self, old, jobs):
        new = run(sha("b"), created="2026-10-28T04:00:00Z", ident=2)
        return dw.superseded_unstarted(old, jobs, [old, new], lambda other: building(), now=NOW, tip_sha=sha("b"))

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


# Build, sign and publish work in a job's steps: a light job (LIGHT_JOBS) has none.
BUILD_WORK = re.compile(r"xcodebuild|\bswift build\b|\bcargo build\b|\bcodesign\b|notarytool|rcodesign|\bstapler\b"
                        r"|\bgh release (?:create|upload|edit)\b|\bgit push\b")


def workflow_jobs(text: str) -> dict[str, list[str]]:
    """Each top-level job id of a workflow file and its lines, comments dropped."""
    out: dict[str, list[str]] = {}
    current, inside = None, False
    for line in text.splitlines():
        if re.match(r"^jobs:\s*$", line):
            inside = True
            continue
        if inside and re.match(r"^\S", line):
            inside, current = False, None
        if not inside:
            continue
        found = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if found:
            current = found.group(1)
            out[current] = []
        elif current and not line.strip().startswith("#"):
            out[current].append(line)
    return out


def at(minute: int) -> str:
    """2026-10-28T19:MM:00Z (minutes past 19:00; may run past 59)."""
    return (dw._time("2026-10-28T19:00:00Z") + dw._dt.timedelta(minutes=minute)).strftime("%Y-%m-%dT%H:%M:%SZ")


def replay_40752120475(*, signer=True):
    """Run 40752120475 (nightly-next push, created 19:11:58Z) as GitHub listed it when the guard refused its cancel
    at 19:54:57Z: decide ran on a Blacksmith Mac, signer-build ran on Linux, and the two control jobs after decide
    waited on blacksmith-6vcpu-macos-26 from 19:30:53Z with no runner; the build jobs were not listed yet."""
    mac, linux = "blacksmith-6vcpu-macos-26", "blacksmith-8vcpu-ubuntu-2404"
    jobs = [job("decide", labels=(mac,), start="2026-10-28T19:29:50Z", end="2026-10-28T19:30:52Z"),
            job("promote-nightly-next", "completed", "skipped", start="2026-10-28T19:11:59Z", end="2026-10-28T19:11:59Z"),
            job("probe-nightly-tag-permission", "completed", "skipped", labels=(), start="2026-10-28T19:11:59Z", end="2026-10-28T19:11:59Z"),
            job("find-nightly-next-recovery", "queued", labels=(mac,), start="2026-10-28T19:30:53Z"),
            job("resolve-nightly-cmux-tui-client", "queued", labels=(mac,), start="2026-10-28T19:30:53Z"),
            job("refresh-test-compilation-cache", "completed", "skipped", labels=(), start="2026-10-28T19:30:53Z", end="2026-10-28T19:30:53Z"),
            job("refresh-compilation-cache", "completed", "skipped", labels=(mac,), start="2026-10-28T19:30:53Z", end="2026-10-28T19:30:53Z")]
    if signer:
        jobs.append(job("signer-build", labels=(linux,), start="2026-10-28T19:32:16Z", end="2026-10-28T19:34:02Z"))
    return run("14b20f800934bc61c9b162e76df164693b795fe3", created="2026-10-28T19:11:58Z", ident=40752120475), jobs


class DeliveryRunTests(unittest.TestCase):
    """delivers(): dep-fleet's ruling (#27521) protects runs that publish, sign, roll back or file things, never a
    pull request's test run of a nightly-named workflow."""

    CANARY = ".github/workflows/nightly-next-canary.yml"
    SMOKE = ".github/workflows/nightly-next-launch-smoke.yml"

    def test_a_pull_request_run_of_a_post_publish_check_is_no_delivery_run(self):
        for path in (self.CANARY, self.SMOKE):
            for event in ("pull_request", "pull_request_target", "merge_group"):
                with self.subTest(path=path, event=event):
                    self.assertTrue(dw.is_delivery_run(path))
                    self.assertFalse(dw.delivers(path, event))

    def test_scheduled_dispatched_and_pushed_delivery_runs_still_deliver(self):
        for path in (self.CANARY, self.SMOKE, ".github/workflows/nightly.yml", ".github/workflows/nightly-sign.yml",
                     ".github/workflows/nightly-next-rollback.yml", ".github/workflows/cmux-next-dev-daily.yml"):
            for event in ("schedule", "workflow_dispatch", "push", "workflow_run"):
                with self.subTest(path=path, event=event):
                    self.assertTrue(dw.delivers(path, event))

    def test_an_unread_event_keeps_the_protection(self):
        for event in (None, ""):
            self.assertTrue(dw.delivers(self.CANARY, event))

    def test_the_dev_build_counts_by_run_name_and_ordinary_workflows_never_do(self):
        dev = "cmux NEXT DEV daily · abc"
        self.assertTrue(dw.delivers(".github/workflows/cmux-next.yml", "workflow_dispatch", dev))
        self.assertFalse(dw.delivers(".github/workflows/cmux-next.yml", "workflow_dispatch", "cmux-next"))
        self.assertFalse(dw.delivers(".github/workflows/ci.yml", "schedule"))


class StaleRuleTests(unittest.TestCase):
    """sr2, 2026-10-28: "count a nightly, dev or promote run as stale, and so cancellable, only when all of these
    hold: 1. every job except light control jobs and decide jobs is still queued for a runner; 2. it has waited at
    least 20 min; 3. a newer tip run is already building. A run with any build, sign or publish job started stays
    protected. So does the 25-min freshness rule"."""

    def stale(self, *, jobs=None, newer_jobs=None, now=at(60), newer=True, tip=sha("b"), old=None):
        old = old or run(sha("a"), created=at(0), ident=1)
        new = run(sha("b"), status="in_progress", created=at(10), ident=2)
        jobs = jobs if jobs is not None else [
            job("decide", labels=("blacksmith-6vcpu-macos-26",), start=at(1), end=at(2)),
            job("resolve-nightly-cmux-tui-client", start=at(2), end=at(4)),
            job("pick-nightly-build-runner", start=at(4), end=at(5)),
            job("build-nightly-app", "queued", labels=(MAC,), start=at(5)),
            job("signer-build", "queued", start=at(2))]
        theirs = newer_jobs if newer_jobs is not None else [
            job("decide", start=at(11), end=at(12)), job("resolve-nightly-cmux-tui-client", start=at(12), end=at(13)),
            job("pick-nightly-build-runner", start=at(13), end=at(14)),
            job("build-nightly-app", "in_progress", labels=(MAC,), start=at(14)),
            job("signer-build", start=at(12), end=at(14))]
        return dw.superseded_unstarted(old, jobs, [old, new] if newer else [old], lambda other: theirs,
                                       now=dw._time(now), tip_sha=tip)

    def test_only_control_and_decide_done_long_queued_and_a_newer_tip_building_is_stale(self):
        ok, why = self.stale()
        self.assertTrue(ok, why)
        for part in ("(1)", "(2) it has waited 55 min", "(3) run 2 is building the tip"):
            self.assertIn(part, why)

    def test_an_unread_or_moved_tip_is_protected(self):
        for tip in (None, ""):
            ok, why = self.stale(tip=tip)
            self.assertFalse(ok)
            self.assertIn("tip of nightly-next could not be read", why)
        # A newer run that is not at the tip does not count: the tip itself must be building.
        ok, why = self.stale(tip=sha("d"))
        self.assertFalse(ok)
        self.assertIn("condition 3 fails: no newer head of nightly-next at its tip", why)

    def test_a_job_without_a_readable_start_is_unread(self):
        jobs = [job("decide", start=at(1), end=at(2)), job("build-nightly-app", "queued", labels=(MAC,), start=None)]
        ok, why = self.stale(jobs=jobs)
        self.assertFalse(ok)
        self.assertIn("how long it has waited could not be read", why)

    def test_the_default_wait_is_20_minutes(self):
        self.assertEqual(dw.STALE_WAIT, dw._dt.timedelta(minutes=20))
        self.assertTrue(self.stale(now=at(25))[0])
        ok, why = self.stale(now=at(24))
        self.assertFalse(ok)
        self.assertIn("condition 2 fails: it has waited 19 min", why)

    def test_a_started_build_sign_or_publish_job_is_protected(self):
        for started in (job("build-nightly-app", "in_progress", labels=(MAC,), start=at(5)),
                        job("build-nightly-app", "queued", labels=(MAC,), start=at(5)) | {"runner_name": "mini-1"},
                        job("signer-build", start=at(2), end=at(4)),
                        job("build-sign-notarize-nightly", "in_progress", labels=(MAC,), start=at(5)),
                        job("publish-nightly", "completed", "failure", start=at(5), end=at(6)),
                        job("build nightly inputs", start=at(2), end=at(3))):
            with self.subTest(job=started["name"], status=started["status"]):
                jobs = [job("decide", start=at(1), end=at(2)), started]
                ok, why = self.stale(jobs=jobs)
                self.assertFalse(ok)
                self.assertIn("condition 1 fails", why)
                self.assertIn(started["name"], why)

    def test_no_newer_tip_building_is_protected(self):
        queued = [job("decide", start=at(11), end=at(12)), job("build-nightly-app", "queued", labels=(MAC,), start=at(12))]
        failed = [job("decide", start=at(11), end=at(12)),
                  job("build-nightly-app", "completed", "failure", labels=(MAC,), start=at(12), end=at(20))]
        cache_only = [job("decide", start=at(11), end=at(12)),
                      job("refresh-compilation-cache", "in_progress", labels=(MAC,), start=at(12)),
                      job("build-nightly-app", "completed", "skipped", labels=(MAC,), start=at(12), end=at(12))]
        # An old run with only decide done is not replaced by a tip that only refreshes a cache on a Mac.
        only_decide = [job("decide", start=at(1), end=at(2))]
        ok, why = self.stale(jobs=only_decide, newer_jobs=cache_only)
        self.assertFalse(ok)
        self.assertIn("no build job of it is running or has run", why)
        for label, kwargs in {"no newer run": dict(newer=False), "the newer run is queued too": dict(newer_jobs=queued),
                              "the newer run's build failed": dict(newer_jobs=failed),
                              "the newer run only refreshes a cache": dict(newer_jobs=cache_only)}.items():
            with self.subTest(label):
                ok, why = self.stale(**kwargs)
                self.assertFalse(ok)
                self.assertIn("condition 3 fails", why)

    def test_the_newest_tip_is_protected_by_the_freshness_rule(self):
        ok, why = self.stale(tip=sha("a"))
        self.assertFalse(ok)
        self.assertIn("freshness rule", why)
        # The newest head's own run, at the tip, is never stale either.
        newest = run(sha("b"), status="in_progress", created=at(10), ident=2)
        ok, why = dw.superseded_unstarted(newest, [job("decide", start=at(11), end=at(12))], [newest],
                                          lambda other: [], now=dw._time(at(60)), tip_sha=sha("b"))
        self.assertFalse(ok)
        self.assertIn("freshness rule", why)

    def test_light_jobs_are_declared_once_and_match_patterns(self):
        for name in ("decide", "pick-nightly-app-runner", "pick-nightly-sign-runner (primary)",
                     "resolve-nightly-cmux-tui-client", "find-nightly-next-recovery", "probe-nightly-tag-permission"):
            self.assertTrue(dw.is_light_job(name), name)
        # Exact names only: a new job that merely looks like a control job is not light until it is listed.
        for name in ("build-nightly-app", "signer-build", "build nightly inputs", "publish-nightly",
                     "build-sign-notarize-nightly", "promote-nightly-next", "refresh-compilation-cache",
                     "resolve-signing-artifact", "probe-and-publish", "pick-up-signed-app", "decide-and-sign"):
            self.assertFalse(dw.is_light_job(name), name)
            self.assertIsNotNone(dw.build_started([job(name, "in_progress")]), name)

    def test_light_jobs_do_no_build_sign_or_publish_work_in_any_delivery_workflow(self):
        seen = set()
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            if not dw.is_delivery_workflow(path.name):
                continue
            for ident, lines in workflow_jobs(path.read_text()).items():
                if not dw.is_light_job(ident):
                    continue
                seen.add(ident)
                work = [line.strip() for line in lines if BUILD_WORK.search(line)]
                self.assertEqual(work, [], f"{path.name} job {ident} matches LIGHT_JOBS but builds, signs or publishes")
        self.assertIn("decide", seen)

    def test_replay_40752120475(self):
        # As refused (19:54:57Z): signer-build, a build job, had run, so the run stays protected, now for that
        # reason and not for decide's Mac.
        old, jobs = replay_40752120475()
        new = run(sha("c"), status="in_progress", created="2026-10-28T19:40:00Z", ident=2)
        theirs = [job("decide", start=at(41), end=at(42)), job("find-nightly-next-recovery", start=at(42), end=at(43)),
                  job("resolve-nightly-cmux-tui-client", start=at(42), end=at(44)),
                  job("signer-build", start=at(42), end=at(44)),
                  job("build-nightly-app", "in_progress", labels=(MAC,), start=at(45))]
        when = dw._time("2026-10-28T19:54:57Z")
        ok, why = dw.superseded_unstarted(old, jobs, [old, new], lambda other: theirs, now=when, tip_sha=sha("c"))
        self.assertFalse(ok)
        self.assertIn("'signer-build'", why)
        self.assertNotIn("Mac", why)
        # Without signer-build: only decide (on a Mac) and the control jobs, queued 24 min, a newer run building.
        old, jobs = replay_40752120475(signer=False)
        ok, why = dw.superseded_unstarted(old, jobs, [old, new], lambda other: theirs, now=when, tip_sha=sha("c"))
        self.assertTrue(ok, why)
        self.assertIn("waited 24 min", why)



# --- DEV publish runs a newer publish covered (2026-10-31: 115 queued, oldest 37 h) ----------------------------
DEV_NOW = dw._dt.datetime(2026, 10, 31, 5, 0, tzinfo=dw._dt.timezone.utc)
OLD_SRC, NEW_SRC = sha("a"), sha("b")


def dev_run(source, *, ident=10, status="queued", conclusion=None, created="2026-10-29T15:34:57Z", attempt=1):
    return {"id": ident, "path": ".github/workflows/cmux-next-dev-daily.yml",
            "name": f"cmux NEXT DEV daily · publish {source}", "display_title": f"cmux NEXT DEV daily · publish {source}",
            "status": status, "conclusion": conclusion, "head_sha": sha("m"), "head_branch": "main",
            "event": "workflow_dispatch", "run_attempt": attempt, "created_at": created}


def dev_waiting_jobs(mac="blacksmith-12vcpu-macos-26"):
    early = "2026-10-29T15:40:00Z"
    return [job("Build the signer", start=early, end=early), job("Sign cmux NEXT DEV", start=early, end=early),
            job("runner", start=early, end=early),
            job("Verify signed cmux NEXT DEV", "queued", labels=(mac,), start=early),
            job("Build the unsigned cmux NEXT DEV tip DMG", "queued", labels=(mac,), start=early)]


def dev_published_jobs():
    return [*[job(n) for n in ("Build the signer", "Sign cmux NEXT DEV", "runner", "Verify signed cmux NEXT DEV",
                                "Build the unsigned cmux NEXT DEV tip DMG", "Publish cmux NEXT DEV")],
            job("Publish the cmux NEXT DEV tip feed", "completed", "skipped")]


class DevPublishSupersededTests(unittest.TestCase):
    def decide(self, run=None, jobs=None, *, newer=None, newer_jobs=None, old=OLD_SRC, new=NEW_SRC, contains=True):
        run = run or dev_run(100)
        newer = newer or dev_run(200, ident=20, status="completed", conclusion="success")
        return dw.dev_publish_superseded(
            run, dev_waiting_jobs() if jobs is None else jobs, source_sha=old, newer=newer,
            newer_jobs=dev_published_jobs() if newer_jobs is None else newer_jobs, newer_source_sha=new,
            contains=lambda a, b: contains, now=DEV_NOW)

    def test_a_publish_run_waiting_on_a_mac_behind_a_newer_published_source_is_superseded(self):
        ok, why = self.decide()
        self.assertTrue(ok, why)
        self.assertIn("certain not to publish", why)

    def test_the_source_id_comes_from_the_title_only_for_the_dev_publisher(self):
        self.assertEqual(dw.dev_publish_source(dev_run(41153639573)), 41153639573)
        self.assertIsNone(dw.dev_publish_source({**dev_run(5), "path": ".github/workflows/nightly.yml"}))
        self.assertIsNone(dw.dev_publish_source({**dev_run(5), "name": "cmux NEXT DEV daily", "display_title": ""}))

    def test_a_started_mac_job_keeps_it(self):
        jobs = dev_waiting_jobs()
        jobs[3] = job("Verify signed cmux NEXT DEV", "in_progress", labels=("glaeda-std-xcode-26.6",),
                      start="2026-10-29T15:40:00Z")
        ok, why = self.decide(jobs=jobs)
        self.assertFalse(ok)
        self.assertIn("running", why)

    def test_a_queued_mac_job_a_runner_took_keeps_it(self):
        jobs = dev_waiting_jobs()
        jobs[3]["runner_name"] = "cmux9s-mac-mini-glaeda"
        self.assertFalse(self.decide(jobs=jobs)[0])

    def test_a_running_or_finished_publish_job_keeps_it(self):
        jobs = [*dev_waiting_jobs(), job("Publish cmux NEXT DEV", "in_progress", start="2026-10-29T15:40:00Z")]
        ok, why = self.decide(jobs=jobs)
        self.assertFalse(ok)
        self.assertIn("running", why)
        early = "2026-10-29T15:40:00Z"
        jobs = [*dev_waiting_jobs(), job("Publish cmux NEXT DEV", "completed", "failure", start=early, end=early)]
        ok, why = self.decide(jobs=jobs)
        self.assertFalse(ok)
        self.assertIn("Publish job has run", why)

    def test_a_finished_tip_dmg_with_verify_still_waiting_is_superseded(self):
        # Run 40946510427 on 2026-10-31: its tip DMG built on a Mac; Verify had waited on a Mac since.
        early = "2026-10-29T15:40:00Z"
        jobs = dev_waiting_jobs()
        jobs[4] = job("Build the unsigned cmux NEXT DEV tip DMG", labels=("blacksmith-6vcpu-macos-26",),
                      start=early, end=early)
        jobs.append(job("Sign, notarize and staple the cmux NEXT DEV tip DMG", start=early, end=early))
        ok, why = self.decide(jobs=jobs)
        self.assertTrue(ok, why)

    def test_a_recent_run_keeps_it(self):
        jobs = [job(j["name"], j["status"], j["conclusion"] or "success", labels=j["labels"],
                    start="2026-10-31T04:50:00Z", end="2026-10-31T04:50:00Z") for j in dev_waiting_jobs()]
        ok, why = self.decide(run=dev_run(100, created="2026-10-31T04:45:00Z"), jobs=jobs)
        self.assertFalse(ok)
        self.assertIn("condition 2", why)

    def test_a_newer_run_that_did_not_publish_keeps_it(self):
        jobs = dev_published_jobs()
        jobs[5] = job("Publish cmux NEXT DEV", "completed", "skipped")
        self.assertFalse(self.decide(newer_jobs=jobs)[0])
        failed = dev_run(200, ident=20, status="completed", conclusion="failure")
        self.assertFalse(self.decide(newer=failed)[0])

    def test_an_older_or_equal_winner_keeps_it(self):
        ok, why = self.decide(run=dev_run(300))
        self.assertFalse(ok)
        self.assertIn("later source run", why)

    def test_unread_or_unrelated_sources_keep_it(self):
        self.assertFalse(self.decide(contains=None)[0])
        self.assertFalse(self.decide(contains=False)[0])
        self.assertFalse(self.decide(old="")[0])
        self.assertTrue(self.decide(old=NEW_SRC, new=NEW_SRC, contains=None)[0])  # the same commit

    def test_unread_jobs_or_a_finished_run_keep_it(self):
        run = dev_run(100)
        self.assertFalse(dw.dev_publish_superseded(run, None, source_sha=OLD_SRC, newer=None, newer_jobs=None,
                                                   newer_source_sha=None, contains=lambda a, b: True, now=DEV_NOW)[0])
        self.assertFalse(self.decide(run=dev_run(100, status="completed", conclusion="cancelled"))[0])
        self.assertFalse(dw.dev_publish_superseded(run, dev_waiting_jobs(), source_sha=OLD_SRC, newer=None,
                                                   newer_jobs=None, newer_source_sha=NEW_SRC,
                                                   contains=lambda a, b: True, now=DEV_NOW)[0])

    def test_the_publish_job_and_title_match_the_workflow(self):
        text = (ROOT / ".github/workflows/cmux-next-dev-daily.yml").read_text()
        names = set(re.findall(r"^    name: (.+)$", text, re.MULTILINE))
        self.assertIn(dw.DEV_PUBLISH_JOB, names)
        self.assertRegex(text, r"cmux NEXT DEV daily · publish \{0\}")


if __name__ == "__main__":
    unittest.main()
