"""persona-walk: a walk's report becomes rows (timings, footprint, stuck points, a failed first reply)."""
from __future__ import annotations

import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.persona_walk import BENCH  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "persona-walk"


def ingest(path: Path) -> Context:
    ctx = Context(bench=BENCH, build={"channel": "nightly", "version": None, "sha": None},
                  host_role="fleet", host={"name": "worker", "role": "fleet", "os": "macOS 26", "chip": "M4"})
    BENCH.ingest(ctx, path)
    return ctx


def values(ctx: Context) -> dict[str, float]:
    return {r["metric"] + "".join(f"[{v}]" for v in r["labels"].values()): r["value"] for r in ctx.rows}


class PersonaWalkTests(unittest.TestCase):
    def test_registered_nightly_on_a_display_worker(self) -> None:
        self.assertEqual(BENCH.name, "persona-walk")
        self.assertTrue(BENCH.nightly)
        self.assertEqual(BENCH.nightly_args.get("mode"), "p0")

    def test_report_directory(self) -> None:
        got = values(ingest(FIX))
        self.assertEqual(got["install"], 19939.0)
        self.assertEqual(got["first_window"], 1658.0)
        self.assertEqual(got["first_command"], 4534.0)
        self.assertEqual(got["footprint[first-window]"], 64.0)
        self.assertEqual(got["footprint[after-5s]"], 262.0)
        # Only the walk's own timestamped lines count; the CLI's "FAIL daemon" output is not a stuck point.
        self.assertEqual(got["stuck_points"], 1.0)
        self.assertEqual(got["first_reply_failed"], 1.0)

    def test_report_tgz(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tgz = Path(tmp) / "report.tgz"
            with tarfile.open(tgz, "w:gz") as tar:
                for f in FIX.iterdir():
                    tar.add(f, arcname=f"./{f.name}")
            self.assertEqual(values(ingest(tgz))["first_window"], 1658.0)

    def test_a_clean_walk_has_no_stuck_points(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "timings.jsonl").write_text('{"step":"install","ms":100}\n')
            (d / "log.txt").write_text("05:00:00 step install 100 ms\n05:00:01 done\n")
            ctx = ingest(d)
            got = values(ctx)
            self.assertEqual(got["stuck_points"], 0.0)
            self.assertEqual(got["first_reply_failed"], 0.0)
            self.assertIn("persona-walk: first_window not reached", ctx.notes)

    def test_not_a_report(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(BenchError):
                ingest(Path(tmp))


if __name__ == "__main__":
    unittest.main()
