"""cmux-tui-spec.yml's clippy job keeps a warm target on a cmux-runner-pool slot, behind a repo variable.

Unset (today's default) the job restores the stripped R2 build as before; set to 1 a pool slot links its own
tree (scripts/ci/machine-channel-warm-target.sh pool-dir), and a run linked to it never saves to R2.
"""

from __future__ import annotations

import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui-spec.yml"


def clippy_steps() -> list[dict]:
    job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["clippy"]
    return job["steps"]


def step(steps: list[dict], step_id: str) -> tuple[int, dict]:
    for index, item in enumerate(steps):
        if item.get("id") == step_id:
            return index, item
    raise AssertionError(f"no step with id {step_id}")


class ClippyPoolWarmTest(unittest.TestCase):
    def setUp(self) -> None:
        self.steps = clippy_steps()

    def test_gated_off_by_default(self) -> None:
        _, locate = step(self.steps, "pool-warm")
        self.assertIn("vars.CI_TUI_CLIPPY_POOL_WARM == '1'", locate["if"])
        self.assertIn("startsWith(runner.name, 'cmux-runner-pool-')", locate["if"])
        self.assertTrue(locate.get("continue-on-error"))

    def test_hit_skips_rust_cache_and_r2_restore(self) -> None:
        for step_id in ("rust-cache", "r2-cargo-key"):
            _, item = step(self.steps, step_id)
            self.assertIn("steps.pool-warm.outputs.hit != 'true'", item["if"], step_id)

    def test_link_after_restores_before_clippy(self) -> None:
        link, _ = step(self.steps, "pool-link")
        for before in ("r2-cargo-target", "r2-cargo-registry", "rust-cache"):
            self.assertLess(step(self.steps, before)[0], link, before)
        self.assertLess(link, step(self.steps, "clippy")[0])

    def test_linked_run_never_saves_to_r2(self) -> None:
        _, strip = step(self.steps, "r2-cargo-strip")
        self.assertIn("steps.pool-link.outputs.linked != 'true'", strip["if"])

    def test_record_then_release_last(self) -> None:
        names = [item.get("name", "") for item in self.steps]
        record = names.index("Record the pool warm clippy target")
        release = names.index("Release the pool warm clippy target")
        self.assertLess(record, release)
        self.assertEqual(release, len(names) - 1)
        self.assertGreater(record, names.index("visible-only frame work contracts"))


if __name__ == "__main__":
    unittest.main()
