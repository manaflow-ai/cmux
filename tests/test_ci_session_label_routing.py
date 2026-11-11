#!/usr/bin/env python3
"""Session jobs outside cmux-next.yml take the session label only once runners carry it.

glaeda#1530 adds `glaeda-session-<class>-xcode-<version>`: a mini's console gui
runner carries it beside the gui label, and with `guiRunners` 2 each mini gets a
session runner carrying only it. The pr-media tour and both autofix workflows'
action-exports job need a logged-in session but not the console gui token, so
they take it. A job asking for a label no online runner carries queues forever,
so until the fleet carries it each job must evaluate to the label it takes today.

The tour's picker (cmux_next_media_runner.py) reads CI_OWNED_POOL_SLOTS, so the
session label wins only with a count there. The autofix jobs never take it: on
2026-10-29 cmux#24295's daemon tests waited 90 minutes, twice, on a session label
whose online runners were all busy while the gui label moved. They take the gui
label only from their own idle read (mac_runner: cmux_next_media_runner.py
--idle-now --gui-only), else Blacksmith macOS, whatever vars.CI_SESSION_LABEL says:
with the office minis dark on 2026-11-10 every base autofix export queued on the
gui label until the rescue cancelled it, and the settings export stayed stale.
"""
from __future__ import annotations

import importlib.util
import json
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
RUNNER_POOLS = json.loads((ROOT / ".github" / "runners.json").read_text(encoding="utf-8"))["pools"]
FALLBACK = RUNNER_POOLS["macos_26"]["members"][0]


def evaluate_runs_on(expression: str, context: dict):
    """Evaluate a route after resolving its declared pool member.

    The shared expression evaluator handles the Actions subset used by the
    older routes, but not property access after ``fromJSON``. Resolve this
    declared pool before evaluating so branch ordering remains under test.
    """
    label = RUNNER_POOLS["macos_26"]["members"][0]
    return evaluate(expression.replace("fromJSON(vars.RUNNER_POOLS).macos_26", f"'{label}'"), context)


def load_media_runner():
    # Imported by name, never loaded by path: one module object per file, so a test that patches it
    # patches what every other test reads (tests/test_script_module_loads.py).
    if str(ROOT / "scripts/ci") not in sys.path:
        sys.path.insert(0, str(ROOT / "scripts/ci"))
    import cmux_next_media_runner
    return cmux_next_media_runner


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
    # Each workflow's job that reads the idle gui runner for its Mac exports.
    WORKFLOWS = {"cmux-next-pr-autofix.yml": "action-areas", "cmux-next-base-autofix.yml": "pushed-exports"}

    def runs_on(self, name: str) -> str:
        workflow = yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))
        return workflow["jobs"]["action-exports"]["runs-on"]

    def context(self, name: str, mac_runner: str = GUI, **variables) -> dict:
        context = github_context("pull_request", ref="refs/pull/1/merge", **{"CI_PR_POOL_OWNED": "1", **variables})
        context["vars"].pop("MACOS_RUNNER_PR")
        context["github"].update(repository="manaflow-ai/cmux",
                                 event={"pull_request": {"head": {"repo": {"full_name": "manaflow-ai/cmux"}}}})
        context["needs"] = {self.WORKFLOWS[name]: {"outputs": {"mac_runner": mac_runner}}}
        return context

    def test_the_gui_label_whatever_ci_session_label_says(self):
        for name in self.WORKFLOWS:
            runs_on = self.runs_on(name)
            with self.subTest(workflow=name):
                self.assertEqual(evaluate_runs_on(runs_on, self.context(name)), GUI)
                self.assertEqual(evaluate_runs_on(runs_on, self.context(name, CI_SESSION_LABEL="0")), GUI)
                self.assertEqual(evaluate_runs_on(runs_on, self.context(name, CI_SESSION_LABEL="1")), GUI)
                self.assertNotIn(SESSION, runs_on)
                # Owned pools off keeps the hosted fallback whatever the session switch says.
                self.assertEqual(evaluate_runs_on(runs_on, self.context(name, CI_PR_POOL_OWNED="0", CI_SESSION_LABEL="1")),
                                 FALLBACK)
                other = self.context(name, CI_SESSION_LABEL="1")
                other["github"]["repository_owner"] = "someone"
                self.assertEqual(evaluate_runs_on(runs_on, other), "macos-26")

    def test_no_idle_gui_runner_takes_blacksmith_at_once(self):
        # 2026-11-10: the office minis were dark; a job queued on the gui label never ran.
        for name in self.WORKFLOWS:
            runs_on = self.runs_on(name)
            with self.subTest(workflow=name):
                self.assertNotIn("glaeda-", runs_on)
                self.assertEqual(evaluate_runs_on(runs_on, self.context(name, mac_runner="")), FALLBACK)
                missing = self.context(name)
                missing["needs"] = {}
                self.assertEqual(evaluate_runs_on(runs_on, missing), FALLBACK)

    def test_each_workflow_reads_the_idle_gui_runner(self):
        for name, job in self.WORKFLOWS.items():
            workflow = yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))
            steps = workflow["jobs"][job]["steps"]
            pick = next(step for step in steps if step.get("id") == "mac-runner")
            with self.subTest(workflow=name):
                self.assertIn("cmux_next_media_runner.py\" --same-repo true --idle-now --gui-only"
                              if name == "cmux-next-pr-autofix.yml" else
                              "cmux_next_media_runner.py --same-repo true --idle-now --gui-only", pick["run"])
                self.assertTrue(pick.get("continue-on-error"))
                if name == "cmux-next-pr-autofix.yml":
                    # The job's sparse checkout leaves scripts/ci out; restore needs the flag to find it
                    # (review of #40722 at 449788fc, F1).
                    placement = next(step for step in steps if step.get("id") == "placement")
                    self.assertIn("restore --ignore-skip-worktree-bits", placement["run"])
                    self.assertNotIn("scripts/ci", workflow["jobs"][job]["steps"][0]["with"]["sparse-checkout"])
                self.assertEqual(workflow["jobs"][job]["outputs"]["mac_runner"],
                                 "${{ steps.mac-runner.outputs.runs_on }}")


def runner(name: str, *labels: str, busy: bool = False, status: str = "online") -> dict:
    return {"name": name, "status": status, "busy": busy, "labels": [{"name": label} for label in labels]}


class IdleGuiOnly(unittest.TestCase):
    """--gui-only (the autofix Mac exports): an idle gui runner, never the session label."""

    def pick(self, runners, **overrides):
        options = dict(same_repo=True, owned="1", pr_xcode_app=PR_XCODE, runners=runners, gui_only=True)
        options.update(overrides)
        return media.pick_idle(**options)

    def test_an_idle_gui_runner_never_the_session_label(self):
        both = [runner("a", "glaeda-std-xcode-26.6", SESSION), runner("b", "glaeda-std-xcode-26.6", GUI, SESSION)]
        self.assertEqual(self.pick(both)[0], GUI)
        # Without --gui-only the same runners give the session label (the visual gate's rule).
        self.assertEqual(self.pick(both, gui_only=False)[0], SESSION)
        self.assertEqual(self.pick([runner("a", SESSION)])[0], "")

    def test_dark_busy_or_unread_runners_place_nothing(self):
        dark = [runner("a", GUI, status="offline"), runner("b", GUI, busy=True)]
        label, reason = self.pick(dark)
        self.assertEqual(label, "")
        self.assertIn("gui", reason)
        self.assertEqual(self.pick(None)[0], "")
        self.assertEqual(self.pick([runner("a", GUI)], owned="0")[0], "")
        self.assertEqual(self.pick([runner("a", GUI)], same_repo=False)[0], "")

    def test_the_cli_needs_idle_now(self):
        import subprocess
        script = ROOT / "scripts" / "ci" / "cmux_next_media_runner.py"
        done = subprocess.run([sys.executable, str(script), "--same-repo", "true", "--gui-only"],
                              capture_output=True, text=True, timeout=60)
        self.assertNotEqual(done.returncode, 0)
        done = subprocess.run([sys.executable, str(script), "--same-repo", "true", "--idle-now", "--gui-only"],
                              capture_output=True, text=True, timeout=60,
                              env={"PATH": "/usr/bin:/bin", "POOL_OWNED": "1", "PR_XCODE_APP": PR_XCODE})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("runs_on=\n", done.stdout)


if __name__ == "__main__":
    unittest.main()
