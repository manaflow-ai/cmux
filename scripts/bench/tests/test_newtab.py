"""newtab bench: instant-new-surfaces and held-new-tab outputs into rows.

Fixtures (fixtures/newtab/): launch-pairs.json and launch-pairs.log are a fleet job's artifact and log lines
(instant-new-surfaces.sh --commands=new_tab --launch-pairs=5, 2026-11-15; per-press spans trimmed);
surfaces.json is the default mode's report reconstructed from those presses (instant-new-surfaces-bench.py
main(): warm rows by phase, quick and cold rows by arm); surfaces.log holds reconstructed ARM lines
(bench_arms.report); held-invalid.log is a fleet job's HELD-NEW-TAB line (2026-11-16) whose rows never ran, and
held.json the same report with measured rows (burst-bench.py's row fields).
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

FIX = Path(__file__).resolve().parent / "fixtures" / "newtab"


def ingest(name: str | Path) -> Context:
    bench = load_all()["newtab"]
    ctx = Context(bench=bench, build={"channel": "nightly", "version": "1.0.0-nightly.1", "sha": "a" * 40},
                  host_role="fleet", host={"name": "cmux22", "role": "fleet", "os": "macOS 27.0", "chip": "Apple M4"})
    bench.ingest(ctx, FIX / name)
    return ctx


def find(ctx: Context, metric: str, **labels: str) -> dict:
    hits = [r for r in ctx.rows if r["metric"] == metric and r["labels"] == labels]
    if len(hits) != 1:
        raise AssertionError(f"{metric} {labels}: {len(hits)} rows")
    return hits[0]


class Surfaces(unittest.TestCase):
    def test_default_mode_report(self):
        ctx = ingest("surfaces.json")
        idle = find(ctx, "first_paint_ms", arm="warm", phase="idle")
        self.assertEqual(idle["n"], 6)
        self.assertEqual(idle["unit"], "ms")
        self.assertEqual(idle["better"], "lower")
        load = find(ctx, "first_paint_ms", arm="warm", phase="load")
        self.assertGreater(load["value"], idle["value"])
        ready = find(ctx, "interactive_ms", arm="warm", phase="idle")
        self.assertGreater(ready["value"], idle["value"])  # painted and taking keys comes after the paint
        cold = find(ctx, "first_paint_ms", arm="cold")
        self.assertEqual(cold["n"], 3)
        self.assertEqual(find(ctx, "missed_presses", arm="cold")["value"], 1)
        self.assertEqual(find(ctx, "missed_presses", arm="quick")["value"], 0)
        find(ctx, "confirmed_ms", arm="quick")
        find(ctx, "key_main_thread_ms", arm="warm", phase="idle")

    def test_launch_pairs_artifact(self):
        ctx = ingest("launch-pairs.json")
        first = find(ctx, "interactive_ms", arm="launch_first")
        self.assertEqual(first["n"], 5)
        self.assertAlmostEqual(first["value"], 44.926458)  # the harness's own LAUNCHPAIR-SUMMARY ready_p50
        self.assertAlmostEqual(find(ctx, "interactive_ms", arm="launch_second")["value"], 24.146125)
        self.assertAlmostEqual(find(ctx, "first_paint_ms", arm="launch_warm_ref")["value"], 31.389417)
        self.assertEqual(find(ctx, "spare_missed", arm="launch_first")["value"], 0)

    def test_an_open_that_took_an_idle_page_is_no_missed_spare(self):
        # The app's record of an open that took the page of a new tab that the person did not use: `spare` false,
        # `idle` true. A page was ready for it, so it is not a missed one; an open with neither is.
        report = json.loads((FIX / "launch-pairs.json").read_text(encoding="utf-8"))
        first = [r for r in report["runs"] if r.get("arm") == "first" and "opening" in r]
        for r in first:
            r["opening"] = {**r["opening"], "spare": False, "idle": True}
        first[0]["opening"]["idle"] = False
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "launch-pairs.json"
            path.write_text(json.dumps(report), encoding="utf-8")
            ctx = ingest(path)
        self.assertGreater(len(first), 1)
        self.assertEqual(find(ctx, "spare_missed", arm="launch_first")["value"], 1)

    def test_launch_pairs_log_matches_artifact(self):
        from_log = ingest("launch-pairs.log")
        from_json = ingest("launch-pairs.json")
        for arm in ("launch_first", "launch_second", "launch_warm_ref"):
            for metric in ("first_paint_ms", "interactive_ms"):
                self.assertAlmostEqual(find(from_log, metric, arm=arm)["value"], find(from_json, metric, arm=arm)["value"])

    def test_arm_lines(self):
        ctx = ingest("surfaces.log")
        quick = find(ctx, "first_paint_ms", arm="quick")
        self.assertEqual((quick["value"], quick["p95"], quick["n"]), (9.5, 30.2, 6))
        self.assertEqual(find(ctx, "missed_presses", arm="quick")["value"], 1)
        self.assertEqual(find(ctx, "interactive_ms", arm="warm", phase="idle")["value"], 24.0)
        self.assertEqual(len([r for r in ctx.rows if r["value"] == 6.0]), 0)  # new_terminal is not this bench


class Held(unittest.TestCase):
    def test_measured_rows(self):
        ctx = ingest("held.json")
        mixed = find(ctx, "input_to_next_commit_ms", scenario="mixed")
        self.assertEqual((mixed["value"], mixed["p95"], mixed["n"]), (10.0, 17.0, 108))
        self.assertEqual(find(ctx, "keys_without_effect", scenario="mixed")["value"], 6)
        self.assertEqual(find(ctx, "keys_without_effect", scenario="close")["better"], "none")
        self.assertEqual(find(ctx, "missed_frames", scenario="mixed")["value"], 3)  # the film take is left out
        self.assertEqual(find(ctx, "tabs_made", scenario="hold")["value"], 180)

    def held_with(self, *more: dict) -> Context:
        """held.json with `more` rows after its own, as a report in a file of its own."""
        report = json.loads((FIX / "held.json").read_text(encoding="utf-8"))
        report["rows"] += more
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "held.json"
            path.write_text(json.dumps(report), encoding="utf-8")
            return ingest(path)

    def test_a_row_with_each_number_below_the_key_that_hides_it_gives_no_row_and_a_note(self):
        # The sample take's row (held-new-tab.py, SAMPLE): its state is valid, and no count of it is outside the key.
        sample = {"scenario": "hold-sample", "round": "sample", "state": "valid", "errors": [], "invalid": [],
                  "not_for_a_person": {"why": "the system's sampler ran on the app in this take", "tabs_made": 60,
                                       "keys_without_effect": 1, "frames": {"missed": 4}},
                  "sample": {"main_thread_samples": 3000}}
        ctx = self.held_with(sample)
        self.assertEqual([r for r in ctx.rows if r["labels"].get("scenario") == "hold-sample"], [])
        self.assertEqual([n for n in ctx.notes if "hold-sample" in n],
                         ["held sample hold-sample: no number of this row is for a person: "
                          "the system's sampler ran on the app in this take"])
        # A row of a round with no proof of its keys' order has the same key: it adds nothing to its scenario's counts.
        hidden = {"scenario": "hold", "round": 3, "state": "finding", "errors": [], "invalid": [], "finding": {"keys": [1, 2]},
                  "not_for_a_person": {"why": "the row has no proof", "tabs_made": 60, "keys_without_effect": 1}}
        ctx = self.held_with(hidden)
        self.assertEqual(find(ctx, "tabs_made", scenario="hold")["value"], 180)
        self.assertEqual([n for n in ctx.notes if n.startswith("held 3 hold")],
                         ["held 3 hold: no number of this row is for a person: the row has no proof"])

    def test_a_report_with_only_such_rows_gives_no_row(self):
        report = {"hid_grant": True, "key_source": "app-queue", "rows": [
            {"scenario": "hold", "round": 0, "state": "finding", "errors": [], "invalid": [],
             "not_for_a_person": {"why": "the row has no proof", "tabs_made": 60}}]}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "held.json"
            path.write_text(json.dumps(report), encoding="utf-8")
            ctx = ingest(path)
        self.assertEqual(ctx.rows, [])
        self.assertIn("held-new-tab: no row measured what it names", ctx.notes)

    def test_rows_that_never_ran_give_no_numbers(self):
        ctx = ingest("held-invalid.log")
        self.assertEqual(ctx.rows, [])
        self.assertTrue(any("never ran its burst" in n for n in ctx.notes))


class Refusals(unittest.TestCase):
    def test_unknown_file_is_refused(self):
        with self.assertRaises(BenchError):
            ingest("../screen-share/vs.jsonl")


if __name__ == "__main__":
    unittest.main()
