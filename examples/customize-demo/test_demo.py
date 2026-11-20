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
        self.assertEqual(calls[-3:], [["customize", "discard"], ["action", "run", "newTab.page", "--focus"],
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

    def test_demo_opens_and_focuses_pages_regardless_of_default_tab(self):
        result, calls = self.run_demo("--auto", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        actions = [call for call in calls if call[:2] == ["action", "run"]]
        self.assertEqual(actions, [["action", "run", "newTab.page", "--focus"]] * 14)

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
                # Capture's action runner supplies focus: true; do not inherit tabs.newTabKind.
                self.assertEqual([step["action"] for step in steps if "action" in step],
                                 ["newTab.page", "newTab.page"])
                for step in steps:
                    self.assertTrue(all(len(arg) <= 2000 for arg in step.get("cmux", [])))


LOOKS = HERE / "looks"
# Measured from manaflow-ai/cmux-design-references live captures, in points (pixels / capture scale).
# The PR that set them carries the table: the source file, its scale and the pixel edges of each.
MEASURED = {
    "claude": {"appearance.metrics.sidebarWidth": 288, "appearance.metrics.sidebarRowHeight": 26,
               "appearance.metrics.titlebarHeight": 48, "appearance.metrics.chromeFontSize": 13,
               "agentPane.display.width": 768, "layout.paneCornerRadius": 12},
    "codex": {"appearance.metrics.sidebarWidth": 291, "appearance.metrics.sidebarRowHeight": 31,
              "appearance.metrics.titlebarHeight": 44, "appearance.metrics.chromeFontSize": 14,
              "agentPane.display.width": 736, "agentPane.display.font.size": 14, "layout.paneCornerRadius": 20},
    "studio": {"appearance.metrics.sidebarWidth": 256, "appearance.metrics.titlebarHeight": 52,
               "appearance.metrics.chromeFontSize": 14, "agentPane.display.width": 736,
               "layout.paneCornerRadius": 8},
    "hosts": {"appearance.metrics.chromeFontSize": 13, "layout.paneCornerRadius": 12},
}
FUNCTIONS = ["palette.newAgentChat", "server.addServer", "customize.open",
             "agentPane.toggleSessionInfo", "toggleSidebar"]


def schema_ranges():
    """Every settings key's numeric range, from the schema sources."""
    ranges = {}

    def walk(node):
        if isinstance(node, dict):
            if isinstance(node.get("key"), str) and isinstance(node.get("range"), dict):
                ranges[node["key"]] = node["range"]
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    for source in (HERE.parent.parent / "schemas" / "settings" / "source").glob("*.json"):
        walk(json.loads(source.read_text()))
    return ranges


class MeasuredLookTests(unittest.TestCase):
    def test_looks_carry_measured_proportions(self):
        ranges = schema_ranges()
        for look, values in MEASURED.items():
            profile = json.loads((LOOKS / look / "profile.json").read_text())["settings"]
            bundle = json.loads((LOOKS / f"{look}.json").read_text())["settings"]
            for key, value in values.items():
                self.assertEqual(profile.get(key), value, f"{look} {key}")
                self.assertEqual(bundle.get(key), value, f"{look}.json {key} (run looks/bundle.py)")
                self.assertIn(key, ranges, f"{key} is not a settings key")
                self.assertGreaterEqual(value, ranges[key]["min"], key)
                self.assertLessEqual(value, ranges[key]["max"], key)

    def test_side_panels_open_beside_the_chat(self):
        for look in MEASURED:
            settings = json.loads((LOOKS / f"{look}.json").read_text())["settings"]
            self.assertEqual(settings.get("agentPane.display.sessionInfo.placement"), "push", look)
            self.assertIs(settings.get("sidebar.floatOnHover"), True, look)

    def test_every_look_wires_its_functions(self):
        for look in MEASURED:
            source = (LOOKS / look / "customize" / "main.js").read_text()
            for action in FUNCTIONS:
                self.assertIn(f'run("{action}"', source, f"{look} {action}")

    def test_gallery_codex_column_matches_the_look(self):
        gallery = json.loads((HERE.parent.parent / "webviews/src/gallery/golden/looks.json").read_text())
        by_id = {look["id"]: look for look in gallery["looks"]}
        self.assertEqual(by_id["codex"]["settings"]["agentPane.display.width"], MEASURED["codex"]["agentPane.display.width"])
        self.assertEqual(by_id["claude"]["settings"]["agentPane.display.width"], MEASURED["claude"]["agentPane.display.width"])
        self.assertEqual(by_id["studio"]["settings"]["agentPane.display.width"], MEASURED["studio"]["agentPane.display.width"])


if __name__ == "__main__":
    unittest.main()
