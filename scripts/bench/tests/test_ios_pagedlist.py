"""ios-pagedlist bench: PagedListStressUITests' `PAGEDLIST STRESS-…` console lines into rows.

Fixture (fixtures/ios-pagedlist/ui-console.txt): two cases in the shape PagedListStressUITests prints
(cmux-next-ios/UITests/PagedListStressUITests.swift), a non-stress PAGEDLIST line the bench skips, and
xcodebuild noise.
"""
from __future__ import annotations

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "ios-pagedlist"


def ingest(path: Path) -> Context:
    bench = load_all()["ios-pagedlist"]
    ctx = Context(bench=bench, build={"channel": "sha", "version": None, "sha": "b7e1e566ee6c" + "0" * 28},
                  host_role="fleet", host={"name": "fleet-mini", "role": "fleet", "os": "macOS 26.4", "chip": "Apple M4 Pro"})
    bench.ingest(ctx, path)
    return ctx


def find(ctx: Context, metric: str, **labels: str) -> dict:
    hits = [r for r in ctx.rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    if len(hits) != 1:
        raise AssertionError(f"{metric} {labels}: {len(hits)} rows")
    return hits[0]


class StressLines(unittest.TestCase):
    def test_console(self):
        ctx = ingest(FIX / "ui-console.txt")
        shift = find(ctx, "frame_shift_pt", direction="down", speed="fast", load="flood")
        self.assertEqual(shift["value"], 0.0)
        self.assertEqual(shift["unit"], "pt")
        self.assertEqual(shift["better"], "lower")
        self.assertNotIn("window", shift["labels"])
        self.assertAlmostEqual(find(ctx, "hitch_ms_per_s", load="flood")["value"], 2.1)
        huge = find(ctx, "in_memory_rows", direction="up", load="huge")
        self.assertEqual(huge["value"], 312)
        self.assertEqual(huge["labels"]["window"], "300")
        self.assertEqual(find(ctx, "disk_bytes", load="huge")["better"], "none")
        self.assertEqual(find(ctx, "changes_applied", load="flood")["better"], "none")
        self.assertEqual({r["labels"]["load"] for r in ctx.rows}, {"flood", "huge"})
        self.assertTrue(any("STRESS-up-fast-huge: frame shift 1.5" in n for n in ctx.notes))

    def test_evidence_zip(self):
        with tempfile.TemporaryDirectory() as tmp:
            z = Path(tmp) / "evidence.zip"
            with zipfile.ZipFile(z, "w") as out:
                out.write(FIX / "ui-console.txt", "ui-console.txt")
                out.writestr("screenshot.png", b"\x89PNG")
            ctx = ingest(z)
        self.assertEqual(find(ctx, "shifted_frames", load="huge")["value"], 2)

    def test_attachments_with_an_empty_console(self):
        with tempfile.TemporaryDirectory() as tmp:
            z = Path(tmp) / "evidence.zip"
            record = '{"direction":"down","speed":"slow","load":"inserts","window":null,"hud":{"frameShift":0.25,"hitchMsPerS":1.5}}'
            manifest = ('[{"testIdentifier":"PagedListStressUITests/testDownSlowInserts()","attachments":['
                        '{"suggestedHumanReadableName":"PAGEDLIST-STRESS-down-slow-inserts_0_ABC.txt","exportedFileName":"ABC.txt"},'
                        '{"suggestedHumanReadableName":"STRESS-down-slow-inserts-deep_0_DEF.png","exportedFileName":"DEF.png"}]}]')
            with zipfile.ZipFile(z, "w") as out:
                out.writestr("ui-console.txt", "")
                out.writestr("ui-attachments/manifest.json", manifest)
                out.writestr("ui-attachments/ABC.txt", record)
            ctx = ingest(z)
        self.assertAlmostEqual(find(ctx, "frame_shift_pt", direction="down", speed="slow", load="inserts")["value"], 0.25)
        self.assertAlmostEqual(find(ctx, "hitch_ms_per_s", load="inserts")["value"], 1.5)

    def test_nothing_to_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            empty = Path(tmp) / "ui-console.txt"
            empty.write_text("no stress lines\n")
            with self.assertRaises(BenchError):
                ingest(empty)


if __name__ == "__main__":
    unittest.main()
