"""instant-new-surfaces-bench.py: a --workspaces run names its idle phase `idle@<n>ws`, and its warm arm must still count
those rows. It matched only `== "idle"`, so every --workspaces run printed `HEADLINE ... = none: no arm ran` although all
its presses had results (mini scheduler jobs 2573c34af484618954ebe2d6 and 82bc0c62310721ec9eb1ed37, 120 presses each).

The bench runs at import (argument parsing, an app launch), so this test takes `arm_samples` from its source alone."""
import ast
import pathlib
import unittest

BENCH = pathlib.Path(__file__).resolve().parents[1] / "scripts/cmux-next/instant-new-surfaces-bench.py"


def load_arm_samples(arms):
    tree = ast.parse(BENCH.read_text())
    node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "arm_samples")
    scope = {"ARMS": arms}
    exec(compile(ast.Module(body=[node], type_ignores=[]), str(BENCH), "exec"), scope)
    return scope["arm_samples"]


class WarmArmTests(unittest.TestCase):
    def rows(self):
        return [
            {"phase": "idle@2ws", "command": "new_tab", "key_ms": 4.0},
            {"phase": "idle@60ws", "command": "new_tab", "key_ms": 6.0},
            {"phase": "load@60ws", "command": "new_tab", "key_ms": 20.0},
            {"phase": "quick", "arm": "quick", "command": "new_tab", "key_ms": 8.0},
            {"phase": "cold", "arm": "cold", "command": "new_tab", "key_ms": 5.0},
        ]

    def test_the_warm_arm_counts_the_idle_phase_at_every_workspace_count(self):
        arm_samples = load_arm_samples(("warm", "quick", "cold"))
        out = arm_samples(self.rows(), "new_tab", "key_ms")
        self.assertEqual(sorted(out["warm"]), [4.0, 6.0])
        self.assertEqual(out["quick"], [8.0])
        self.assertEqual(out["cold"], [5.0])

    def test_a_run_without_workspace_counts_keeps_its_idle_rows(self):
        arm_samples = load_arm_samples(("warm",))
        rows = [{"phase": "idle", "command": "new_tab", "key_ms": 3.0}, {"phase": "load", "command": "new_tab", "key_ms": 9.0}]
        self.assertEqual(arm_samples(rows, "new_tab", "key_ms")["warm"], [3.0])


if __name__ == "__main__":
    unittest.main()
