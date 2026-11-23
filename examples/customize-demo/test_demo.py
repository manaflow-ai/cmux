#!/usr/bin/env python3
"""Regression checks for preview ownership, reset ordering, and capture limits.

Run through cmux-ci test -- python3 examples/customize-demo/test_demo.py.
The fake CLI verifies orchestration only; it is not evidence of live UI behavior.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
FAKE = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["DEMO_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:2] == ["customize", "status"]:
    print(json.dumps({"draft": {} if os.environ.get("DEMO_DRAFT") else None, "try_on": None,
                      "changes": [{"path": "cmux-next.json"}] if os.environ.get("DEMO_HAND_EDIT") else []}))
if args[:2] == ["customize", "use"] and os.environ.get("DEMO_FAIL_USE"):
    sys.exit(7)
if args[:2] == ["customize", "discard"] and os.environ.get("DEMO_FAIL_RESET"):
    sys.exit(9)
'''


class DemoTests(unittest.TestCase):
    def run_demo(self, *args, **env):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            cli = root / "cmux"
            cli.write_text(FAKE)
            cli.chmod(0o755)
            log = root / "calls"
            result = subprocess.run(
                [str(HERE / "demo.sh"), *args], text=True, capture_output=True,
                env={**os.environ, "CMUX": str(cli), "DEMO_LOG": str(log), **env},
            )
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_every_look_has_its_own_reset(self):
        result, calls = self.run_demo("--auto", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        mutations = [call[1] for call in calls if call[0] == "customize" and call[1] in ("use", "discard")]
        self.assertEqual(mutations, ["use", "discard"] * 13)

    def test_existing_draft_is_not_discarded(self):
        result, calls = self.run_demo("--auto", "0", DEMO_DRAFT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [["customize", "status", "--json"]])

    def test_failed_apply_restores_and_keeps_error(self):
        result, calls = self.run_demo("--auto", "0", DEMO_FAIL_USE="1")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(calls[-3:], [["customize", "discard"], ["action", "run", "newTab.page"],
                                     ["customize", "library", "status"]])

    def test_hand_edits_survive_a_failed_first_import(self):
        result, calls = self.run_demo("--auto", "0", DEMO_HAND_EDIT="1", DEMO_FAIL_USE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [["customize", "status", "--json"]])

    def test_failed_reset_does_not_claim_success(self):
        result, _ = self.run_demo("--only", "looks/claude.json", "--auto", "0", DEMO_FAIL_RESET="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Your setup is back", result.stdout)

    def test_bad_arguments_do_not_mutate(self):
        for args in [("--only", "../bad.json"), ("--auto", "bad")]:
            result, calls = self.run_demo(*args)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(calls, [])

    def test_per_look_video_states(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "states"
            subprocess.run(["python3", str(HERE / "record-steps.py"), "--ref", "a" * 40,
                            "--video", "--output-dir", str(output)], check=True, capture_output=True)
            states = list(output.glob("*.json"))
            self.assertEqual(len(states), 13)
            for state in states:
                steps = json.loads(state.read_text())["steps"]
                self.assertLessEqual(len(steps), 60)
                starts = [step for step in steps if step.get("recording") == "start"]
                self.assertEqual(starts, [{"recording": "start", "clip": state.stem}])
                self.assertEqual(sum(step.get("recording") == "stop" for step in steps), 1)
                self.assertIn({"cmux": ["customize", "discard"], "record": True}, steps)
                for step in steps:
                    self.assertTrue(all(len(arg) <= 2000 for arg in step.get("cmux", [])))

    def test_frame_states_fit_the_runner(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "states"
            subprocess.run(["python3", str(HERE / "record-steps.py"), "--ref", "a" * 40, "--frames", "12",
                            "--output-dir", str(output)], check=True, capture_output=True)
            for state in output.glob("*.json"):
                steps = json.loads(state.read_text())["steps"]
                self.assertLessEqual(len(steps), 60)
                shots = [step["shot"] for step in steps if "shot" in step]
                self.assertEqual(len(shots), len(set(shots)))
                self.assertEqual(len(shots), 14)  # before, 12 frames, after reset
                self.assertFalse(any("recording" in step for step in steps))

    def test_each_look_opens_the_new_tab_page(self):
        # A capture's action.run and the CLI are scripts: newTab.default gives them a tab of the selected
        # tab's kind (a terminal, or the Chief home's chat), never the page a look's tabs.newTabApp draws.
        result, calls = self.run_demo("--auto", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        uses = [i for i, call in enumerate(calls) if call[:2] == ["customize", "use"]]
        self.assertEqual(len(uses), 13)
        for i in uses:
            self.assertEqual(calls[i + 1], ["action", "run", "newTab.page"])
        self.assertNotIn(["action", "run", "newTab.default"], calls)
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "states"
            subprocess.run(["python3", str(HERE / "record-steps.py"), "--ref", "a" * 40, "--frames", "3",
                            "--output-dir", str(output)], check=True, capture_output=True)
            for state in output.glob("*.json"):
                steps = json.loads(state.read_text())["steps"]
                actions = [step["action"] for step in steps if "action" in step]
                self.assertEqual(actions, ["newTab.page", "newTab.page"], state.name)
                use = next(i for i, step in enumerate(steps) if step.get("cmux", [])[:2] == ["customize", "use"])
                self.assertEqual(steps[use + 1].get("action"), "newTab.page", state.name)


if __name__ == "__main__":
    unittest.main()
