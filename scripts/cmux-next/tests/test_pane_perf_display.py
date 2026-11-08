#!/usr/bin/env python3
"""pane-perf-terminal.py refuses a display too small for the STRESS window instead of measuring a clamped one.

Run: python3 -I scripts/cmux-next/tests/test_pane_perf_display.py
No app, display or fleet host is needed: the bench's own `display_refusal` runs on recorded
`debug.window_frame` replies (the AWS Nitro one is from aws-m4pro-8, step 193976b0, 2026-11-08).
"""
import ast
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def stress_module():
    spec = importlib.util.spec_from_file_location("perf_stress_session", ROOT / "perf-stress-session.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def definitions(path, names):
    """Load selected definitions without executing the bench's app launch."""
    tree = ast.parse(path.read_text(), filename=str(path))
    nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
    return compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec")


STRESS = stress_module()
SCOPE = {"STRESS_MODULE": STRESS, "WINDOW": STRESS.WINDOW_SIZE}
exec(definitions(ROOT / "pane-perf-terminal.py", {"display_refusal"}), SCOPE)

# aws-m4pro-8: the 1600 x 1000 window came back clamped to the 1024 x 768 display's visible frame.
AWS_NITRO = {"frame": [-288, 58, 1600, 680], "visible_frame": [0, 58, 1024, 680],
             "screen_frame": [0, 0, 1024, 768], "screen": "AWS Nitro D-1"}
# A 1920x1200 display (a Mac mini's, or split-spring.sh --vdisplay): the window is the STRESS size.
ROOMY = {"frame": [160, 100, 1600, 1000], "visible_frame": [0, 0, 1920, 1175],
         "screen_frame": [0, 0, 1920, 1200], "screen": "Virtual 1920x1200"}


class DisplayRefusal(unittest.TestCase):
    def test_a_clamped_window_refuses_the_run_as_display_too_small(self):
        refusal = SCOPE["display_refusal"](AWS_NITRO)
        self.assertIsNotNone(refusal)
        self.assertTrue(refusal.startswith("display too small"), refusal)
        self.assertIn("AWS Nitro D-1", refusal)
        self.assertIn("1024 x 768", refusal)  # the display it saw, from display_advice

    def test_a_window_of_the_stress_size_runs(self):
        self.assertIsNone(SCOPE["display_refusal"](ROOMY))

    def test_one_point_of_rounding_still_runs(self):
        self.assertIsNone(SCOPE["display_refusal"]({**ROOMY, "frame": [160, 100, 1599.5, 1000.5]}))

    def test_no_reply_is_not_a_display_refusal(self):
        # A failed debug.window_frame is the placement row's failure, not a display size.
        self.assertIsNone(SCOPE["display_refusal"]({"error": "unavailable"}))
        self.assertIsNone(SCOPE["display_refusal"](None))


if __name__ == "__main__":
    unittest.main()
