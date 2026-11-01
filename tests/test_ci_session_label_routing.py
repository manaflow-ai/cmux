#!/usr/bin/env python3
"""Session jobs outside cmux-next.yml take the session label only once runners carry it.

glaeda#1530 adds `glaeda-session-<class>-xcode-<version>`: a mini's console gui
runner carries it beside the gui label, and with `guiRunners` 2 each mini gets a
session runner carrying only it. The pr-media tour and both autofix workflows'
action-exports job need a logged-in session but not the console gui token, so
they take it. A job asking for a label no online runner carries queues forever,
so until the fleet carries it each job must evaluate to the label it takes today.

The tour's picker (cmux_next_media_runner.py) reads CI_OWNED_POOL_SLOTS, so the
session label wins only with a count there. The autofix jobs have no picker, so
they never take it: on 2026-10-29 cmux#24295's daemon tests waited 90 minutes,
twice, on a session label whose online runners were all busy while the gui label
moved, and only a placement's role_room() can see that (side_lane_placement.py).
They keep the gui label whatever vars.CI_SESSION_LABEL says.
"""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
sys.path.insert(0, str(ROOT / "tests"))
from test_seed_derived_data import evaluate, github_context  # noqa: E402

PR_XCODE = "/Applications/Xcode_26.6.app"
GUI = "glaeda-gui-std-xcode-26.6"
SESSION = "glaeda-session-std-xcode-26.6"
FALLBACK = "blacksmith-6vcpu-macos-26"


def load_media_runner():
    path = ROOT / "scripts" / "ci" / "cmux_next_media_runner.py"
    spec = importlib.util.spec_from_file_location("cmux_next_media_runner", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


media = load_media_runner()


def pick(slots: str, **overrides):
    args = {"same_repo": True, "owned": "1", "owned_slots": slots, "pr_xcode_app": PR_XCODE, **overrides}
    return media.pick(**args)[0]


class MediaTourRunner(unittest.TestCase):
    def test_the_gui_label_until_a_session_count_exists(self):
        # Today's CI_OWNED_POOL_SLOTS has no session count: the tour keeps the gui label.
        self.assertEqual(pick('{"std": 42, "root-std": 19, "gui-std": 10}'), GUI)
        self.assertEqual(pick('{"std": 42, "root-std": 19, "gui-std": 10, "session-std": 20}'), SESSION)
        self.assertEqual(pick(f'{{"std": 42, "gui-std": 10, "{SESSION}": 20}}'), SESSION)
        # Session runners alone can run the tour.
        self.assertEqual(pick('{"std": 42, "session-std": 10}'), SESSION)
        self.assertEqual(pick('{"std": 42}'), "")

    def test_untrusted_or_off_never_takes_an_owned_label(self):
        slots = '{"std": 42, "gui-std": 10, "session-std": 20}'
        self.assertEqual(pick(slots, same_repo=False), "")
        self.assertEqual(pick(slots, owned="0"), "")
        self.assertEqual(pick(slots, pr_xcode_app=""), "")


class AutofixActionExports(unittest.TestCase):
    WORKFLOWS = ("cmux-next-pr-autofix.yml", "cmux-next-base-autofix.yml")

    def runs_on(self, name: str) -> str:
        workflow = yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))
        return workflow["jobs"]["action-exports"]["runs-on"]

    def context(self, **variables) -> dict:
        context = github_context("pull_request", ref="refs/pull/1/merge", **{"CI_PR_POOL_OWNED": "1", **variables})
        context["vars"].pop("MACOS_RUNNER_PR")
        context["github"].update(repository="manaflow-ai/cmux",
                                 event={"pull_request": {"head": {"repo": {"full_name": "manaflow-ai/cmux"}}}})
        return context

    def test_the_gui_label_whatever_ci_session_label_says(self):
        for name in self.WORKFLOWS:
            runs_on = self.runs_on(name)
            with self.subTest(workflow=name):
                self.assertEqual(evaluate(runs_on, self.context()), GUI)
                self.assertEqual(evaluate(runs_on, self.context(CI_SESSION_LABEL="0")), GUI)
                self.assertEqual(evaluate(runs_on, self.context(CI_SESSION_LABEL="1")), GUI)
                self.assertNotIn(SESSION, runs_on)
                # Owned pools off keeps the hosted fallback whatever the session switch says.
                self.assertEqual(evaluate(runs_on, self.context(CI_PR_POOL_OWNED="0", CI_SESSION_LABEL="1")),
                                 FALLBACK)
                other = self.context(CI_SESSION_LABEL="1")
                other["github"]["repository_owner"] = "someone"
                self.assertEqual(evaluate(runs_on, other), "macos-26")


if __name__ == "__main__":
    unittest.main()
