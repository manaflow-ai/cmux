"""mobile-flows bench: measure.py result.json files into rows.

Fixtures are written inline: two apps' result.json for one flow, one with a fitted spring and one without.
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402


def ingest(path: Path) -> Context:
    bench = load_all()["mobile-flows"]
    ctx = Context(bench=bench, build={"channel": "sha", "version": None, "sha": "a" * 40}, host_role="anywhere")
    bench.ingest(ctx, path)
    return ctx


class MobileFlowsTests(unittest.TestCase):
    def test_rows_per_app_and_flow(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "cmux/keyboard-show").mkdir(parents=True)
            (root / "cmux/keyboard-show/result.json").write_text(json.dumps({
                "app": "cmux", "flow": "keyboard-show", "source": "simulator", "response_ms": 25.0,
                "settle_ms": 400.0, "motion_ms": 375.0, "dropped": 2, "jumps": 0,
                "curve": {"spring_response_s": 0.4, "spring_damping_fraction": 0.9}}))
            (root / "claude/new-chat").mkdir(parents=True)
            (root / "claude/new-chat/result.json").write_text(json.dumps({
                "app": "Claude", "flow": "new-chat", "source": "mac-iphone-app", "response_ms": 16.7,
                "settle_ms": 250.0, "motion_ms": 233.3, "dropped": 0, "jumps": None}))
            ctx = ingest(root)
        rows = {(r["metric"], r["labels"]["app"]): r for r in ctx.rows}
        self.assertEqual(rows[("response", "cmux")]["value"], 25.0)
        self.assertEqual(rows[("dropped", "cmux")]["unit"], "count")
        self.assertEqual(rows[("spring_damping", "cmux")]["value"], 0.9)
        self.assertEqual(rows[("settle", "Claude")]["labels"], {"app": "Claude", "flow": "new-chat", "source": "mac-iphone-app"})
        self.assertNotIn(("jumps", "Claude"), rows)
        self.assertNotIn(("spring_response", "Claude"), rows)

    def test_no_results_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(BenchError):
            ingest(Path(tmp))


if __name__ == "__main__":
    unittest.main()
