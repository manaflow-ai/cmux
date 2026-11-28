"""cmux-tui-spec.yml's clippy job: a red clippy step that is the change's own skips the rebuilds that cannot judge it.

Lints never fail the clippy step, so its red is a compile error or a killed compiler. The panic ratchet and the
frame work contracts then rebuilt the same packages into the job's 40-min budget (2026-11-28 20-22Z). A base red,
which the clippy step marks in CMUX_CLIPPY_BASE_RED_FILE, still runs both, as scripts/ci/feat-parity-check.sh does.
"""

from __future__ import annotations

import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui-spec.yml"
GATED = ("Rust panic ratchet on changed cmux-tui packages", "visible-only frame work contracts")


class ClippyRedSkipsRatchetTest(unittest.TestCase):
    def setUp(self) -> None:
        self.steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["clippy"]["steps"]
        self.names = [item.get("name", "") for item in self.steps]

    def by_id(self, step_id: str) -> dict:
        return next(item for item in self.steps if item.get("id") == step_id)

    def test_the_clippy_step_writes_the_base_red_marker_the_gate_reads(self) -> None:
        clippy = self.by_id("clippy")
        self.assertEqual(clippy["env"]["CMUX_CLIPPY_BASE_RED_FILE"], "${{ runner.temp }}/clippy-base-red")
        gate = self.by_id("clippy-red")
        self.assertIn('-s "$RUNNER_TEMP/clippy-base-red"', gate["run"])
        self.assertIn("steps.clippy.outcome == 'failure'", gate["if"])
        self.assertIn('echo "own=true" >> "$GITHUB_OUTPUT"', gate["run"])

    def test_only_the_rebuilding_steps_wait_on_an_own_red(self) -> None:
        gate = self.names.index("Is the clippy red this change's own")
        for name in GATED:
            with self.subTest(step=name):
                item = self.steps[self.names.index(name)]
                self.assertGreater(self.names.index(name), gate)
                self.assertEqual(item["if"], "${{ !cancelled() && steps.clippy-red.outputs.own != 'true' }}")
        # The source scan reads the tree, not a build: it still runs on every change.
        self.assertEqual(self.steps[self.names.index("visible-only draw ratchet")]["if"], "${{ !cancelled() }}")

    def test_the_marker_is_the_one_the_clippy_script_writes(self) -> None:
        script = (ROOT / ".github/scripts/cmux-tui-clippy-changed.py").read_text(encoding="utf-8")
        self.assertIn('os.environ.get("CMUX_CLIPPY_BASE_RED_FILE")', script)


if __name__ == "__main__":
    unittest.main()
