#!/usr/bin/env python3
"""The cmux_next_ daemon tests that gate nightly-next run on Blacksmith Linux.

Leo, 2026-10-26: "I THOUGHT THESE COULD JUST GO ON LINUX".

cmux-tui-artifacts.yml's cmux-next-daemon-tests job is the nightly-next
promotion gate: its pass writes tree/<key>/daemon-tests.json
(publish-tree-tested), which request-nightly-next.sh requires. It ran on the
owned Macs (the promote pool the Release compile also needs, then the side
lane) and queued there for 20+ minutes while nightly-next waited. None of
the cmux_next_ tests is gated to macOS, and cmux-tui.yml's Linux job runs the
whole workspace, so the gate takes Blacksmith Linux at 32 vCPU on every
event and attempt, and a Linux pass writes the marker (naming its OS).

The tests that genuinely need macOS (acpmux's Keychain and Seatbelt tests,
the idle wakeup counter) run in cmux-next-daemon-macos-shadow: it gates
nothing, no job needs it, and a red there leaves the run green.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from test_ci_tui_routes_avoid_nightly_label import (  # noqa: E402
    DAEMON_LABEL,
    LIGHT_LABEL,
    PIN_LABEL,
    PROMOTE_LABEL,
    SIDE_LABEL,
    contexts,
    route,
)

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
LINUX_LABEL = "blacksmith-32vcpu-ubuntu-2404"
JOB_NAME = "cmux_next_ daemon tests (Linux)"
SHADOW = "cmux-next-daemon-macos-shadow"
MAC_ONLY_TESTS = ("no_keychain", "router_no_keychain", "remote_sandbox", "remote_sandbox_canary", "idle_wakeups")


def jobs() -> dict:
    return yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]


def step(job: dict, name: str) -> dict:
    return next(s for s in job["steps"] if s.get("name") == name)


def flat(text: str) -> str:
    return " ".join(text.split())


class DaemonTestsLinuxTests(unittest.TestCase):
    def test_the_gate_runs_on_blacksmith_linux_whatever_the_pool_variables_say(self) -> None:
        runs_on = jobs()["cmux-next-daemon-tests"]["runs-on"]
        for overrides in ({}, {"CI_NEXT_DAEMON_POOL": DAEMON_LABEL}, {"CI_PIN_DAEMON_POOL": PIN_LABEL},
                          {"CI_PR_POOL_OWNED": ""}, {"CI_NEXT_PROMOTE_POOL": ""}):
            for context in contexts(**overrides):
                context["inputs.macos_runner"] = "blacksmith-6vcpu-macos-26"
                label = route(runs_on, context)
                if context["github.repository_owner"] != "manaflow-ai":
                    self.assertEqual(label, "ubuntu-24.04", context)
                else:
                    self.assertEqual(label, LINUX_LABEL, (overrides, context))

    def test_the_job_keeps_its_id_and_linux_setup(self) -> None:
        daemon = jobs()["cmux-next-daemon-tests"]
        # cmux_tui_publisher_testing.py finds the job by its name's prefix.
        self.assertEqual(daemon["name"], JOB_NAME)
        self.assertEqual(daemon["outputs"]["runner_os"].replace(" ", ""), "${{runner.os}}")
        deps = step(daemon, "Install Linux build dependencies")
        self.assertIn("runner.os == 'Linux'", deps["if"])
        self.assertIn("libclang-dev", deps["run"])
        cache = step(daemon, "Cache cargo build")["with"]
        self.assertIn("'cmux-tui-linux'", cache["shared-key"])
        self.assertEqual(cache["cache-all-crates"], "true")
        self.assertIn("cmux_next_", step(daemon, "cargo test cmux_next_")["run"])
        self.assertNotIn("continue-on-error", daemon)

    def test_a_linux_pass_writes_the_marker_and_names_its_os(self) -> None:
        tested = jobs()["publish-tree-tested"]
        condition = flat(tested["if"])
        self.assertNotIn("runner_os", condition)
        self.assertIn("needs.cmux-next-daemon-tests.result == 'success'", condition)
        self.assertIn("needs.cmux-next-daemon-tests.outputs.key == needs.tree-preflight.outputs.key", condition)
        self.assertNotIn(SHADOW, tested["needs"])
        env = step(tested, "Write the daemon-tests marker")["env"]
        self.assertEqual(env["TESTED_OS"].replace(" ", ""), "${{needs.cmux-next-daemon-tests.outputs.runner_os}}")
        script = (ROOT / "scripts/ci/cmux-tui-mark-daemon-tested.sh").read_text(encoding="utf-8")
        self.assertIn('marker["os"] = os.environ["TESTED_OS"]', script)

    def test_the_macos_shadow_gates_nothing(self) -> None:
        all_jobs = jobs()
        shadow = all_jobs[SHADOW]
        self.assertEqual(shadow["continue-on-error"], "true")
        self.assertEqual(shadow["concurrency"]["cancel-in-progress"], "false")
        self.assertFalse(shadow["name"].startswith("cmux_next_ daemon tests"))
        for name, job in all_jobs.items():
            needs = job.get("needs", [])
            needs = [needs] if isinstance(needs, str) else needs
            self.assertNotIn(SHADOW, needs, name)
        run = flat(step(shadow, "cargo test the macOS-only daemon tests")["run"])
        for test in MAC_ONLY_TESTS:
            self.assertIn(f"--test {test}", run)
        self.assertIn("feat-cmux-next", shadow["if"])

    def test_the_shadow_stays_off_the_promote_pool_and_the_pin_pushes_shared_pools(self) -> None:
        runs_on = jobs()[SHADOW]["runs-on"]
        for daemon in ("", DAEMON_LABEL, PROMOTE_LABEL, LIGHT_LABEL, SIDE_LABEL):
            for context in contexts(CI_NEXT_DAEMON_POOL=daemon):
                label = route(runs_on, context)
                if context["github.repository_owner"] != "manaflow-ai":
                    self.assertEqual(label, "macos-26")
                    continue
                self.assertNotEqual(label, PROMOTE_LABEL, (daemon, context))
                if context["github.ref"].startswith("refs/heads/cmux-tui-pin-"):
                    self.assertEqual(label, "blacksmith-6vcpu-macos-15")
                elif daemon and daemon != PROMOTE_LABEL:
                    self.assertEqual(label, daemon)
                else:
                    self.assertEqual(label, "blacksmith-6vcpu-macos-15")


if __name__ == "__main__":
    unittest.main()
