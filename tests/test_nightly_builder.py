#!/usr/bin/env python3
"""The dedicated cmux-next nightly builder admits only the NEXT app build and reports its health."""
import datetime as dt
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import nightly_builder as nb  # noqa: E402

GIB = 1024 ** 3
NOW = dt.datetime(2026, 10, 20, 8, 0, tzinfo=dt.timezone.utc)


def job_env(**over):
    env = {
        "GITHUB_REPOSITORY": "manaflow-ai/cmux",
        "GITHUB_WORKFLOW_REF": "manaflow-ai/cmux/.github/workflows/nightly.yml@refs/heads/nightly-next",
        "GITHUB_JOB": "build-nightly-app",
        "GITHUB_EVENT_NAME": "push",
        "GITHUB_REF": "refs/heads/nightly-next",
    }
    env.update(over)
    return env


class AdmitTest(unittest.TestCase):
    def test_admits_the_next_app_build(self):
        ok, reason = nb.admit(job_env(), free_bytes=100 * GIB)
        self.assertTrue(ok, reason)

    def test_refuses_every_other_job(self):
        cases = {
            "seed job": job_env(GITHUB_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/seed-derived-data.yml@refs/heads/main",
                                GITHUB_JOB="seed", GITHUB_REF="refs/heads/main"),
            "main NIGHTLY": job_env(GITHUB_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/nightly.yml@refs/heads/main",
                                    GITHUB_REF="refs/heads/main"),
            "other job in nightly.yml": job_env(GITHUB_JOB="build-sign-notarize-nightly"),
            "pull request": job_env(GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/1/merge"),
            "dispatch": job_env(GITHUB_EVENT_NAME="workflow_dispatch"),
            "fork": job_env(GITHUB_REPOSITORY="someone/cmux"),
            "test workflow": job_env(GITHUB_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/cmux-next.yml@refs/heads/nightly-next",
                                     GITHUB_JOB="test"),
            "missing env": {},
        }
        for name, env in cases.items():
            with self.subTest(name):
                ok, reason = nb.admit(env, free_bytes=100 * GIB)
                self.assertFalse(ok)
                self.assertTrue(reason)

    def test_refuses_on_low_disk(self):
        ok, reason = nb.admit(job_env(), free_bytes=10 * GIB)
        self.assertFalse(ok)
        self.assertIn("disk", reason)


def gate_env(**over):
    env = {
        "GITHUB_REPOSITORY": "manaflow-ai/cmux",
        "GITHUB_WORKFLOW_REF": "manaflow-ai/cmux/.github/workflows/cmux-tui-artifacts.yml@refs/heads/feat-cmux-next",
        "GITHUB_JOB": "cmux-next-daemon-tests",
        "GITHUB_EVENT_NAME": "push",
        "GITHUB_REF": "refs/heads/feat-cmux-next",
    }
    env.update(over)
    return env


class GateRoleTest(unittest.TestCase):
    """The next-gate runner admits only the nightly gate's daemon tests, and the
    role comes from the hook script's argument, never from the job's env."""

    def hook(self, env, *args):
        # The runner's job-started hook runs the CLI; a refusal must exit non-zero
        # before any disk check, so these cases do not depend on this disk.
        return subprocess.run([sys.executable, str(ROOT / "scripts/ci/nightly_builder.py"), "admit", *args],
                              env={**env, "PATH": os.environ.get("PATH", ""),
                                   "NIGHTLY_BUILDER_LOG": os.devnull},
                              capture_output=True, text=True)

    def test_admits_the_gate_daemon_tests(self):
        ok, reason = nb.admit(gate_env(), free_bytes=100 * GIB, role="next-gate")
        self.assertTrue(ok, reason)

    def test_gate_runner_refuses_other_jobs(self):
        cases = {
            "nightly app build": job_env(),
            "pin branch daemon tests": gate_env(GITHUB_REF="refs/heads/cmux-tui-pin-abc"),
            "pull request daemon tests": gate_env(GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/1/merge"),
            "dispatch": gate_env(GITHUB_EVENT_NAME="workflow_dispatch"),
            "build leg": gate_env(GITHUB_JOB="build"),
            "fork": gate_env(GITHUB_REPOSITORY="someone/cmux"),
        }
        for name, env in cases.items():
            with self.subTest(name):
                result = self.hook(env, "--role", "next-gate")
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_job_env_cannot_choose_the_gate_role(self):
        # The nightly-app runner (no --role) refuses the gate job even if the job sets a role.
        result = self.hook(gate_env(NIGHTLY_BUILDER_ROLE="next-gate"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not .github/workflows/nightly.yml", result.stderr)

    def test_unknown_role_refuses(self):
        ok, reason = nb.admit(gate_env(), free_bytes=100 * GIB, role="seed")
        self.assertFalse(ok)
        self.assertIn("role", reason)


def run(conclusion, sha, created, status="completed"):
    return {"conclusion": conclusion, "status": status, "head_sha": sha,
            "created_at": created.strftime("%Y-%m-%dT%H:%M:%SZ"), "html_url": "https://github.com/x/1"}


class HealthTest(unittest.TestCase):
    def base_state(self, **over):
        state = {
            "runner_alive": True,
            "free_bytes": 100 * GIB,
            "heads": {"feat-cmux-next": "a" * 40, "nightly-next": "b" * 40},
            "nightly_next_moved_at": (NOW - dt.timedelta(minutes=20)).isoformat(),
            "runs": [run("success", "b" * 40, NOW - dt.timedelta(minutes=19))],
        }
        state.update(over)
        return state

    def test_ok(self):
        self.assertEqual(nb.health(self.base_state(), NOW), ("ok", []))

    def test_runner_down(self):
        status, reasons = nb.health(self.base_state(runner_alive=False), NOW)
        self.assertEqual(status, "alert")
        self.assertIn("runner-down", reasons)

    def test_disk_low(self):
        status, reasons = nb.health(self.base_state(free_bytes=20 * GIB), NOW)
        self.assertIn("disk-low", reasons)

    def test_build_failed(self):
        status, reasons = nb.health(self.base_state(runs=[run("failure", "b" * 40, NOW)]), NOW)
        self.assertIn("build-failed", reasons)

    def test_in_progress_build_is_not_stale(self):
        state = self.base_state(nightly_next_moved_at=(NOW - dt.timedelta(minutes=50)).isoformat(),
                                runs=[run(None, "b" * 40, NOW - dt.timedelta(minutes=50), status="in_progress")])
        self.assertEqual(nb.health(state, NOW), ("ok", []))

    def test_stale_when_no_success_long_after_move(self):
        state = self.base_state(nightly_next_moved_at=(NOW - dt.timedelta(minutes=90)).isoformat(),
                                runs=[run(None, "b" * 40, NOW - dt.timedelta(minutes=90), status="in_progress")])
        status, reasons = nb.health(state, NOW)
        self.assertEqual(status, "alert")
        self.assertIn("stale", reasons)

    def test_cancelled_superseded_run_is_not_a_failure(self):
        state = self.base_state(runs=[run("cancelled", "c" * 40, NOW), run("success", "b" * 40, NOW)])
        self.assertEqual(nb.health(state, NOW), ("ok", []))


class ChangeTest(unittest.TestCase):
    def test_moved_at_updates_only_when_head_changes(self):
        prev = {"heads": {"nightly-next": "b" * 40}, "nightly_next_moved_at": "2026-10-20T06:00:00+00:00"}
        same = nb.track_moves(prev, {"nightly-next": "b" * 40}, NOW)
        self.assertEqual(same, "2026-10-20T06:00:00+00:00")
        moved = nb.track_moves(prev, {"nightly-next": "c" * 40}, NOW)
        self.assertEqual(moved, NOW.isoformat())

    def test_first_tick_counts_as_moved_now(self):
        self.assertEqual(nb.track_moves({}, {"nightly-next": "b" * 40}, NOW), NOW.isoformat())


class PruneTest(unittest.TestCase):
    def test_prunes_old_logs_and_temp_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            runner = Path(tmp)
            old = time.time() - 10 * 86400
            paths = {
                "old_diag": runner / "_diag/Runner_old.log",
                "new_diag": runner / "_diag/Runner_new.log",
                "old_temp": runner / "_work/_temp/old.sh",
                "new_temp": runner / "_work/_temp/new.sh",
                "cache": runner / "_work/cmux/cmux/.spm-cache/old.pkg",
            }
            for path in paths.values():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("x")
            for key in ("old_diag", "old_temp", "cache"):
                os.utime(paths[key], (old, old))
            removed = nb.prune(runner, now=time.time())
            self.assertFalse(paths["old_diag"].exists())
            self.assertFalse(paths["old_temp"].exists())
            self.assertTrue(paths["new_diag"].exists())
            self.assertTrue(paths["new_temp"].exists())
            self.assertTrue(paths["cache"].exists())
            self.assertEqual(len(removed), 2)



class GlaedaFloor(unittest.TestCase):
    """glaeda passes the runner's own floor (GLAEDA_MIN_FREE_GIB): the builder admits by that one number."""

    def test_the_glaeda_floor_is_used_when_valid(self) -> None:
        self.assertEqual(nb.min_free_bytes({"GLAEDA_MIN_FREE_GIB": "40"}), 40 * GIB)
        self.assertEqual(nb.min_free_bytes({"GLAEDA_MIN_FREE_GIB": "25.5"}), int(25.5 * GIB))
        for bad in ("", "0", "-1", "nan", "inf", "x", "20000"):
            with self.subTest(bad=bad):
                self.assertEqual(nb.min_free_bytes({"GLAEDA_MIN_FREE_GIB": bad}), nb.MIN_FREE_BYTES)
        self.assertEqual(nb.min_free_bytes({}), nb.MIN_FREE_BYTES)

    def test_admission_follows_the_glaeda_floor(self) -> None:
        floor = nb.min_free_bytes({"GLAEDA_MIN_FREE_GIB": "30"})
        ok, _ = nb.admit(job_env(), free_bytes=35 * GIB, min_free=floor)
        self.assertTrue(ok)
        ok, reason = nb.admit(job_env(), free_bytes=25 * GIB, min_free=floor)
        self.assertFalse(ok)
        self.assertIn("below 30 GiB", reason)


if __name__ == "__main__":
    unittest.main()
