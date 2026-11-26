"""Import contract for agent-class-duress: cells become wall rows, a capped cell a note, probes the controller's reading."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchlib.bench import Context
from benches.agent_class_duress import BENCH

FIXTURE = Path(__file__).parent / "fixtures" / "agent_class_duress" / "report.json"


class AgentClassDuressImportTest(unittest.TestCase):
    def test_rows(self):
        # A synthetic contract fixture, not performance evidence.
        ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "a" * 40}, host_role="local-readonly")
        BENCH.ingest(ctx, FIXTURE)
        walls = {(r["labels"]["load"], r["labels"]["arm"]): r["value"]
                 for r in ctx.rows if r["metric"] == "tool_loop_wall"}
        self.assertEqual(walls[("full", "dynamic")], 12.5)
        self.assertNotIn(("full", "background"), walls)
        self.assertTrue(any("cap" in n for n in ctx.notes))
        share = {r["labels"]["load"]: r["value"] for r in ctx.rows if r["metric"] == "pressured_share"}
        self.assertEqual(share, {"idle": 0.0, "full": 100.0})


if __name__ == "__main__":
    unittest.main()
