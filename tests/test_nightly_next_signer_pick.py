#!/usr/bin/env python3
"""The nightly-next signer pick (scripts/ci/nightly_next_signer_pick.py), and nightly.yml's use of it.

Why: docs/ci/nightly-workflow-notes.md#note-33 (design manaflow-ai/cmuxterm-hq#17011). Two builds in flight, one per
signer Mac: the pin always starts with the literal signer label, an idle signer with no nightly-next-one for it is
picked first, else the host whose holder ends soonest, never a host that already has one waiting; any failure is
cmux15 and the label alone (the routing before the pick).
"""
from __future__ import annotations

import base64
import datetime as dt
import gzip
import importlib.util
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_next_signer_pick.py"
spec = importlib.util.spec_from_file_location("nightly_next_signer_pick", SCRIPT)
pick_mod = importlib.util.module_from_spec(spec)
sys.modules["nightly_next_signer_pick"] = pick_mod
spec.loader.exec_module(pick_mod)

SIGNER = "glaeda-trusted-next-signing"
LABEL_ONLY = json.dumps([SIGNER], separators=(",", ":"))
NOW = dt.datetime(2026, 11, 21, tzinfo=dt.timezone.utc)
_ids = iter(range(1, 10_000))


def runner(name: str, busy: bool = False, status: str = "online", signer: bool = True) -> dict:
    labels = [{"name": "self-hosted"}, {"name": f"glaeda-runner-{name}"}]
    if signer:
        labels.append({"name": SIGNER})
    return {"id": next(_ids), "name": name, "os": "macOS", "status": status, "busy": busy, "labels": labels}


def fleet(**overrides) -> list[dict]:
    """Two runners per signer Mac, all online and idle, plus a nightly-only runner on cmux15."""
    base = {name: runner(name) for name in ("cmux15-glaeda", "cmux15-glaeda-1", "ultra1-glaeda", "ultra1-glaeda-1")}
    base["cmux15-glaeda-nightly-only-4"] = runner("cmux15-glaeda-nightly-only-4", busy=True, signer=False)
    for name, value in overrides.items():
        base[name.replace("_", "-")] = value
    return list(base.values())


def one(status: str, runner_name: str = "", labels=(SIGNER,), steps=(), started: str = "") -> dict:
    return {"name": "nightly-next-one", "status": status, "runner_name": runner_name, "labels": list(labels),
            "started_at": started, "steps": [{"name": n, "status": s, "conclusion": c} for n, s, c in steps]}


FINISHING = (("Ask main's nightly-next tick at notarization", "completed", "success"),
             ("Notarize app ticket through final DMG", "in_progress", None))


def census(runners: list[dict], generated: dt.datetime = NOW) -> str:
    doc = {"schema": "runner-state/v1", "repository": "manaflow-ai/cmux", "complete": True,
           "generated_at": generated.isoformat(), "repository_runners": runners,
           "runner_groups": {"glaeda-minis": []}, "scale_sets": {}}
    return base64.b64encode(gzip.compress(json.dumps(doc).encode())).decode()


def loop_run(run_id: int, status: str = "in_progress", event: str = "push", title: str = "x") -> dict:
    return {"id": run_id, "status": status, "event": event, "display_title": title, "head_branch": "nightly-next"}


class Api:
    def __init__(self, runs, jobs):
        self.runs, self.jobs, self.paths = runs, jobs, []

    def __call__(self, path: str):
        self.paths.append(path)
        if path.startswith("actions/workflows/nightly.yml/runs?"):
            return {"workflow_runs": self.runs}
        run_id = int(path.split("/")[2])
        return {"jobs": self.jobs.get(run_id, [])}


def env(runners=None, **extra) -> dict:
    return {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ID": "500",
            "CI_RUNNER_STATE": census(fleet() if runners is None else runners), **extra}


class PickTests(unittest.TestCase):
    def assert_pin(self, pin: str, runner_name: str | None = None) -> None:
        labels = json.loads(pin)
        self.assertEqual(labels[0], SIGNER, "the pin always starts with the literal signer label")
        if runner_name is None:
            self.assertEqual(labels, [SIGNER])
        else:
            self.assertEqual(labels, [SIGNER, f"glaeda-runner-{runner_name}"])

    def test_nothing_running_picks_cmux15(self):
        host, pin, why = pick_mod.pick(fleet(), [])
        self.assertEqual(host, "cmux15", why)
        self.assert_pin(pin, "cmux15-glaeda")

    def test_cmux15_building_picks_idle_ultra1(self):
        runners = fleet(cmux15_glaeda=runner("cmux15-glaeda", busy=True))
        host, pin, why = pick_mod.pick(runners, [one("in_progress", "cmux15-glaeda")])
        self.assertEqual(host, "ultra1", why)
        self.assert_pin(pin, "ultra1-glaeda")

    def test_a_host_with_a_waiting_build_is_not_free_even_before_its_runner_is_busy(self):
        """A nightly-next-one queued for cmux15 (pinned, or on the label alone) claims it: the census can't see it."""
        for labels in ([SIGNER, "glaeda-runner-cmux15-glaeda-1"], [SIGNER]):
            with self.subTest(labels=labels):
                host, pin, why = pick_mod.pick(fleet(), [one("pending", labels=labels)])
                self.assertEqual(host, "ultra1", why)

    def test_an_offline_signer_is_never_picked(self):
        runners = fleet(ultra1_glaeda=runner("ultra1-glaeda", status="offline"),
                        ultra1_glaeda_1=runner("ultra1-glaeda-1", status="offline"),
                        cmux15_glaeda=runner("cmux15-glaeda", busy=True))
        host, pin, why = pick_mod.pick(runners, [one("in_progress", "cmux15-glaeda", steps=FINISHING)])
        self.assertEqual(host, "cmux15", why)
        self.assert_pin(pin, "cmux15-glaeda-1")

    def test_both_busy_picks_the_finishing_holder(self):
        runners = fleet(cmux15_glaeda=runner("cmux15-glaeda", busy=True), ultra1_glaeda=runner("ultra1-glaeda", busy=True))
        holders = [one("in_progress", "cmux15-glaeda", started="2026-11-21T10:00:00Z"),
                   one("in_progress", "ultra1-glaeda", steps=FINISHING, started="2026-11-21T10:10:00Z")]
        host, pin, why = pick_mod.pick(runners, holders)
        self.assertEqual(host, "ultra1", why)
        self.assertIn("notarizing or publishing", why)
        self.assertEqual(json.loads(pin)[0], SIGNER)

    def test_both_busy_none_finishing_picks_the_first_started(self):
        runners = fleet(cmux15_glaeda=runner("cmux15-glaeda", busy=True), ultra1_glaeda=runner("ultra1-glaeda", busy=True))
        holders = [one("in_progress", "cmux15-glaeda", started="2026-11-21T10:20:00Z"),
                   one("in_progress", "ultra1-glaeda", started="2026-11-21T10:05:00Z")]
        host, _, why = pick_mod.pick(runners, holders)
        self.assertEqual(host, "ultra1", why)

    def test_a_host_busy_only_with_a_tail_job_comes_before_a_building_one(self):
        runners = fleet(cmux15_glaeda=runner("cmux15-glaeda", busy=True), ultra1_glaeda=runner("ultra1-glaeda", busy=True))
        host, _, why = pick_mod.pick(runners, [one("in_progress", "cmux15-glaeda", steps=FINISHING)])
        self.assertEqual(host, "ultra1", why)
        self.assertIn("tail job", why)

    def test_never_a_second_waiting_build_on_one_host(self):
        runners = fleet(cmux15_glaeda=runner("cmux15-glaeda", busy=True), ultra1_glaeda=runner("ultra1-glaeda", busy=True))
        holders = [one("in_progress", "cmux15-glaeda", steps=FINISHING),
                   one("pending", labels=[SIGNER, "glaeda-runner-cmux15-glaeda-1"]),
                   one("in_progress", "ultra1-glaeda")]
        host, _, why = pick_mod.pick(runners, holders)
        self.assertEqual(host, "ultra1", why)
        with self.subTest("both hosts have one waiting: the label alone, as before"):
            host, pin, why = pick_mod.pick(runners, [*holders, one("queued", labels=[SIGNER, "glaeda-runner-ultra1-glaeda-1"])])
            self.assertEqual((host, pin), ("cmux15", LABEL_ONLY), why)

    def test_a_non_signer_host_is_never_a_slot(self):
        runners = [runner("cmux7s-mac-mini-glaeda"), *fleet(cmux15_glaeda=runner("cmux15-glaeda", busy=True),
                                                            ultra1_glaeda=runner("ultra1-glaeda", busy=True))]
        host, _, _ = pick_mod.pick(runners, [])
        self.assertIn(host, pick_mod.HOSTS)

    def test_a_runner_without_the_signer_label_is_never_pinned(self):
        runners = [runner("ultra1-glaeda", signer=False), runner("cmux15-glaeda", busy=True)]
        host, pin, why = pick_mod.pick(runners, [one("pending", labels=[SIGNER, "glaeda-runner-cmux15-glaeda"])])
        self.assertEqual((host, pin), ("cmux15", LABEL_ONLY), why)


def done(runner_name: str, conclusion: str, completed: str, failed_step: str = "Build nightly app (Release)") -> dict:
    steps = [{"name": failed_step, "status": "completed", "conclusion": "failure"}] if conclusion == "failure" else []
    return {"name": "nightly-next-one", "status": "completed", "conclusion": conclusion, "runner_name": runner_name,
            "completed_at": completed, "steps": steps}


class CrashedHostTests(unittest.TestCase):
    """2026-11-27 15:24Z-17:57Z: 9 builds in a row took one signer Mac as "an idle signer" and failed in the app build;
    21 of 22 builds in 48 h ran there. A host whose last build failed in the app build yields to the other."""

    def test_last_build_failed_in_the_app_build_marks_the_host(self):
        crashed = pick_mod.crashed_hosts([done("cmux15-glaeda", "success", "2026-11-27T10:00:00Z"),
                                          done("cmux15-glaeda-1", "failure", "2026-11-27T11:00:00Z")])
        self.assertEqual(crashed, {"cmux15"})

    def test_a_later_success_clears_it_and_other_steps_do_not_count(self):
        self.assertEqual(pick_mod.crashed_hosts([done("ultra1-glaeda", "failure", "2026-11-27T10:00:00Z"),
                                                 done("ultra1-glaeda", "success", "2026-11-27T11:00:00Z")]), set())
        self.assertEqual(pick_mod.crashed_hosts([done("ultra1-glaeda", "failure", "2026-11-27T11:00:00Z",
                                                      failed_step="Notarize app ticket through final DMG")]), set())

    def test_both_free_skips_the_crashed_first_host(self):
        host, pin, why = pick_mod.pick(fleet(), [], frozenset({"cmux15"}))
        self.assertEqual(host, "ultra1", why)
        self.assertIn("skipped", why)

    def test_a_crashed_idle_host_yields_to_a_busy_healthy_one(self):
        holders = [one("in_progress", "ultra1-glaeda", started="2026-11-27T16:00:00Z")]
        runners = fleet(ultra1_glaeda=runner("ultra1-glaeda", busy=True))
        host, pin, why = pick_mod.pick(runners, holders, frozenset({"cmux15"}))
        self.assertEqual(host, "ultra1", why)
        self.assertEqual(json.loads(pin)[0], SIGNER)

    def test_the_crashed_host_still_builds_when_no_other_can(self):
        runners = fleet(ultra1_glaeda=runner("ultra1-glaeda", status="offline"),
                        ultra1_glaeda_1=runner("ultra1-glaeda-1", status="offline"))
        host, _, why = pick_mod.pick(runners, [], frozenset({"cmux15"}))
        self.assertEqual(host, "cmux15", why)

    def test_evaluate_reads_finished_runs_and_moves_off_the_crashed_host(self):
        runs = [loop_run(7, status="completed")]
        api = Api(runs, {7: [done("cmux15-glaeda", "failure", "2026-11-27T11:00:00Z")]})
        host, _, why = pick_mod.evaluate(env(), api, now=NOW)
        self.assertEqual(host, "ultra1", why)

    def test_a_failed_finished_read_keeps_the_pick(self):
        class Flaky(Api):
            def __call__(self, path):
                if "/runs/7/" in path:
                    raise OSError("boom")
                return super().__call__(path)
        host, _, why = pick_mod.evaluate(env(), Flaky([loop_run(7, status="completed")], {}), now=NOW)
        self.assertEqual(host, "cmux15", why)
        self.assertNotIn("pick failed", why)


class EvaluateTests(unittest.TestCase):
    def test_reads_one_listing_and_each_open_loop_run_s_jobs(self):
        runs = [loop_run(1), loop_run(2, event="workflow_dispatch", title="Retry nightly-next (1 of 2)"),
                loop_run(3, status="completed"), loop_run(4, event="workflow_dispatch", title="Nightly"),
                loop_run(500)]
        api = Api(runs, {1: [one("in_progress", "cmux15-glaeda")]})
        host, pin, why = pick_mod.evaluate(env(), api, now=NOW)
        self.assertEqual(host, "ultra1", why)
        self.assertEqual(len(api.paths), 4, api.paths)
        self.assertIn("actions/runs/3/jobs?filter=latest&per_page=100", api.paths, "a finished push run is read")
        self.assertFalse(any("/runs/500/" in p or "/runs/4/" in p for p in api.paths), api.paths)

    def test_a_census_as_old_as_the_run_reads_it_still_picks(self):
        """vars are read when the run starts and the pick runs after resolve (~13 min); runs 44990363506,
        44992267457 and 44993740115 (2026-11-22) read censuses 30, 36 and 23 min old, fell back every time and
        queued in one group: the second Mac never built. Busy comes from the live jobs listing, not the census."""
        building = {1: [one("in_progress", "cmux15-glaeda")]}
        for minutes in (23, 36, 45):
            with self.subTest(minutes=minutes):
                environment = env() | {"CI_RUNNER_STATE": census(fleet(), NOW - dt.timedelta(minutes=minutes))}
                host, pin, why = pick_mod.evaluate(environment, Api([loop_run(1)], building), now=NOW)
                self.assertEqual(host, "ultra1", why)

    def test_any_failure_is_cmux15_and_the_label_alone(self):
        def boom(path):
            raise OSError("HTTP 403: API rate limit exceeded")
        cases = {
            "a failed read": (env(), boom),
            "no census": (env() | {"CI_RUNNER_STATE": ""}, Api([], {})),
            "a stale census": (env() | {"CI_RUNNER_STATE": census(fleet(), NOW - dt.timedelta(hours=1))}, Api([], {})),
            "a malformed listing": (env(), lambda path: {"nope": 1}),
            "no token and no reader": (env(), None),
            "too many open runs": (env(), Api([loop_run(i) for i in range(1, 9)], {})),
        }
        for name, (environment, api) in cases.items():
            with self.subTest(name):
                host, pin, why = pick_mod.evaluate(environment, api, now=NOW)
                self.assertEqual((host, pin), ("cmux15", LABEL_ONLY), why)

    def test_the_spare_token_reads_first_and_a_403_moves_to_github_token(self):
        import io
        import urllib.error
        from unittest import mock
        seen = []

        def fake(request, timeout, follow_redirects=False, raise_errors=False):
            token = request.headers["Authorization"].split()[-1]
            seen.append(token)
            if token == "spare":
                raise urllib.error.HTTPError(request.full_url, 403, "Forbidden", {}, io.BytesIO(b""))
            return 200, json.dumps({"workflow_runs": []}).encode(), {}
        with mock.patch.object(pick_mod.deadline_http, "request", side_effect=fake):
            host, pin, why = pick_mod.evaluate(env(SPARE_READ_TOKEN="spare", GITHUB_TOKEN="gh"), now=NOW)
        self.assertEqual(seen, ["spare", "gh"])
        self.assertEqual(host, "cmux15")
        self.assertNotIn("pick failed", why)

    def test_main_writes_host_and_pin(self):
        import os
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as scratch:
            out = Path(scratch) / "out"
            with mock.patch.object(pick_mod, "evaluate", return_value=("ultra1", '["glaeda-trusted-next-signing","glaeda-runner-ultra1-glaeda"]', "ok")):
                pick_mod.main({"GITHUB_OUTPUT": str(out)})
            text = out.read_text()
            self.assertIn("host=ultra1\n", text)
            self.assertIn('pin=["glaeda-trusted-next-signing","glaeda-runner-ultra1-glaeda"]\n', text)
            out.unlink()
            with mock.patch.object(pick_mod, "evaluate", return_value=("evil", '["macos-26"]', "x")):
                pick_mod.main({"GITHUB_OUTPUT": str(out)})
            self.assertIn(f"host=cmux15\npin={LABEL_ONLY}\n", out.read_text())
            del os


class WorkflowTests(unittest.TestCase):
    """nightly.yml: the pick job before nightly-next-one, and nightly-next-one's runs-on and group read it."""

    @classmethod
    def setUpClass(cls):
        import yaml
        cls.jobs = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]
        cls.one = cls.jobs["nightly-next-one"]
        cls.pick = cls.jobs["pick-nightly-next-signer"]

    def test_the_pick_uses_only_the_protected_routing_key_before_the_build(self):
        import yaml
        text = yaml.safe_dump(self.pick)
        # One secret: the glaeda-route App key for a read-only (contents, actions) token, as decide mints on the same
        # runner, so the pick has its own API budget (run 45575194160's pick 403d on github.token's).
        self.assertEqual(set(re.findall(r"secrets\.\w+", text)), {"secrets.GLAEDA_ROUTE_APP_KEY"})
        self.assertEqual(self.pick["environment"], {"name": "ci-routing-agent", "deployment": False})
        self.assertIn("github.ref == 'refs/heads/nightly-next'", self.pick["if"])
        self.assertEqual(self.pick.get("permissions"), {"actions": "read", "contents": "read"})
        self.assertIn("pick-nightly-next-signer", self.one["needs"])
        self.assertIn("vars.CI_NIGHTLY_MINI == ''", self.pick["if"])
        self.assertTrue(self.pick.get("continue-on-error"))
        self.assertLessEqual(int(self.pick.get("timeout-minutes", 99)), 5)
        self.assertIn("nightly_next_signer_pick.py", text)
        self.assertIn("vars.CI_RUNNER_STATE", text)

    def test_the_finish_steps_are_nightly_next_one_s(self):
        names = {step.get("name") for step in self.one["steps"]}
        for step in pick_mod.FINISH_STEPS:
            self.assertIn(step, names)


if __name__ == "__main__":
    unittest.main()
