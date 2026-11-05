"""An older nightly-next build hands its sign slot to a newer build whose sign job exists; the newest never yields
(scripts/ci/nightly_sign_yield.py, cmuxterm-hq#7079)."""

from pathlib import Path
import datetime as dt
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_sign_yield.py"
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
spec = importlib.util.spec_from_file_location("nightly_sign_yield", SCRIPT)
sy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sy)

REPO = "manaflow-ai/cmux"
SIGN = "build-sign-notarize-nightly (arm64)"
NOW = dt.datetime(2026, 11, 5, 1, 0, tzinfo=dt.timezone.utc)


# The other tests read a feed published 5 minutes before NOW and a clock at NOW, never the network.
sy.utcnow = lambda: NOW


def at(minutes):
    return NOW + dt.timedelta(minutes=minutes)


def feed(*runs):
    """A NEXT feed whose items are attempt 1 of these runs (an empty feed for none)."""
    items = "".join(f"<item><sparkle:version>{rid}01</sparkle:version></item>" for rid in runs)
    return f"<rss><channel><title>cmux NEXT</title>{items}</channel></rss>".encode()


def iso(when):
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def env(run_id=100, **over):
    base = {"GITHUB_REPOSITORY": REPO, "GITHUB_RUN_ID": str(run_id), "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_EVENT_NAME": "push", "GITHUB_REF_NAME": "nightly-next", "TRACK": "nightly-next"}
    base.update(over)
    return base


def job(name, status, conclusion=None):
    return {"id": hash((name, status)) & 0xFFFF, "name": name, "status": status, "conclusion": conclusion}


class Fake:
    """runs: {run id: [jobs]} of the unfinished nightly-next push runs; statuses: {run id: run status}, in_progress
    unless given. A run listing answers only the runs in the status it asks for."""

    def __init__(self, runs, fail=None, statuses=None, created=None):
        self.runs, self.fail, self.paths, self.statuses = runs, fail, [], statuses or {}
        self.created = created or {}  # {run id: when it landed}; NOW unless given

    def __call__(self, path):
        self.paths.append(path)
        if self.fail and self.fail in path:
            raise sy.Unreadable("refused")
        first = path.endswith("&page=1")
        if "/actions/workflows/nightly.yml/runs" in path:
            status = path.split("status=", 1)[1].split("&", 1)[0]
            matching = [rid for rid in self.runs if self.statuses.get(rid, "in_progress") == status]
            items = [{"id": rid, "created_at": iso(self.created.get(rid, NOW))} for rid in matching] if first else []
            return {"total_count": len(matching) + 7, "workflow_runs": items}  # total_count runs ahead, as GitHub's can
        rest = path.split("/actions/runs/")[1]
        rid = int(rest.split("/")[0])
        if rest.isdigit():
            return {"id": rid, "created_at": iso(self.created.get(rid, NOW))}
        jobs = self.runs[rid] if first else []
        return {"total_count": len(self.runs[rid]), "jobs": jobs}


sy.read_feed = lambda url=sy.NEXT_FEED: feed(1)


def decide(run_id, runs, created=None, published=(1,), **over):
    return sy.decide(env(run_id, **over), Fake(runs, created=created), log=lambda _: None,
                     feed=lambda: feed(*published), now=lambda: NOW)


class Sim:
    """nightly-next as it runs: a landing every EVERY minutes, each its own push run, built BUILD minutes later on
    the parallel builders, then its sign job queued FIFO for the one signer (GitHub hands a free runner the oldest
    queued job). The signer runs nightly_sign_yield.decide on each job it takes; a job that yields frees it at once,
    one that signs holds it SIGN minutes (sign, notarize, publish) and then publishes. never_runs names runs whose
    sign job is queued but never gets a runner (a pinned runner that went offline)."""

    def __init__(self, every=8, hours=3, build=15, sign=20, never_runs=()):
        self.every, self.build, self.sign, self.never_runs = every, build, sign, set(never_runs)
        self.landings = [i * every for i in range(int(hours * 60 // every) + 1)]
        self.end = self.landings[-1] + build + 4 * sign
        self.state = {}  # run index -> queued | stuck | in_progress | signed | yielded
        self.published = []  # (minute, run index of the build published)
        # Minutes each build that yielded to a newer run that was not due had waited since its landing.
        self.yielded_due_to_undue = []

    def runs_view(self):
        status = {"queued": ("queued", None), "stuck": ("queued", None), "in_progress": ("in_progress", None)}
        active = {}
        for i, landed in enumerate(self.landings):
            st = self.state.get(i)
            if st in (None, "queued", "stuck", "in_progress") and landed <= self.t:
                active[1000 + i] = [job(SIGN, *status[st])] if st else [job("build-nightly-app", "in_progress")]
        return active

    def decide(self, i):
        runs = self.runs_view()
        created = {1000 + k: NOW + dt.timedelta(minutes=m) for k, m in enumerate(self.landings)}
        pubs = [1000 + i for _, i in self.published]
        return sy.decide(env(1000 + i), Fake(runs, created=created), log=lambda _: None,
                         feed=lambda: feed(*pubs), now=lambda: NOW + dt.timedelta(minutes=self.t))

    def run(self):
        holder, free_at = None, 0
        for self.t in range(self.end + 1):
            for i, landed in enumerate(self.landings):
                if landed + self.build == self.t:
                    self.state[i] = "stuck" if i in self.never_runs else "queued"
            if holder is not None and self.t >= free_at:
                self.state[holder] = "signed"
                self.published.append((self.t, holder))
                holder = None
            while holder is None:
                queued = [i for i, st in sorted(self.state.items()) if st == "queued"]
                if not queued:
                    break
                i = queued[0]
                yielded, why = self.decide(i)
                if yielded:
                    self.state[i] = "yielded"
                    if "also waiting 30 min" not in why:
                        self.yielded_due_to_undue.append(self.t - self.landings[i])
                else:
                    self.state[i], holder, free_at = "in_progress", i, self.t + self.sign
        return self

    def gaps(self, until=None):
        """Minutes between publishes, from the first landing, over the landing window."""
        until = self.landings[-1] if until is None else until
        times = [0] + [m for m, _ in self.published if m <= until + self.build + self.sign]
        return [b - a for a, b in zip(times, times[1:])]


class SignYieldTest(unittest.TestCase):
    def test_the_newest_queued_build_never_yields(self):
        # The 2026-11-04 shape: three older signs running, three queued. The newest queued one signs.
        runs = {100: [job(SIGN, "in_progress")], 101: [job(SIGN, "in_progress")], 102: [job(SIGN, "in_progress")],
                103: [job(SIGN, "queued")], 104: [job(SIGN, "queued")], 105: [job(SIGN, "queued")]}
        self.assertEqual(decide(105, runs)[0], False)
        # A newer run whose sign job does not exist yet (its build is still running) is no reason either.
        runs[106] = [job("build-nightly-app", "in_progress"), job("decide", "completed", "success")]
        self.assertEqual(decide(105, runs)[0], False)

    def test_an_older_build_yields_to_a_newer_queued_running_or_signed_sign_job(self):
        for state in (("queued", None), ("in_progress", None), ("completed", "success")):
            with self.subTest(state=state):
                yielded, why = decide(103, {103: [job(SIGN, "queued")], 105: [job(SIGN, *state)]})
                self.assertTrue(yielded)
                self.assertIn("105", why)

    def test_a_newer_run_waiting_pending_or_requested_is_read_too(self):
        # cmuxterm-hq#7091: a newer run gated on an environment or a concurrency slot can hold a queued sign job.
        for status in ("waiting", "pending", "requested"):
            with self.subTest(status=status):
                fake = Fake({103: [job(SIGN, "queued")], 105: [job(SIGN, "queued")]}, statuses={105: status})
                yielded, why = sy.decide(env(103), fake, log=lambda _: None)
                self.assertTrue(yielded)
                self.assertIn("105", why)
        fake = Fake({105: [job(SIGN, "queued")]})
        sy.decide(env(103), fake, log=lambda _: None)
        self.assertIn("queued", sy.ACTIVE_RUN_STATUSES)
        self.assertEqual(sorted({p.split("status=")[1].split("&")[0] for p in fake.paths if "status=" in p}),
                         sorted(sy.ACTIVE_RUN_STATUSES))

    def test_a_newer_run_whose_only_unfinished_job_is_its_queued_sign_reads_as_queued_and_counts(self):
        # 2026-11-04: once a run's builds finish and only its sign job waits for a runner, GitHub reports the whole
        # run as queued. The yield read no queued runs, so an older build signed while a newer sign job waited.
        runs = {103: [job(SIGN, "queued")],
                105: [job("build-nightly-app", "completed", "success"), job(SIGN, "queued")]}
        fake = Fake(runs, statuses={105: "queued"})
        yielded, why = sy.decide(env(103), fake, log=lambda _: None)
        self.assertTrue(yielded)
        self.assertIn("105", why)

    def test_a_newer_push_alone_never_counts(self):
        # #33109's rule still holds for a newer push: no sign job, or one that failed, was skipped or cancelled.
        for jobs in ([], [job("build-nightly-app", "queued")], [job(SIGN, "completed", "failure")],
                     [job(SIGN, "completed", "skipped")], [job(SIGN, "completed", "cancelled")],
                     [job("sign-nightly-identity-legacy", "queued")]):
            with self.subTest(jobs=jobs):
                self.assertEqual(decide(103, {103: [job(SIGN, "queued")], 105: jobs})[0], False)

    def test_an_older_run_is_never_a_reason(self):
        self.assertEqual(decide(105, {101: [job(SIGN, "queued")], 105: [job(SIGN, "queued")]})[0], False)

    def test_outside_attempt_1_of_a_nightly_next_push_it_signs_without_a_read(self):
        runs = {103: [job(SIGN, "queued")], 105: [job(SIGN, "queued")]}
        for over in ({"GITHUB_RUN_ATTEMPT": "2"}, {"GITHUB_EVENT_NAME": "workflow_dispatch"},
                     {"GITHUB_REF_NAME": "main"}, {"TRACK": "nightly"}, {"NIGHTLY_NEXT_SIGN_YIELD": "0"},
                     {"GITHUB_RUN_ID": "x"}):
            with self.subTest(over=over):
                fake = Fake(runs)
                self.assertEqual(sy.decide(env(103, **over), fake, log=lambda _: None)[0], False)
                self.assertEqual(fake.paths, [])

    def test_any_doubt_signs(self):
        runs = {103: [job(SIGN, "queued")], 105: [job(SIGN, "queued")]}
        for fail in ("/actions/workflows/", "/actions/runs/105/"):
            with self.subTest(fail=fail):
                self.assertEqual(sy.decide(env(103), Fake(runs, fail=fail), log=lambda _: None)[0], False)
        # A listing with no end (more than MAX_PAGES pages), one that is not a listing, and a job with no status.
        endless = lambda path: {"workflow_runs": [{"id": 105}]}
        self.assertEqual(sy.decide(env(103), endless, log=lambda _: None)[0], False)
        self.assertEqual(sy.decide(env(103), lambda path: {"message": "x"}, log=lambda _: None)[0], False)
        bad = {103: [], 105: [{"id": 1, "name": SIGN}]}
        self.assertEqual(decide(103, bad)[0], False)

    def test_the_cli_writes_yielded_and_exits_1_only_when_it_yields(self):
        # No network: an unreadable API (a closed port) signs, writes yielded=false and exits 0.
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            proc = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True,
                                  env={**os.environ, **env(103), "GITHUB_OUTPUT": str(out), "GH_TOKEN": "x",
                                       "GITHUB_API_URL": "http://127.0.0.1:9"})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(out.read_text(), "yielded=false\n")


class NeverPast30MinutesTest(unittest.TestCase):
    """Leo, 2026-11-05: "If something hasn't f***ing ran for thirty minutes, f***ing build it. Stop f***ing
    canceling it." The newest run whose landing has waited 30 min unpublished signs to the end."""

    NEWER = {103: [job(SIGN, "queued")], 105: [job(SIGN, "queued")]}

    def test_a_due_landing_never_yields_to_a_newer_run_that_is_not_due(self):
        yielded, why = decide(103, self.NEWER, created={103: at(-31), 105: at(-10)}, published=(90,))
        self.assertFalse(yielded)
        self.assertIn("due", why)
        # An empty feed counts as nothing published.
        self.assertFalse(decide(103, self.NEWER, created={103: at(-31), 105: at(-10)}, published=())[0])

    def test_under_30_min_or_already_published_it_still_yields_to_the_newest(self):
        self.assertTrue(decide(103, self.NEWER, created={103: at(-29), 105: at(-10)}, published=(90,))[0])
        # The feed already has a build at or after this run: its commits are out, so it is not due.
        self.assertTrue(decide(103, self.NEWER, created={103: at(-45), 105: at(-10)}, published=(104,))[0])

    def test_due_runs_sign_newest_first(self):
        # Both waited 30 min unpublished: the older one yields to the newer one, which then never yields.
        created = {103: at(-50), 105: at(-35), 107: at(-5)}
        runs = {**self.NEWER, 107: [job(SIGN, "queued")]}
        yielded, why = decide(103, runs, created=created, published=(90,))
        self.assertTrue(yielded)
        self.assertIn("105", why)
        self.assertFalse(decide(105, runs, created=created, published=(90,))[0])

    def test_an_unreadable_feed_signs(self):
        huge = b"<item><sparkle:version>" + b"9" * 5000 + b"</sparkle:version></item>"
        mixed = b"<item><sparkle:version>4190094575701</sparkle:version></item><item><sparkle:version>x</sparkle:version></item>"
        for reader in (lambda: b"<item><title>no build</title></item>", lambda: b"x" * 2_000_001,
                       lambda: huge, lambda: mixed):
            with self.subTest():
                fake = Fake(self.NEWER)
                self.assertFalse(sy.decide(env(103), fake, log=lambda _: None, feed=reader, now=lambda: NOW)[0])

        # A run start with no zone is doubt too, never a crash.
        fake = Fake(self.NEWER)
        fake_get = lambda path: ({"id": 103, "created_at": "2026-11-05T00:00:00"} if path.endswith("/runs/103")
                                 else fake(path))
        self.assertFalse(sy.decide(env(103), fake_get, log=lambda _: None, now=lambda: NOW)[0])

        def refused():
            raise sy.Unreadable("refused")
        self.assertFalse(sy.decide(env(103), Fake(self.NEWER), log=lambda _: None, feed=refused,
                                   now=lambda: NOW)[0])

    def test_a_landing_every_8_min_for_3_hours_publishes_at_least_every_30_min(self):
        sim = Sim(every=8, hours=3, build=15, sign=20).run()
        gaps = sim.gaps()
        self.assertTrue(gaps, "nothing published")
        self.assertLessEqual(gaps[0], 15 + 20, gaps)  # the first landing: built, then signed and published
        self.assertLessEqual(max(gaps[1:]), 30, gaps)
        # Nothing that waited 30 min unpublished gave its build up to a run that was not due.
        self.assertTrue(all(w < sy.PIN_AFTER_S / 60 for w in sim.yielded_due_to_undue), sim.yielded_due_to_undue)

    def test_a_newer_sign_job_that_never_gets_a_runner_cannot_starve_the_feed(self):
        # Every fourth run's sign job waits for a runner that never comes. Before the 30-minute rule an older build
        # yielded to it and nothing published; now a build that waited 30 min signs anyway.
        sim = Sim(every=8, hours=3, build=15, sign=20, never_runs=range(3, 40, 4)).run()
        gaps = sim.gaps()
        self.assertLessEqual(max(gaps[1:]), 30, gaps)


class SignYieldWiringTest(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        self.sign = self.jobs["build-sign-notarize-nightly"]
        self.names = [step.get("name") for step in self.sign["steps"]]

    def test_the_yield_runs_right_after_the_claim_and_before_any_secret(self):
        at = self.names.index("Yield the sign slot to a newer build")
        self.assertEqual(self.names[at - 1], "Claim the whole Mac for signing")
        step = self.sign["steps"][at]
        self.assertEqual(step["run"], "python3 .nightly-signing-control/scripts/ci/nightly_sign_yield.py")
        self.assertNotIn("secrets.", str(step))
        self.assertNotIn("continue-on-error", step)
        self.assertNotIn("if", step)
        for earlier in self.sign["steps"][:at]:
            self.assertNotIn("secrets.", str(earlier), earlier.get("name"))
        self.assertEqual(self.sign["outputs"]["yielded"], "${{ steps.sign-yield.outputs.yielded }}")

    def test_report_nightly_failure_skips_only_a_yielded_sign(self):
        script = self.jobs["report-nightly-failure"]["steps"][0]["with"]["script"]
        self.assertIn("results['build-sign-notarize-nightly']?.outputs?.yielded === 'true'", script)
        self.assertIn("!(yielded && k === 'build-sign-notarize-nightly')", script)
        self.assertIn("if (yielded && failed.length === 0", script)


if __name__ == "__main__":
    unittest.main()
