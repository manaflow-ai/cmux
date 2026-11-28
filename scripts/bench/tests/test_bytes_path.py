"""bytes-path: a real `cmux-bytes bench --json` run (lane VM, 2026-11-25) -> rows; refusals for other files."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.bytes_path import BENCH  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "bytes-path" / "latest.json"


def ingest(path):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="anywhere",
                  host={"name": "lane", "role": "anywhere", "os": "Linux", "chip": "x86_64"},
                  timestamp="2026-11-25T00:00:00Z")
    BENCH.ingest(ctx, path)
    return ctx


class BytesPathTest(unittest.TestCase):
    def test_fixture_rows(self):
        doc = json.loads(FIXTURE.read_text())
        rows = ingest(FIXTURE).rows
        got = {(r["metric"], r["labels"]["folder"], r["labels"]["scenario"], r["labels"]["profile"],
                r["labels"]["strategy"]): r for r in rows}
        first = doc["rows"][0]
        key = (first["folder"], first["scenario"], first["profile"], first["strategy"])
        self.assertEqual(got[("synced", *key)]["p95"], first["synced_p95"])
        self.assertEqual(got[("wire_bytes", *key)]["value"], first["wire_bytes"])
        self.assertEqual(len(rows), 6 * len(doc["rows"]))
        # The never-grow rule: no new-path row carries grown bytes.
        self.assertFalse([r for r in rows if r["metric"] == "grown_bytes" and r["labels"]["strategy"] == "new"
                          and r["value"] > 0])

    def test_other_files_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.json"
            path.write_text(json.dumps({"schema": "other", "rows": []}))
            with self.assertRaises(BenchError):
                ingest(path)
            path.write_text("not json")
            with self.assertRaises(BenchError):
                ingest(path)


if __name__ == "__main__":
    unittest.main()
