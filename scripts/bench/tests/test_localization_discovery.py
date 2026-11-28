"""Import accepts only receipts that preserve the fixture's source coverage."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchlib.bench import BenchError, Context
from benches.localization_discovery import BENCH


class LocalizationDiscoveryTest(unittest.TestCase):
    def test_import_and_reject_changed_coverage(self):
        fixture = Path(__file__).parent / "fixtures/localization-discovery/current.json"
        ctx = Context(bench=BENCH, build={"channel": "local"}, host_role="anywhere")
        BENCH.ingest(ctx, fixture)
        self.assertEqual([row["metric"] for row in ctx.rows], ["directory_reads", "discovery"])
        self.assertEqual(ctx.rows[0]["value"], 2)
        data = json.loads(fixture.read_text())
        data["files"] = []
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "bad.json"
            path.write_text(json.dumps(data))
            with self.assertRaises(BenchError):
                BENCH.ingest(ctx, path)


if __name__ == "__main__":
    unittest.main()
