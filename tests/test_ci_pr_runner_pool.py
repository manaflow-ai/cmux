#!/usr/bin/env python3
"""Tests for scripts/ci/pr_runner_pool.py and its wiring (no network)."""

from __future__ import annotations

import datetime as dt
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


pool = load("pr_runner_pool", ROOT / "scripts/ci/pr_runner_pool.py")
janitor = load("queue_janitor", ROOT / "scripts/ci/queue_janitor.py")

NOW = dt.datetime(2026, 9, 24, 10, 30, tzinfo=dt.timezone.utc)
SMALL, LARGE, OLD = pool.DEFAULT_RUNNER, pool.LARGE_RUNNER, pool.MACOS_15_RUNNER
XCODE_15 = "/Applications/Xcode_26.3.app"
PINS = {"CMUX_CI_XCODE_APP_MACOS_15": XCODE_15}


FORK_SETTINGS = {"lane": SMALL, "overflow": "", "order": "", "max_queued": ""}


def backlog(small=21, large=0, old=4, large_reserved=0, old_reserved=0, age=5, settings=None) -> dict:
    return {
        "version": 1,
        "settings": dict(FORK_SETTINGS if settings is None else settings),
        "generated_at": (NOW - dt.timedelta(minutes=age)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pools": {
            SMALL: {"queued": small, "running": 10},
            LARGE: {"queued": large, "running": 1, "reserved_queued": large_reserved},
            OLD: {"queued": old, "running": 10, "reserved_queued": old_reserved},
        },
    }


def choose(snap, *, event="pull_request", head="manaflow-ai/cmux", default=SMALL,
           overflow="", order="", max_queued="", pins=PINS, fetch=None, routed=0):
    def count_routed(since):
        if isinstance(routed, Exception):
            raise routed
        return routed
    return pool.choose(
        event=event, repo="manaflow-ai/cmux", head_repo=head, default_runner=default,
        overflow=overflow, order=order, max_queued=max_queued, xcode_pins=pins,
        fetch=fetch or (lambda: snap), count_routed=count_routed, now=NOW,
    )[0]


class PreferenceOrder(unittest.TestCase):
    def test_12vcpu_first_while_it_has_headroom(self):
        choice = choose(backlog(small=0, large=0))
        self.assertEqual((choice.runner, choice.xcode_app), (LARGE, ""))

    def test_6vcpu_26_when_12vcpu_is_backed_up(self):
        choice = choose(backlog(small=1, large=5))
        self.assertEqual((choice.runner, choice.xcode_app), (SMALL, ""))

    def test_macos_15_last_with_its_own_xcode(self):
        # The measured 2026-09-24 10:08Z backlog, with 12vcpu also full.
        choice = choose(backlog(small=21, large=5, old=2))
        self.assertEqual((choice.runner, choice.xcode_app), (OLD, XCODE_15))

    def test_fewest_queued_when_nothing_has_headroom(self):
        self.assertEqual(choose(backlog(small=21, large=6, old=4)).runner, OLD)
        self.assertEqual(choose(backlog(small=5, large=6, old=9)).runner, SMALL)
        # A tie goes to the earlier pool in the order.
        self.assertEqual(choose(backlog(small=7, large=7, old=7)).runner, LARGE)

    def test_a_queued_release_or_nightly_job_reserves_its_pool(self):
        self.assertEqual(choose(backlog(small=0, large=0, large_reserved=1)).runner, SMALL)
        self.assertEqual(choose(backlog(small=9, large=0, old=0, large_reserved=1, old_reserved=1)).runner, SMALL)

    def test_order_and_threshold_come_from_variables(self):
        order = f"{SMALL},{OLD}"
        self.assertEqual(choose(backlog(small=2, old=0), order=order).runner, SMALL)
        self.assertEqual(choose(backlog(small=2, old=0), order=order, max_queued="2").runner, OLD)
        self.assertEqual(choose(backlog(small=0, large=0), order=OLD).runner, OLD)

    def test_runs_since_the_snapshot_spread_a_burst(self):
        # 12vcpu has 9 of its 10 slots idle (1 running), 6vcpu 26 is backed
        # up, macOS 15 is full with nothing queued: pushes after a sweep fill
        # 12vcpu's idle slots, then its threshold, then queue on macOS 15.
        snap = backlog(small=6, large=0, old=0)
        snap["pools"][OLD]["running"] = pool.POOL_CAPACITY
        picks = [choose(snap, routed=n).runner for n in range(16)]
        self.assertEqual(picks, [LARGE] * 12 + [OLD] * 3 + [LARGE])
        self.assertIn("replaying 4", choose(backlog(small=6), routed=4).reason)

    def test_idle_slots_absorb_recent_runs(self):
        # The 11:45Z proof run: 12vcpu 0 queued and 2 running, four runs
        # created in the minute since the sweep. They fit its idle slots.
        snap = backlog(small=2, large=0, old=1)
        snap["pools"][LARGE]["running"] = 2
        self.assertEqual(choose(snap, routed=4).runner, LARGE)
        self.assertEqual(pool.effective_queue({"queued": 0, "running": 2}, 8), 0)
        self.assertEqual(pool.effective_queue({"queued": 0, "running": 2}, 10), 2)
        self.assertEqual(pool.effective_queue({"queued": 1, "running": 3}, 2), 3)

    def test_only_runs_still_in_flight_are_replayed(self):
        runs = [{"id": 1, "status": "queued"}, {"id": 2, "status": "in_progress"},
                {"id": 3, "status": "completed"}, {"id": 4, "status": "pending"}, {"id": 5, "status": "waiting"}]
        self.assertEqual(pool.count_in_flight(runs, exclude_run_id=2), 3)

    def test_counting_errors_keep_the_default(self):
        choice = choose(backlog(), routed=RuntimeError("GET /actions/workflows/ci.yml/runs failed (500)"))
        self.assertEqual((choice.runner, choice.xcode_app), ("", ""))
        self.assertIn("500", choice.reason)

    def test_macos_15_needs_an_xcode_pin(self):
        choice = choose(backlog(small=21, large=5, old=0), pins={})
        self.assertEqual(choice.runner, LARGE)  # fewest queued among the usable pools
        self.assertIn("no Xcode pin", choice.reason)
        self.assertEqual(choose(backlog(), order=OLD, pins={}).runner, "")


class FailSafe(unittest.TestCase):
    def assert_default(self, choice):
        self.assertEqual((choice.runner, choice.xcode_app), ("", ""), choice.reason)

    def test_only_same_repository_pull_requests_move(self):
        self.assert_default(choose(backlog(), event="push"))
        self.assert_default(choose(backlog(), event="merge_group"))
        self.assert_default(choose(backlog(), event="workflow_dispatch"))
        self.assert_default(choose(backlog(), head=""))
        self.assert_default(choose(backlog(), head="someone/cmux", event="push"))

    def test_fork_heads_follow_the_settings_the_janitor_copied(self):
        # A fork run sees no repository variables: empty lane, no Xcode pins,
        # and whatever reached its env is ignored in favour of the snapshot.
        fork = dict(head="someone/cmux", default="", pins={}, overflow="0", order=OLD)
        self.assertEqual(choose(backlog(small=0, large=0), **fork).runner, LARGE)
        choice = choose(backlog(small=21, large=5, old=0), **fork)
        self.assertEqual((choice.runner, choice.xcode_app), (OLD, ""))
        self.assertIn("fork head", choice.reason)
        copied = dict(FORK_SETTINGS, order=f"{OLD},{SMALL}")
        self.assertEqual(choose(backlog(small=0, old=0, settings=copied), **fork).runner, OLD)
        # The kill switch and the lane reach fork runs through the snapshot.
        for off in (dict(FORK_SETTINGS, overflow="0"), dict(FORK_SETTINGS, lane=""),
                    dict(FORK_SETTINGS, lane=OLD), dict(FORK_SETTINGS, order="warp-macos-26-arm64-12x")):
            self.assert_default(choose(backlog(settings=off), **fork))
        no_settings = backlog()
        no_settings.pop("settings")
        self.assert_default(choose(no_settings, **fork))
        self.assert_default(choose(None, **fork))

    def test_fork_heads_only_use_ephemeral_pools(self):
        self.assertTrue(all(label.startswith(pool.EPHEMERAL_PREFIX) for label in pool.DEFAULT_ORDER))
        owned = "cmux-owned-mac-mini"
        original = dict(pool.POOLS)
        pool.POOLS[owned] = ""
        try:
            copied = dict(FORK_SETTINGS, order=f"{owned},{SMALL}")
            snap = backlog(small=0, settings=copied)
            self.assertEqual(choose(snap, head="someone/cmux", default="").runner, SMALL)
            self.assert_default(choose(backlog(settings=dict(FORK_SETTINGS, order=owned)),
                                       head="someone/cmux", default=""))
            # A same-repository run may use it.
            self.assertEqual(choose(snap, order=f"{owned},{SMALL}").runner, owned)
        finally:
            pool.POOLS.clear()
            pool.POOLS.update(original)

    def test_only_moves_off_the_6vcpu_macos_26_lane(self):
        self.assert_default(choose(backlog(), default=""))
        self.assert_default(choose(backlog(), default=OLD))

    def test_kill_switch_and_invalid_settings(self):
        self.assert_default(choose(backlog(), overflow="0"))
        for bad in ({"order": "warp-macos-26-arm64-12x"}, {"order": f"{LARGE},{LARGE}"},
                    {"max_queued": "0"}, {"max_queued": "many"}):
            self.assert_default(choose(backlog(), **bad))

    def test_unknown_or_stale_snapshot(self):
        self.assert_default(choose(None))
        self.assert_default(choose({"pools": "nope"}))
        self.assert_default(choose(backlog(age=pool.MAX_SNAPSHOT_MINUTES + 1)))
        self.assert_default(choose(backlog(age=-30)))
        self.assert_default(choose({**backlog(), "generated_at": "yesterday"}))
        self.assert_default(choose({**backlog(), "pools": {LARGE: {"queued": "x"}}}))

    def test_fetch_errors_keep_the_default(self):
        def boom():
            raise RuntimeError("GET /actions/artifacts failed (403)")
        choice = choose(None, fetch=boom)
        self.assert_default(choice)
        self.assertIn("403", choice.reason)

    def test_main_writes_outputs_and_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            snap_path = Path(tmp, "snap.json")
            fresh = backlog(small=21, large=0)
            fresh["generated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            snap_path.write_text(json.dumps(fresh))
            out, summary = Path(tmp, "out"), Path(tmp, "summary")
            env = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "HEAD_REPO": "manaflow-ai/cmux", "DEFAULT_RUNNER": SMALL,
                   "CMUX_CI_XCODE_APP_MACOS_15": XCODE_15,
                   "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary)}
            stdout = io.StringIO()
            old, sys.stdout = sys.stdout, stdout
            try:
                self.assertEqual(pool.main(["--snapshot", str(snap_path)], env), 0)
            finally:
                sys.stdout = old
            self.assertEqual(out.read_text(), f"runner={LARGE}\nxcode_app=\n")
            text = summary.read_text()
            self.assertIn(f"Pool: `{LARGE}`", text)
            self.assertIn(f"{SMALL}: 21 queued, 10 running", text)


class TrustedArtifact(unittest.TestCase):
    def artifact(self, **run):
        base = {"head_branch": "main", "repository_id": 1, "head_repository_id": 1}
        return {"expired": False, "workflow_run": {**base, **run}}

    def test_only_main_of_this_repository(self):
        self.assertEqual(pool.SNAPSHOT_BRANCH, "main")
        self.assertTrue(pool.trusted_snapshot_artifact(self.artifact(), "main"))
        self.assertFalse(pool.trusted_snapshot_artifact(self.artifact(head_branch="feature"), "main"))
        self.assertFalse(pool.trusted_snapshot_artifact(self.artifact(head_repository_id=2), "main"))
        self.assertFalse(pool.trusted_snapshot_artifact(self.artifact(repository_id=None, head_repository_id=None),
                                                        "main"))
        self.assertFalse(pool.trusted_snapshot_artifact({**self.artifact(), "expired": True}, "main"))
        self.assertFalse(pool.trusted_snapshot_artifact({"expired": False}, "main"))


class JanitorSnapshot(unittest.TestCase):
    def job(self, label, status, created="2026-09-24T09:00:00Z"):
        return {"labels": [label], "status": status, "created_at": created, "name": "x"}

    def test_counts_per_pool_and_reserved_demand(self):
        runs = [
            {"id": 1, "name": "CI", "path": ".github/workflows/ci.yml"},
            {"id": 2, "name": "Nightly", "path": ".github/workflows/nightly.yml"},
        ]
        jobs = {
            1: [self.job(SMALL, "queued", "2026-09-24T09:20:00Z"), self.job(SMALL, "queued"),
                self.job(SMALL, "in_progress"), self.job(OLD, "completed"),
                self.job("blacksmith-4vcpu-ubuntu-2404", "queued")],
            2: [self.job(LARGE, "queued"), self.job(LARGE, "in_progress"), self.job(OLD, "waiting")],
        }
        snap = janitor.pool_load_snapshot(runs, jobs, now=NOW, settings=FORK_SETTINGS)
        self.assertEqual(snap["settings"], FORK_SETTINGS)
        self.assertEqual(snap["generated_at"], "2026-09-24T10:30:00Z")
        self.assertEqual(snap["pools"][SMALL],
                         {"queued": 2, "running": 1, "reserved_queued": 0, "oldest_queued_minutes": 90})
        self.assertEqual(snap["pools"][LARGE]["reserved_queued"], 1)
        self.assertNotIn(OLD, snap["pools"])
        self.assertNotIn("blacksmith-4vcpu-ubuntu-2404", snap["pools"])
        # The picker reads what the janitor writes.
        # 12vcpu is reserved by the queued nightly job; 6vcpu 26 has headroom.
        self.assertEqual(choose(snap).runner, SMALL)

    def test_workflow_publishes_the_snapshot(self):
        workflow = yaml.safe_load((WORKFLOWS / "ci-queue-janitor.yml").read_text())
        steps = workflow["jobs"]["sweep"]["steps"]
        sweep = next(step for step in steps if "queue_janitor.py" in str(step.get("run")))
        self.assertIn("macos-pool-load.json", sweep["env"]["POOL_LOAD_OUT"])
        for name, key in janitor.POOL_SETTINGS_ENV.items():
            self.assertIn(key, FORK_SETTINGS)
        self.assertEqual(sweep["env"]["PR_POOL_LANE"], "${{ vars.MACOS_RUNNER_PR }}")
        self.assertEqual(sweep["env"]["PR_POOL_OVERFLOW"], "${{ vars.CI_PR_POOL_OVERFLOW }}")
        self.assertEqual(sweep["env"]["PR_POOL_ORDER"], "${{ vars.CI_PR_POOL_ORDER }}")
        self.assertEqual(sweep["env"]["PR_POOL_MAX_QUEUED"], "${{ vars.CI_PR_POOL_MAX_QUEUED }}")
        upload = next(step for step in steps if "upload-artifact" in str(step.get("uses")))
        self.assertEqual(upload["with"]["name"], pool.ARTIFACT_NAME)
        self.assertTrue(upload["with"]["path"].endswith(pool.SNAPSHOT_FILE))


# The pull-request lane, wherever its event condition puts it: compile admission
# also takes it for main's full-suite dispatch (#14158), where the inputs are empty.
PR_ROUTE = re.compile(r"&& \((?P<lane>[^()]*vars\.MACOS_RUNNER_PR[^()]*)\)")


class Wiring(unittest.TestCase):
    """Every pull-request macOS route in one CI run reads the one chosen pool."""

    def workflow(self, name):
        return yaml.safe_load((WORKFLOWS / name).read_text())

    def test_changes_job_chooses_once(self):
        changes = self.workflow("ci.yml")["jobs"]["changes"]
        self.assertEqual(changes["outputs"]["macos_pr_runner"], "${{ steps.macos-pool.outputs.runner }}")
        self.assertEqual(changes["outputs"]["macos_pr_xcode_app"], "${{ steps.macos-pool.outputs.xcode_app }}")
        self.assertEqual(changes["permissions"]["actions"], "read")
        step = next(step for step in changes["steps"] if step.get("id") == "macos-pool")
        self.assertIs(step["continue-on-error"], True)
        self.assertEqual(step["run"], "python3 scripts/ci/pr_runner_pool.py")
        self.assertEqual(step["env"]["DEFAULT_RUNNER"], "${{ vars.MACOS_RUNNER_PR }}")

    def lanes(self, name):
        text = (WORKFLOWS / name).read_text()
        return [match.group("lane") for match in PR_ROUTE.finditer(text)]

    def test_every_pr_route_in_the_run_reads_the_choice(self):
        expected = {
            "ci.yml": "needs.changes.outputs.macos_pr_runner || vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15'",
            "ci-macos.yml": "inputs.pr_runner || vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15'",
            "cli-pipe-regressions.yml": "inputs.pr_runner || vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15'",
            "remote-daemon.yml": "inputs.pr_runner || vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15'",
        }
        for name, lane in expected.items():
            lanes = self.lanes(name)
            self.assertTrue(lanes, name)
            self.assertEqual(set(lanes), {lane}, name)

    def test_callers_pass_the_choice(self):
        jobs = self.workflow("ci.yml")["jobs"]
        runner = "${{ needs.changes.outputs.macos_pr_runner }}"
        xcode = "${{ needs.changes.outputs.macos_pr_xcode_app }}"
        self.assertEqual(jobs["macos"]["with"]["pr_runner"], runner)
        self.assertEqual(jobs["macos"]["with"]["pr_xcode_app"], xcode)
        self.assertEqual(jobs["cli"]["with"]["pr_runner"], runner)
        self.assertEqual(jobs["cli"]["with"]["pr_xcode_app"], xcode)
        self.assertEqual(jobs["remote-daemon"]["with"]["pr_runner"], runner)
        for name in ("macos", "cli", "remote-daemon", "claude-wrapper"):
            needs = jobs[name]["needs"]
            self.assertIn("changes", [needs] if isinstance(needs, str) else needs, name)

    def test_xcode_pins_follow_the_chosen_pool(self):
        lane = "(inputs.pr_xcode_app || vars.CMUX_CI_XCODE_APP_PR || vars.CMUX_CI_XCODE_APP_MACOS_15)"
        pin = f"${{{{ github.event_name == 'pull_request' && {lane} || vars.CMUX_CI_XCODE_APP_MACOS_15 }}}}"
        main_dispatch = ("${{ (github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch' "
                         f"&& github.ref == 'refs/heads/main') && {lane} || vars.CMUX_CI_XCODE_APP_MACOS_15 }}}}")
        macos = self.workflow("ci-macos.yml")["jobs"]
        for job in ("macos-compile-admission", "tests-build-and-lag"):
            self.assertEqual(macos[job]["env"]["CMUX_CI_XCODE_APP"], main_dispatch, job)
        cli = self.workflow("cli-pipe-regressions.yml")["jobs"]["cli-pipe-regressions"]
        self.assertEqual(cli["env"]["CMUX_CI_XCODE_APP"], pin)

    def test_build_input_fingerprint_keys_on_the_chosen_xcode(self):
        # A run moved to the macOS 15 pool compiles under another Xcode, so it
        # must not skip its compile on a fingerprint taken under the lane's.
        steps = self.workflow("ci.yml")["jobs"]["changes"]["steps"]
        ids = [step.get("id") for step in steps]
        for step_id in ("inputs", "unchanged_inputs"):
            self.assertLess(ids.index("macos-pool"), ids.index(step_id))
            step = steps[ids.index(step_id)]
            self.assertEqual(step["env"]["XCODE_APP"],
                             "${{ steps.macos-pool.outputs.xcode_app || vars.CMUX_CI_XCODE_APP_PR "
                             "|| vars.CMUX_CI_XCODE_APP_MACOS_15 }}", step_id)

    def test_reusable_inputs_default_to_todays_route(self):
        for name, keys in (("ci-macos.yml", ("pr_runner", "pr_xcode_app")),
                           ("cli-pipe-regressions.yml", ("pr_runner", "pr_xcode_app")),
                           ("remote-daemon.yml", ("pr_runner",))):
            # PyYAML reads the `on:` key as True.
            inputs = self.workflow(name)[True]["workflow_call"]["inputs"]
            for key in keys:
                self.assertEqual((inputs[key]["required"], inputs[key]["default"], inputs[key]["type"]),
                                 (False, "", "string"), (name, key))

    def test_package_tests_stay_off_the_pr_lane(self):
        # swift-package-tests builds the SDK 15 helper and must never move.
        block = yaml.safe_dump(self.workflow("ci-macos.yml")["jobs"]["swift-package-tests"])
        self.assertNotIn("pr_runner", block)


if __name__ == "__main__":
    unittest.main(verbosity=2)
