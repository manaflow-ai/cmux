"""The lane-gh fast-checks workflow starts on our fleet before Blacksmith overflow."""
from pathlib import Path
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/fast-checks.yml"


class FastChecksFleetFirst(unittest.TestCase):
    def test_default_is_fleet_and_runner_input_declares_fleet(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        runs_on = next(line for line in text.splitlines() if "runs-on:" in line)
        self.assertIn("cmux-fleet-linux-x64", runs_on)
        self.assertNotIn("fromJSON(vars.RUNNER_POOLS)", runs_on)
        self.assertIn("cmux-fleet-linux-x64", text)


if __name__ == "__main__":
    unittest.main()
