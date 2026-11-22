"""post-update: each mode's harness output becomes rows.

Fixtures: fresh-copy-*.log and shift-update.log are real fleet step logs (nightly-fresh-launch.sh on a NIGHTLY and as
a base/head build; relaunch-shift.sh --variants=update), trimmed to the lines the bench reads. update-click.log is
update-click-ab.py's own output for reconstructed timeline.json files (update-click-report.tgz holds those files): no
update-click-ab.sh step had run on the fleet yet.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "post-update"


def ingest(name: str, **args: str) -> Context:
    bench = load_all()["post-update"]
    ctx = Context(bench=bench, build={"channel": "sha", "version": None, "sha": "a" * 40}, host_role="fleet",
                  args=dict(args))
    bench.ingest(ctx, FIXTURES / name)
    return ctx


def key(row: dict) -> tuple:
    return (row["metric"],) + tuple(sorted(row["labels"].items()))


class UpdateClick(unittest.TestCase):
    def check(self, ctx: Context) -> None:
        rows = {(r["metric"], r["labels"]["arm"]): r for r in ctx.rows}
        self.assertTrue(all(r["labels"]["mode"] == "update-click" for r in ctx.rows))
        # UCA-MEDIAN base: click_to_home 4980, v2_first_frame 1180; head: 2260, 690.
        self.assertEqual(rows[("click_to_home", "base")]["value"], 4980)
        self.assertEqual(rows[("click_to_home", "head")]["value"], 2260)
        self.assertEqual(rows[("v2_first_frame", "head")]["value"], 690)
        self.assertEqual(rows[("v2_home_first_page", "head")]["value"], 800)
        self.assertEqual(rows[("prewarm_wait", "base")]["value"], 2210)
        self.assertEqual(rows[("click_to_relaunch", "head")]["n"], 3)
        self.assertEqual(len(ctx.rows), 14)
        self.assertTrue(all(r["harness"]["name"] == "scripts/measure/update-click-ab.sh" for r in ctx.rows))
        self.assertIn("post-update:update-click@1", ctx.rows[0]["harness"]["version"])

    def test_log(self) -> None:
        ctx = ingest("update-click.log")
        self.check(ctx)
        self.assertEqual(ctx.host["chip"], "Apple M6")

    def test_report_tgz(self) -> None:
        # The archive's timeline.json files, read through update-click-ab.py's own metrics().
        self.check(ingest("update-click-report.tgz", mode="update-click"))


class Shift(unittest.TestCase):
    def test_log(self) -> None:
        ctx = ingest("shift-update.log")
        rows = {r["metric"]: r for r in ctx.rows}
        self.assertTrue(all(r["labels"] == {"mode": "shift", "variant": "update"} for r in ctx.rows))
        # Three relaunches (each printed twice in the log): first_paint 1900, 1909, 408 -> median 1900.
        self.assertEqual(rows["first_paint_ms"]["value"], 1900)
        self.assertEqual(rows["first_paint_ms"]["n"], 3)
        self.assertEqual(rows["last_paint_ms"]["value"], 2228)
        self.assertEqual(rows["layout_passes"]["value"], 93)
        self.assertEqual(rows["layout_passes"]["unit"], "count")
        self.assertEqual(rows["view_layouts"]["value"], 5770)
        self.assertEqual(rows["blank_frames"]["value"], 0)
        self.assertEqual(rows["chat_appeared"]["value"], 6)
        self.assertEqual(rows["chat_first_rows"]["better"], "higher")
        self.assertIsNone(rows["chat_shifts"]["n"])
        self.assertEqual(ctx.rows[0]["harness"]["name"], "scripts/measure/relaunch-shift.sh")


class FreshCopy(unittest.TestCase):
    def test_nightly_log(self) -> None:
        ctx = ingest("fresh-copy-nightly.log")
        rows = {(r["metric"], r["labels"]["copy"]): r for r in ctx.rows}
        self.assertTrue(all(r["labels"]["arm"] == "head" and r["labels"]["mode"] == "fresh-copy" for r in ctx.rows))
        # NFL-MEDIAN fresh-copy: pre_main 1214.2, frame 2337.3, page 4250.7, harness 4512; warm pre_main 47.6.
        self.assertAlmostEqual(rows[("pre_main", "fresh-copy")]["value"], 1214.2)
        self.assertAlmostEqual(rows[("first_frame", "fresh-copy")]["value"], 2337.3)
        self.assertAlmostEqual(rows[("home_first_page", "fresh-copy")]["value"], 4250.7)
        self.assertAlmostEqual(rows[("home_rendered", "fresh-copy")]["value"], 4512)
        self.assertAlmostEqual(rows[("pre_main", "warm")]["value"], 47.6)
        self.assertEqual(rows[("pre_main", "same-copy")]["n"], 3)
        self.assertEqual(ctx.host["name"], "cmux23")
        self.assertEqual(ctx.rows[0]["harness"]["name"], "scripts/measure/nightly-fresh-launch.sh")

    def test_ab_log(self) -> None:
        # base= runs each round as its own rounds=1 run (every line says round 1): all three rounds still count.
        ctx = ingest("fresh-copy-ab.log")
        rows = {(r["metric"], r["labels"]["arm"], r["labels"]["copy"]): r for r in ctx.rows}
        self.assertEqual(rows[("pre_main", "base", "fresh-copy")]["n"], 3)
        self.assertEqual(rows[("pre_main", "head", "warm")]["n"], 3)
        self.assertEqual(len({r["labels"]["arm"] for r in ctx.rows}), 2)


class Modes(unittest.TestCase):
    def test_unknown_mode(self) -> None:
        with self.assertRaises(BenchError):
            ingest("shift-update.log", mode="nope")

    def test_wrong_mode_finds_nothing(self) -> None:
        with self.assertRaises(BenchError):
            ingest("shift-update.log", mode="update-click")

    def test_registered(self) -> None:
        bench = load_all()["post-update"]
        self.assertTrue(bench.nightly)
        self.assertEqual(bench.nightly_args["mode"], "fresh-copy")


if __name__ == "__main__":
    unittest.main()
