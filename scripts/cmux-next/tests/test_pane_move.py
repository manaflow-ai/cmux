#!/usr/bin/env python3
"""pane_move.py holds the one rule for `did a pane move in this act`, and the measure scripts call it.

The pane suite (pane-perf-terminal.py) and the zoom script (pane-zoom-terminal.py) both said if an act was
animated. The suite read the pane trace; the zoom script counted the app's `layout.travel` and `layout.commit`
samples only, so at a build with no `layout.commit` sample each zoom by a commit motion failed its row with
`0 spring frames, 0 commit frames`, with a pane that moved on the screen. The rule is now in one module:

- neither script has a copy of the rule's 3 functions, and both import them from pane_move;
- the zoom script's row is the rule's: a pane in a move in 2 samples of the pane trace or more is animated with
  no frame of the app's samples, and a build with no source says NO SOURCE and fails;
- the zoom script proves the move in a round of its own, with the pane trace: a timed zoom runs with no trace.

Run: python3 scripts/cmux-next/tests/test_pane_move.py
"""
import ast
import sys
from pathlib import Path
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[1]
RULE = ("pane_in_a_move", "move_facts", "animated_row")
SCRIPTS = ("pane-perf-terminal.py", "pane-zoom-terminal.py")


def definitions(path, names):
    """Selected functions of a script, with no run of its launch block. A name that the script lacks fails."""
    tree = ast.parse(path.read_text(), filename=str(path))
    nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
    missing = set(names) - {node.name for node in nodes}
    assert not missing, f"{path.name} lacks {sorted(missing)}"
    return compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec")


def rule():
    """The module's 3 functions by name. A tree with no such module fails."""
    sys.path.insert(0, str(ROOT))
    try:
        import pane_move
    except ImportError as error:
        raise AssertionError(f"no module pane_move: {error}") from None
    finally:
        sys.path.remove(str(ROOT))
    return {name: getattr(pane_move, name) for name in RULE}


def pane(name, end, now=None):
    """One pane row of the pane trace as the app's sampler gives it: the id and 21 numbers; the first rect is where
    the pane ends, the last 4 numbers where it IS in the sample."""
    return [name, *end, 1, 1, *end, end[2], end[3], 1, *end, *(now or end)]


END = [100, 6, 200, 190]
MOVE = {"samples": [{"t": 8.3 * at, "panes": [pane("a", END, [100, 6, width, 190])]} for at, width in enumerate((100, 130, 160, 190))]
        + [{"t": 50, "panes": [pane("a", END)]}]}
ONE_FRAME = {"samples": [{"t": 0, "panes": [pane("a", END)]}, {"t": 8.3, "panes": [pane("a", END, [100, 6, 0, 0])]}]}


class TheRuleIsInOnePlace(unittest.TestCase):
    def test_neither_script_has_a_copy_of_the_rule(self):
        for script in SCRIPTS:
            tree = ast.parse((ROOT / script).read_text())
            own = {node.name for node in tree.body if isinstance(node, ast.FunctionDef)}
            self.assertEqual(own & set(RULE), set(), script)

    def test_each_script_takes_the_rule_from_the_module(self):
        for script in SCRIPTS:
            tree = ast.parse((ROOT / script).read_text())
            taken = {name.name for node in tree.body if isinstance(node, ast.ImportFrom) and node.module == "pane_move"
                     for name in node.names}
            self.assertLessEqual({"move_facts", "animated_row"}, taken, script)

    def test_the_module_has_the_rule(self):
        self.assertEqual(sorted(rule()), sorted(RULE))


class TheZoomScriptsRow(unittest.TestCase):
    """`moved_row` of the zoom script: the row of a proof round's zoom or unzoom."""

    def setUp(self):
        self.made = dict(rule())
        exec(definitions(ROOT / "pane-zoom-terminal.py", {"moved_row"}), self.made)
        self.facts = self.made["move_facts"]

    def row(self, trace, moving=0, committed=0):
        return self.made["moved_row"]({"moving_frames": moving, "commit_frames": committed, "move": self.facts(trace)})

    def test_a_zoom_that_moves_in_the_pane_trace_is_animated_with_no_frame_of_the_apps_samples(self):
        said, _, seen, passed = self.row(MOVE)
        self.assertTrue(passed, seen)
        self.assertTrue(said.startswith("animated"), said)
        self.assertEqual(seen, "4 of 5 samples of the pane trace in a move; 0 spring frames, 0 commit frames")

    def test_a_build_with_no_source_says_so_and_fails(self):
        for trace in (None, {}, {"samples": []}, {"samples": [{"t": 0, "panes": [["a", 100, 6, 200, 190]]}]}):
            _, _, seen, passed = self.row(trace)
            self.assertFalse(passed, seen)
            self.assertTrue(seen.startswith("NO SOURCE: "), seen)

    def test_a_change_in_one_frame_is_not_a_move(self):
        _, _, seen, passed = self.row(ONE_FRAME)
        self.assertFalse(passed, seen)
        self.assertTrue(seen.startswith("1 of 2 samples of the pane trace in a move"), seen)

    def test_a_frame_of_the_apps_samples_is_a_move_with_no_trace(self):
        self.assertTrue(self.row(None, committed=5)[3])
        self.assertTrue(self.row(None, moving=3)[3])


class Calls:
    """The app's debug socket as a list of the calls that the script made."""

    def __init__(self, trace):
        self.made, self.trace = [], trace

    def __call__(self, method, params=None, timeout=30):
        self.made.append((method, (params or {}).get("action"), tuple((params or {}).get("targets") or ())))
        return self.trace if (params or {}).get("action") == "trace_stop" else {}


class TheZoomScriptsProofRound(unittest.TestCase):
    """A timed zoom runs with no pane trace: the trace's sampler costs main-thread time at each display tick. Each
    layout has one zoom and one unzoom more, first, with the trace: the proof round, not timed, not in the numbers."""

    def setUp(self):
        self.printed, self.calls = [], Calls(MOVE)
        self.made = dict(rule())
        self.made.update(rpc=self.calls, time=SimpleNamespace(sleep=lambda seconds: None),
                         action=lambda name: self.calls("action.run", {"action": name}),
                         print=lambda *said, **more: self.printed.append(" ".join(str(part) for part in said)))
        exec(definitions(ROOT / "pane-zoom-terminal.py", {"sample_frames", "measure"}), self.made)

    def traced(self):
        return [call for call in self.calls.made if call[1] in ("trace_start", "trace_stop", "toggleSplitZoom")]

    def test_a_timed_zoom_runs_with_no_pane_trace(self):
        run = self.made["measure"]("2x2 zoom #0")
        self.assertEqual(self.traced(), [("action.run", "toggleSplitZoom", ())])
        self.assertIsNone(run["move"])
        self.assertNotIn("proof round", " ".join(self.printed))

    def test_a_proof_round_runs_with_the_pane_trace_around_the_act(self):
        run = self.made["measure"]("2x2 zoom proof", proof=True)
        self.assertEqual(self.traced(), [("debug.motion", "trace_start", ("panes",)), ("action.run", "toggleSplitZoom", ()),
                                         ("debug.motion", "trace_stop", ())])
        self.assertEqual((run["move"]["samples_in_a_move"], run["move"]["samples"], run["move"]["no_source"]), (4, 5, None))

    def test_a_proof_round_says_that_it_is_not_timed(self):
        self.made["measure"]("2x2 zoom proof", proof=True)
        self.assertEqual(len(self.printed), 1)
        self.assertIn("2x2 zoom proof", self.printed[0])
        self.assertIn("proof round (not timed, not in the numbers): 4 of 5 samples of the pane trace in a move", self.printed[0])

    def test_a_proof_round_of_a_build_with_no_source_says_so(self):
        self.calls.trace = {"error": "unknown action"}
        run = self.made["measure"]("2x2 unzoom proof", proof=True)
        self.assertTrue(run["move"]["no_source"])
        self.assertIn("proof round (not timed, not in the numbers): NO SOURCE: ", self.printed[0])


if __name__ == "__main__":
    unittest.main()
