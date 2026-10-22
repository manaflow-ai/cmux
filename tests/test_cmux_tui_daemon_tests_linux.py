#!/usr/bin/env python3
"""cmux-tui-pin-* pushes run the cmux_next_ daemon tests on Linux; promotion stays on macOS.

cmux-tui-artifacts.yml's cmux-next-daemon-tests job ran on a Mac for every
push that tests: one cmux-tui-pin-* push per merged pull request, and every
feat-cmux-next push. The tests are Rust and pass on Linux (cmux-tui.yml's
Linux test job runs the whole workspace), so a pin push takes Blacksmith Linux
and only the feat-cmux-next promotion gate keeps a Mac.

The promotion gate is the tree's daemon-tests marker
(tree/<key>/daemon-tests.json), which request-nightly-next.sh requires. A pin
usually publishes the same tree key its feat-cmux-next merge pushes next, and
a marker written there would let that push skip its macOS tests. So only a
macOS run of the job writes the marker; an unmarked tree is then tested by the
feat-cmux-next push on its Mac pool.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from test_ci_tui_routes_avoid_nightly_label import (  # noqa: E402
    LIGHT_LABEL,
    PIN_LABEL,
    PIN_REF,
    PROMOTE_LABEL,
    contexts,
    route,
)

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
LINUX_LABEL = "blacksmith-16vcpu-ubuntu-2404"
JOB_NAME = "cmux_next_ daemon tests (macOS)"


def jobs() -> dict:
    return yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]


def step(job: dict, name: str) -> dict:
    return next(s for s in job["steps"] if s.get("name") == name)


class DaemonTestsLinuxTests(unittest.TestCase):
    def test_pin_pushes_run_on_linux_and_promotion_keeps_its_mac(self) -> None:
        runs_on = jobs()["cmux-next-daemon-tests"]["runs-on"]
        for owned in ("1", ""):
            for context in contexts(CI_PR_POOL_OWNED=owned):
                label = route(runs_on, context)
                if context["github.repository_owner"] != "manaflow-ai":
                    self.assertEqual(label, "macos-26")
                    continue
                if context["github.event_name"] == "push" and context["github.ref"] == PIN_REF:
                    self.assertEqual(label, LINUX_LABEL, (owned, context["github.run_attempt"]))
                    continue
                self.assertNotIn("ubuntu", label, context)
                if (context["github.event_name"], context["github.ref"], context["github.run_attempt"]) == (
                        "push", "refs/heads/feat-cmux-next", 1):
                    self.assertEqual(label, PROMOTE_LABEL)

    def test_a_pin_pool_variable_still_wins_and_the_light_minis_do_not(self) -> None:
        runs_on = jobs()["cmux-next-daemon-tests"]["runs-on"]
        for context in contexts(CI_PIN_DAEMON_POOL=PIN_LABEL):
            if (context["github.repository_owner"], context["github.event_name"], context["github.ref"]) == (
                    "manaflow-ai", "push", PIN_REF):
                self.assertEqual(route(runs_on, context), PIN_LABEL)
        for context in contexts(CI_NEXT_DAEMON_POOL=LIGHT_LABEL, CI_PIN_DAEMON_POOL=LIGHT_LABEL):
            if (context["github.repository_owner"], context["github.event_name"], context["github.ref"]) == (
                    "manaflow-ai", "push", PIN_REF):
                self.assertEqual(route(runs_on, context), LINUX_LABEL)

    def test_the_job_keeps_its_name_and_runs_on_either_os(self) -> None:
        daemon = jobs()["cmux-next-daemon-tests"]
        # cmux_tui_publisher_testing.py and tree-owner-wait find the job by name.
        self.assertEqual(daemon["name"], JOB_NAME)
        self.assertEqual(daemon["outputs"]["runner_os"].replace(" ", ""), "${{runner.os}}")
        deps = step(daemon, "Install Linux build dependencies")
        self.assertIn("runner.os == 'Linux'", deps["if"])
        self.assertIn("libclang-dev", deps["run"])
        cache = step(daemon, "Cache cargo build")["with"]["shared-key"]
        self.assertIn("runner.os", cache)
        # The macOS key stays as it was, so the Mac runs keep their warm cache.
        self.assertIn("'cmux-tui-macos'", cache)

    def test_only_a_macos_run_writes_the_daemon_tests_marker(self) -> None:
        condition = " ".join(jobs()["publish-tree-tested"]["if"].split())
        self.assertIn("needs.cmux-next-daemon-tests.outputs.runner_os == 'macOS'", condition)


if __name__ == "__main__":
    unittest.main()
