#!/usr/bin/env python3
"""scripts/ci/nightly_next_supersede.py and scripts/ci/nightly_now.py (no network).

2026-11-10/11: push runs 42925854615 and 42929616529, then sign run 42930383771, held nightly-next's push and
sign groups for hours with every remaining job queued on a runner label that had gone; tip runs 42945365476,
42947517129 and 42948266530 were each replaced while pending and never started. Leo: "aren't there things we
can just be like 'ok just get this one in asap'".

The rule reads main's scripts/ci/delivery_workflows.py (the stale rule's one definition): NIGHTLY_RULES_PY
names a copy of it (ci-guards.yml fetches main's), else `git show origin/main:` from this checkout.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import nightly_next_supersede as sup  # noqa: E402
import nightly_now  # noqa: E402


def rules_path() -> str:
    given = os.environ.get("NIGHTLY_RULES_PY")
    if given:
        return given
    text = subprocess.run(["git", "-C", str(ROOT), "show", "origin/main:scripts/ci/delivery_workflows.py"],
                          capture_output=True, text=True, check=True).stdout
    handle = tempfile.NamedTemporaryFile("w", suffix="_delivery_workflows.py", delete=False)
    handle.write(text)
    handle.close()
    return handle.name


RULES = sup.load_rules(rules_path())
TIP, OLD = "b" * 40, "a" * 40
NOW = dt.datetime(2026, 11, 11, 3, 0, tzinfo=dt.timezone.utc)
JOB_IDS = iter(range(1000, 10**6))


def stamp(minutes_ago: float) -> str:
    return (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(ident, head, status, *, event="push", title="x", created=60.0, branch="nightly-next",
        path=".github/workflows/nightly.yml", attempt=1):
    return {"id": ident, "path": path, "name": "Nightly macOS build", "display_title": title, "status": status,
            "conclusion": None, "head_sha": head, "head_branch": branch, "event": event, "run_attempt": attempt,
            "workflow_id": 7, "created_at": stamp(created), "head_repository": {"full_name": "manaflow-ai/cmux"}}


def job(name, status="queued", conclusion=None, *, runner=None, start=58.0, end=None):
    return {"id": next(JOB_IDS), "name": name, "status": status,
            "conclusion": conclusion if status == "completed" else None, "labels": ["dead-light-label"],
            "runner_name": runner, "started_at": stamp(start), "completed_at": None if end is None else stamp(end),
            "run_attempt": 1}


def queued(last_moved=58.0):
    return [job("decide", "completed", "success", runner="r", start=59, end=last_moved),
            job("build-nightly-app", start=last_moved), job("signer-build", start=last_moved)]


SIGN_OLD = "Sign nightly-next run 42925854615 attempt 1"
SIGN_NEW = "Sign nightly-next run 42929616529 attempt 1"


class RuleTests(unittest.TestCase):
    def judge(self, holder=None, jobs=None, others=None, *, tip=TIP, waiter_jobs=(), now=NOW):
        holder = holder or run(42925854615, OLD, "in_progress")
        others = [run(42948266530, TIP, "pending", created=2)] if others is None else others
        return sup.holder_superseded(RULES, holder, queued() if jobs is None else jobs, [holder, *others],
                                     lambda other: None if waiter_jobs is None else list(waiter_jobs),
                                     tip=tip, now=now)

    def test_the_tip_waiting_on_a_queued_only_push_holder_drops_it(self):
        ok, why, _ = self.judge()
        self.assertTrue(ok, why)
        self.assertIn("42948266530", why)

    def test_the_ready_wait_is_5_minutes_since_it_last_moved(self):
        self.assertEqual(sup.READY_WAIT, dt.timedelta(minutes=5))
        self.assertTrue(self.judge(jobs=queued(last_moved=5))[0])
        ok, why, wait = self.judge(jobs=queued(last_moved=4))
        self.assertFalse(ok)
        self.assertIn("under 5", why)
        self.assertEqual(wait, dt.timedelta(minutes=1))

    def test_a_started_build_sign_or_publish_job_keeps_it(self):
        for started in (job("build-nightly-app", "in_progress", runner="mini", start=30),
                        job("build-nightly-app", runner="mini", start=30),
                        job("build-sign-notarize-nightly", "in_progress", runner="m", start=30),
                        job("publish-nightly", "completed", "failure", runner="r", start=30, end=29),
                        job("signer-build", "completed", "success", runner="r", start=30, end=29)):
            with self.subTest(job=started["name"], status=started["status"]):
                ok, why, wait = self.judge(jobs=[queued()[0], started])
                self.assertFalse(ok)
                self.assertIn("started", why)
                self.assertIsNone(wait)

    def test_the_tips_push_run_is_never_dropped(self):
        ok, why, _ = self.judge(holder=run(1, TIP, "in_progress"))
        self.assertFalse(ok)
        self.assertIn("tip", why)

    def test_no_waiter_or_a_wrong_waiter_keeps_it(self):
        waiter = run(42948266530, TIP, "pending", created=2)
        cases = {
            "no newer run": dict(others=[]),
            "waiter off the tip": dict(tip="c" * 40),
            "waiter lists jobs": dict(waiter_jobs=[job("decide")]),
            "waiter jobs unread": dict(waiter_jobs=None),
            "waiter is queued, not pending": dict(others=[waiter | {"status": "queued"}]),
            "waiter is older": dict(others=[waiter | {"created_at": stamp(90)}]),
            "waiter on main": dict(others=[waiter | {"head_branch": "main"}]),
            "waiter from a fork": dict(others=[waiter | {"head_repository": {"full_name": "x/cmux"}}]),
            "waiter is run-scoped": dict(others=[waiter | {"event": "workflow_dispatch"}]),
            "waiter is a re-run": dict(others=[waiter | {"run_attempt": 2}]),
            "unread tip": dict(tip=""),
        }
        for label, kwargs in cases.items():
            with self.subTest(label):
                ok, why, _ = self.judge(**kwargs)
                self.assertFalse(ok, why)

    def test_live_titles_and_runs_in_no_shared_group(self):
        # Live runs on nightly-next: 42952791964 (a sign stage) and 42941668554 (a loop retry). main's
        # nightly.yml keys main push runs by run id and nightly-sign.yml per source run: never in these groups.
        sign = run(42952791964, OLD, "in_progress", event="workflow_dispatch",
                   title="Sign nightly-next run 42950072283 attempt 1")
        retry = run(42941668554, OLD, "in_progress", event="workflow_dispatch", title="Retry nightly-next (1 of 2)")
        self.assertEqual((sup.group_of(sign), sup.sign_source(sign)), ("sign", 42950072283))
        self.assertEqual(sup.group_of(retry), "push")
        push = run(1, OLD, "in_progress")
        for other in (push | {"head_branch": "main"}, retry | {"head_branch": "main"}, sign | {"head_branch": "main"},
                      sign | {"path": ".github/workflows/nightly-sign.yml"},
                      push | {"path": ".github/workflows/nightly-sign.yml"}, push | {"event": "schedule"},
                      run(2, OLD, "in_progress", event="workflow_dispatch", title="Promote nightly-next to x"),
                      run(3, OLD, "in_progress", event="workflow_dispatch", title="Resume nightly-next run 1 attempt 1")):
            with self.subTest(other=(other["head_branch"], other["path"], other["event"], other["display_title"])):
                self.assertIsNone(sup.group_of(other))
                ok, why, _ = self.judge(holder=other)
                self.assertFalse(ok, why)

    def test_a_loop_retry_shares_the_push_group(self):
        retry_waiter = run(9, TIP, "pending", event="workflow_dispatch", title="Retry nightly-next (1 of 2)", created=2)
        self.assertTrue(self.judge(others=[retry_waiter])[0])
        holder = run(8, OLD, "in_progress", event="workflow_dispatch", title="Retry nightly-next (2 of 2)")
        self.assertTrue(self.judge(holder=holder)[0])

    def test_a_sign_stage_waiting_on_an_older_one_even_at_the_tip(self):
        # A sign stage's head is the tip when its push run dispatched it, not the build it signs.
        old = run(42930383771, TIP, "in_progress", event="workflow_dispatch", title=SIGN_OLD)
        newer = run(42950000000, TIP, "pending", event="workflow_dispatch", title=SIGN_NEW, created=2)
        ok, why, _ = self.judge(holder=old, others=[newer])
        self.assertTrue(ok, why)
        self.assertIn("sign group", why)
        self.assertFalse(self.judge(holder=old, others=[])[0], "with nothing waiting it stays")
        same = newer | {"display_title": "Sign nightly-next run 42925854615 attempt 2"}
        self.assertFalse(self.judge(holder=old, others=[same])[0], "a sign stage of the same build is not later")
        self.assertFalse(self.judge(holder=old)[0], "a push run is not in the sign group")
        # The newest sign stage is pending, never a holder.
        self.assertNotIn("pending", sup.HOLDER_STATUSES)

    def test_mains_20_minute_rule_still_applies(self):
        # A newer tip run already building: main's superseded_unstarted() decides, after its own 20 min.
        holder = run(1, OLD, "queued", created=60)
        building = run(2, TIP, "in_progress", created=40)
        theirs = [job("decide", "completed", "success", runner="r", start=39, end=38),
                  job("build-nightly-app", "in_progress", runner="m", start=37),
                  job("signer-build", "completed", "success", runner="r", start=37, end=36)]
        ok, why, _ = sup.holder_superseded(RULES, holder, queued(last_moved=30), [holder, building],
                                           lambda other: theirs, tip=TIP, now=NOW)
        self.assertTrue(ok, why)
        self.assertIn("stale: (1)", why)


class FakeGh:
    """Answers the reads from a table; records writes."""

    def __init__(self, runs, jobs, prs=(), refuse_writes=False):
        self.runs, self.jobs, self.prs, self.writes, self.refuse = runs, jobs, list(prs), [], refuse_writes
        self.reads: list[str] = []

    def __call__(self, args, write):
        if write:
            if self.refuse:
                raise sup.Unreadable("409")
            self.writes.append(list(args))
            return ""
        path = args[1].split("repos/o/r/", 1)[1]
        self.reads.append(path)
        if path.startswith("actions/workflows/nightly.yml/runs?"):
            status = path.split("status=", 1)[1].split("&", 1)[0]
            listed = [r for r in self.runs if r["status"] == status]
            return json.dumps({"total_count": len(listed), "workflow_runs": listed})
        if path.startswith("actions/runs/") and "/jobs" in path:
            listed = self.jobs.get(int(path.split("/")[2]), [])
            return json.dumps({"total_count": len(listed), "jobs": listed})
        if path.startswith("actions/runs/"):
            ident = int(path.split("/")[2].split("?")[0])
            return json.dumps(next(r for r in self.runs if r["id"] == ident))
        if path.startswith("commits/"):
            return json.dumps(self.prs)
        raise AssertionError(path)


def api(gh, tip=TIP):
    return sup.Api("o/r", gh=gh, tip=lambda repo, branch: tip)


def tonight(holder_jobs=None):
    holder, waiter = run(42925854615, OLD, "in_progress"), run(42948266530, TIP, "pending", created=2)
    return FakeGh([holder, waiter], {42925854615: queued() if holder_jobs is None else holder_jobs, 42948266530: []})


class SweepTests(unittest.TestCase):
    def tick(self, gh, **kwargs):
        log: list[str] = []
        kwargs.setdefault("clock", lambda: NOW)
        done = sup.tick(RULES, api(gh), log=log.append, **kwargs)
        return done, log

    def test_tonights_push_holder_is_cancelled_with_its_jobs_read_last(self):
        gh = tonight()
        done, log = self.tick(gh)
        self.assertEqual(done, [42925854615])
        self.assertEqual(gh.writes, [["api", "-X", "POST", "repos/o/r/actions/runs/42925854615/cancel"]])
        self.assertEqual(gh.reads[-1], "actions/runs/42925854615/jobs?filter=latest&per_page=100&page=1")
        self.assertTrue(any("cancelled run 42925854615" in line for line in log), log)

    def test_a_build_that_starts_by_the_last_read_is_kept(self):
        gh = tonight()
        real = gh.__call__
        reads = {"n": 0}

        def starting(args, write):
            out = real(args, write)
            if not write and "42925854615/jobs" in args[1]:
                reads["n"] += 1
                if reads["n"] == 3:  # the last read, right before the cancel
                    started = [queued()[0], job("build-nightly-app", "in_progress", runner="mini", start=0)]
                    return json.dumps({"total_count": 2, "jobs": started})
            return out
        done, log = self.tick(starting)
        self.assertEqual(done, [])
        self.assertTrue(any("last read of its jobs" in line for line in log), log)

    def test_dry_run_cancels_nothing(self):
        gh = tonight()
        self.assertEqual(self.tick(gh, dry_run=True)[0], [42925854615])
        self.assertEqual(gh.writes, [])

    def test_a_started_build_or_an_open_pull_request_keeps_it(self):
        gh = tonight([queued()[0], job("build-nightly-app", "in_progress", runner="mini", start=30)])
        self.assertEqual(self.tick(gh)[0], [])
        gh = tonight()
        gh.prs = [{"number": 9, "state": "open", "head": {"sha": OLD}}]
        self.assertEqual(self.tick(gh)[0], [])
        self.assertEqual(gh.writes, [])

    def test_unread_answers_and_refused_cancels_cancel_nothing(self):
        def broken(args, write):
            raise sup.Unreadable("rate limited")
        done, log = self.tick(broken)
        self.assertEqual(done, [])
        self.assertIn("nothing cancelled", log[0])
        gh = tonight()
        gh.refuse = True
        done, log = self.tick(gh)
        self.assertEqual(done, [])
        self.assertTrue(any("refused" in line for line in log), log)

    def test_settle_waits_out_the_holders_last_minute_once(self):
        gh = tonight(queued(last_moved=4))
        clock = {"now": NOW}
        slept: list[float] = []

        def sleep(seconds):
            slept.append(seconds)
            clock["now"] += dt.timedelta(seconds=seconds)
        done, _ = self.tick(gh, settle=True, clock=lambda: clock["now"], sleep=sleep)
        self.assertEqual(done, [42925854615])
        self.assertEqual(slept, [65.0])
        # Without --settle nothing waits.
        gh = tonight(queued(last_moved=4))
        self.assertEqual(self.tick(gh, sleep=lambda s: self.fail("slept"))[0], [])

    def test_settle_waits_briefly_for_a_push_run_not_listed_yet(self):
        holder = run(1, OLD, "in_progress")
        gh = FakeGh([holder], {1: queued()})
        slept: list[float] = []
        self.tick(gh, settle=True, sleep=slept.append)
        self.assertEqual(slept, [sup.SETTLE_NO_WAITER.total_seconds() + 5])

    def test_a_holder_still_inside_its_ready_wait_dispatches_the_next_link(self):
        # The settle ends (here the clock stands still) and the holder still lacks a minute: rather than wait for
        # the next promotion, the run dispatches the next link of the chain on nightly-next.
        gh = tonight(queued(last_moved=4))
        done, log = self.tick(gh, settle=True, sleep=lambda s: None, chain=0)
        self.assertEqual(done, [])
        self.assertEqual(gh.writes, [["workflow", "run", "nightly-next-supersede.yml", "-R", "o/r", "--ref",
                                      "nightly-next", "-f", "chain=1"]])
        self.assertTrue(any("dispatched link 1 of at most 12" in line for line in log), log)
        gh = tonight(queued(last_moved=4))
        self.tick(gh, sleep=lambda s: None, chain=5)
        self.assertEqual(gh.writes[-1][-1], "chain=6")

    def test_the_chain_stops_at_its_cap_on_a_dry_run_once_cancelled_and_without_a_holder(self):
        gh = tonight(queued(last_moved=4))
        _, log = self.tick(gh, sleep=lambda s: None, chain=sup.CHAIN_MAX)
        self.assertEqual(gh.writes, [])
        self.assertTrue(any("::warning" in line and "re-dispatches" in line for line in log), log)
        gh = tonight(queued(last_moved=4))
        _, log = self.tick(gh, sleep=lambda s: None, chain=0, dry_run=True)
        self.assertEqual(gh.writes, [])
        self.assertTrue(any("would dispatch link 1" in line for line in log), log)
        gh = tonight()  # droppable now: cancelled, nothing left to wait for
        self.tick(gh, chain=0)
        self.assertEqual([w[0] for w in gh.writes], ["api"])
        gh = FakeGh([run(1, OLD, "in_progress")], {1: queued()})  # no waiter listed yet: not a holder's wait
        self.tick(gh, settle=True, sleep=lambda s: None, chain=0)
        self.assertEqual(gh.writes, [])
        gh = tonight(queued(last_moved=4))  # without --chain (by hand) it never re-dispatches
        self.tick(gh, sleep=lambda s: None)
        self.assertEqual(gh.writes, [])

    def test_a_refused_dispatch_is_a_warning(self):
        gh = tonight(queued(last_moved=4))
        gh.refuse = True
        done, log = self.tick(gh, sleep=lambda s: None, chain=0)
        self.assertEqual(done, [])
        self.assertTrue(any("re-dispatch was refused" in line for line in log), log)

    def test_a_missing_gh_is_unread(self):
        old = os.environ.get("PATH")
        os.environ["PATH"] = "/nonexistent"
        try:
            with self.assertRaises(sup.Unreadable):
                sup.gh_cli(["api", "x"], False)
        finally:
            os.environ["PATH"] = old or ""

    def test_the_workflow_runs_beside_each_promotion_with_mains_rule(self):
        import yaml
        doc = yaml.safe_load((ROOT / ".github/workflows/nightly-next-supersede.yml").read_text(encoding="utf-8"))
        triggers = doc.get("on", doc.get(True))
        self.assertEqual(triggers["push"], {"branches": ["nightly-next"]})
        self.assertEqual(triggers["workflow_dispatch"]["inputs"]["chain"]["default"], "0")
        job = doc["jobs"]["supersede"]
        self.assertEqual(job["concurrency"], {"group": "nightly-next-supersede", "cancel-in-progress": False})
        self.assertEqual(job["permissions"], {"actions": "write", "contents": "read"})
        self.assertNotIn("secrets.", json.dumps(job))
        rules = job["steps"][1]["with"]
        self.assertEqual((rules["ref"], rules["sparse-checkout"].strip()), ("main", "scripts/ci/delivery_workflows.py"))
        step = job["steps"][-1]
        self.assertTrue(step.get("continue-on-error"))
        self.assertIn("--rules .main-rules/scripts/ci/delivery_workflows.py --settle --chain \"$CHAIN\"", step["run"])
        self.assertEqual(step["env"]["CHAIN"], "${{ inputs.chain || '0' }}")


class NightlyNowTests(unittest.TestCase):
    def call(self, argv, fail=()):
        sent, log = [], []

        def gh(args):
            sent.append(list(args))
            if args[0] == "api":
                return "c" * 40 + "\n"
            if any(name in args for name in fail):
                raise RuntimeError("HTTP 404")
            return ""
        code = nightly_now.main(argv, gh=gh, tip=lambda repo, branch: TIP, log=log.append)
        return code, sent, log

    def test_asks_for_the_tip_then_starts_the_cleanup(self):
        code, sent, _ = self.call(["--repo", "o/r"])
        self.assertEqual(code, 0)
        self.assertEqual(sent, [
            ["workflow", "run", "nightly-next-tick.yml", "--repo", "o/r", "--ref", "main", "-f", f"sha={TIP}"],
            ["workflow", "run", "nightly-next-supersede.yml", "--repo", "o/r", "--ref", "nightly-next"]])

    def test_a_given_or_short_sha(self):
        self.assertEqual(self.call([OLD, "--repo", "o/r"])[1][0][-1], f"sha={OLD}")
        code, sent, _ = self.call(["abc1234", "--repo", "o/r"])
        self.assertEqual((code, sent[0][:2]), (0, ["api", "repos/o/r/commits/abc1234"]))
        self.assertEqual(sent[1][-1], "sha=" + "c" * 40)

    def test_a_failed_cleanup_only_warns_and_a_failed_request_stops(self):
        code, _, log = self.call(["--repo", "o/r"], fail=("nightly-next-supersede.yml",))
        self.assertEqual(code, 0)
        self.assertIn("warning", log[-1])
        code, sent, _ = self.call(["--repo", "o/r"], fail=("nightly-next-tick.yml",))
        self.assertEqual((code, len(sent)), (1, 1))

    def test_dry_run_and_a_bad_sha(self):
        code, sent, log = self.call(["--repo", "o/r", "--dry-run"])
        self.assertEqual((code, sent, len(log)), (0, [], 2))
        self.assertEqual(self.call(["not-a-sha", "--repo", "o/r"])[0], 2)

    def test_it_never_cancels(self):
        _, sent, _ = self.call(["--repo", "o/r"])
        self.assertFalse(any("cancel" in " ".join(args) for args in sent))


if __name__ == "__main__":
    unittest.main()
