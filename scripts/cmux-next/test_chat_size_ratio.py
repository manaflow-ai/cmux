#!/usr/bin/env python3
"""chat-size-ratio.py's pure part: sizes, a size's values, ratios, missing sizes and row names (no app).

  python3 -m unittest scripts/cmux-next/test_chat_size_ratio.py
"""
import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("chat_size_ratio", os.path.join(HERE, "chat-size-ratio.py"))
csr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(csr)

SIZES = ["mb1", "mb100", "gb1", "gb4"]


def launch(open_ms=100.0, frames=(8.0, 8.3, 9.0), key=6.0, app=300.0, unloaded=40.0, loaded=60.0, **extra):
    """One launch's record as one_launch writes it."""
    return {"open_ms": open_ms, "flings": [{"p95_ms": max(frames), "running": False,
                                            "perf_stats": {"samples": [{"interval_ms": f} for f in frames]}}],
            "key_paint_ms": key, "app_mb": app, "daemon_unloaded_mb": unloaded, "daemon_loaded_mb": loaded, **extra}


def result(**sizes):
    asked = [s for s in SIZES if s in sizes]
    return {"asked": asked, "sizes": {s: {"runs": runs} if isinstance(runs, list) else runs for s, runs in sizes.items()}}


def by_name(rows):
    return {r["name"]: r for r in rows}


class Sizes(unittest.TestCase):
    def test_names(self):
        self.assertEqual(csr.size_bytes("mb1"), 1 << 20)
        self.assertEqual(csr.size_bytes("mb100"), 100 << 20)
        self.assertEqual(csr.size_bytes("gb4"), 4 << 30)
        for bad in ("4gb", "gb0", "tb1", "mb", ""):
            with self.assertRaises(ValueError, msg=bad):
                csr.size_bytes(bad)

    def test_parse_sorts_and_needs_the_base(self):
        self.assertEqual(csr.parse_sizes("gb4,mb1,gb1,mb100"), SIZES)
        self.assertEqual(csr.parse_sizes(csr.DEFAULT_SIZES), SIZES)
        with self.assertRaises(ValueError):
            csr.parse_sizes("mb100,gb1")


class Values(unittest.TestCase):
    def test_a_size_is_the_median_of_its_launches(self):
        values, why = csr.size_values({"runs": [launch(open_ms=100), launch(open_ms=300), launch(open_ms=120)]})
        self.assertEqual(why, {})
        self.assertEqual(values["open_ms"], 120)
        self.assertEqual(values["daemon_mb"], 20.0, "loaded less unloaded")
        self.assertEqual(values["scroll_frame_ms"], 9.0, "the p95 of the page's own intervals")

    def test_a_fling_without_raw_intervals_uses_its_reply(self):
        run = launch()
        run["flings"] = [{"p95_ms": 12.5, "running": False}]
        self.assertEqual(csr.run_values(run)["scroll_frame_ms"], 12.5)

    def test_a_failed_fling_is_no_frame_time(self):
        run = launch()
        run["flings"].append({"error": "no transcript"})
        self.assertIsNone(csr.run_values(run)["scroll_frame_ms"])

    def test_a_failed_launch_makes_every_axis_missing(self):
        values, why = csr.size_values({"runs": [launch(), {"error": "the app exited during the open"}]})
        self.assertTrue(all(v is None for v in values.values()))
        self.assertIn("the app exited", why["open_ms"])

    def test_one_launch_without_a_reading_makes_that_axis_missing(self):
        values, why = csr.size_values({"runs": [launch(), launch(key=None)]})
        self.assertIsNone(values["key_paint_ms"])
        self.assertIn("1 of 2", why["key_paint_ms"])
        self.assertIsNotNone(values["open_ms"])

    def test_a_seed_error_and_no_launch_are_missing(self):
        self.assertIn("seed", csr.size_values({"error": "seed: exit 2", "runs": []})[1]["app_mb"])
        self.assertEqual(csr.size_values({"runs": []})[1]["app_mb"], "no launch ran")
        self.assertEqual(csr.size_values(None)[1]["app_mb"], "not measured")

    def test_memory_sums_only_its_kinds(self):
        sample = {"kinds": {"cef-renderer": {"footprint_mb": 200.0}, "cef-gpu": {"footprint_mb": 80.5},
                            "app": {"footprint_mb": 400.0}, "acpmux-daemon": {"footprint_mb": 33.0}}}
        self.assertEqual(csr.kinds_mb(sample, csr.RENDER_KINDS), 280.5)
        self.assertEqual(csr.kinds_mb(sample, csr.DAEMON_KINDS), 33.0)
        self.assertIsNone(csr.kinds_mb({"kinds": {"app": {"footprint_mb": 1.0}}}, csr.DAEMON_KINDS),
                          "no daemon in the sample is no reading, not 0 MB")


class Ratios(unittest.TestCase):
    def full(self):
        return result(mb1=[launch()], mb100=[launch(open_ms=150)], gb1=[launch(open_ms=200, loaded=100.0)],
                      gb4=[launch(open_ms=400, loaded=200.0, app=900.0)])

    def test_rows_are_named_per_size_and_axis(self):
        rows, incomplete, table = csr.rows_from(self.full())
        self.assertEqual(incomplete, [])
        names = by_name(rows)
        for size in SIZES:
            for axis in csr.AXIS_NAMES:
                self.assertIn(f"chat_size.{size}.{axis}", names)
                if size != "mb1":
                    self.assertIn(f"chat_size.{size}.{axis}_ratio", names)
        self.assertNotIn("chat_size.mb1.open_ms_ratio", names, "the base's own ratio is 1 by definition")
        self.assertEqual(names["chat_size.gb4.open_ms_ratio"]["p95"], 4.0)
        self.assertEqual(names["chat_size.gb4.open_ms_ratio"]["unit"], "x")
        self.assertEqual(names["chat_size.gb4.open_ms"]["unit"], "ms")
        self.assertEqual(names["chat_size.gb4.app_mb"]["unit"], "MB")
        self.assertEqual(names["chat_size.missing_readings"]["p95"], 0)
        self.assertEqual(names["chat_size.missing_readings"]["budget"], 0)
        self.assertTrue(all(r["p50"] == r["p95"] for r in rows))

    def test_ratio_max_is_the_worst_of_every_size_and_axis(self):
        rows, _incomplete, table = csr.rows_from(self.full())
        top = by_name(rows)["chat_size.ratio_max"]
        # gb4's daemon: 200 - 40 = 160 MB over mb1's 20 MB = 8x; its open is 4x and its app memory 3x.
        self.assertEqual(top["p95"], 8.0)
        self.assertEqual(top["worst"], "gb4.daemon_mb")
        self.assertEqual(table["worst"], "gb4.daemon_mb")

    def test_a_noise_denominator_is_floored(self):
        # The 1 MB chat's daemon grew 0.5 MB: over the floor (8 MB), not over 0.5.
        data = result(mb1=[launch(unloaded=40.0, loaded=40.5)], gb4=[launch(unloaded=40.0, loaded=56.0)])
        rows, _incomplete, _table = csr.rows_from(data)
        self.assertEqual(by_name(rows)["chat_size.gb4.daemon_mb_ratio"]["p95"], 16.0 / csr.RATIO_FLOOR["daemon_mb"])

    def test_a_size_that_crashed_makes_its_ratios_and_ratio_max_missing(self):
        data = self.full()
        data["sizes"]["gb4"] = {"runs": [{"error": "the app exited during the open"}]}
        rows, incomplete, table = csr.rows_from(data)
        names = by_name(rows)
        self.assertNotIn("chat_size.ratio_max", names, "a missing size is never skipped")
        self.assertIsNone(table["ratio_max"])
        self.assertFalse([n for n in names if n.startswith("chat_size.gb4.")])
        missing = {item["name"]: item["reason"] for item in incomplete}
        for axis in csr.AXIS_NAMES:
            self.assertIn("the app exited", missing[f"chat_size.gb4.{axis}_ratio"])
        self.assertIn("chat_size.ratio_max", missing)
        self.assertEqual(names["chat_size.missing_readings"]["p95"], len(csr.AXIS_NAMES))
        self.assertIn("chat_size.gb1.open_ms_ratio", names, "the other sizes keep their rows")

    def test_a_stalled_size_is_missing(self):
        data = self.full()
        data["sizes"]["gb1"] = {"runs": [{"error": "open: stalled, no first content within 120 s"}]}
        _rows, incomplete, _table = csr.rows_from(data)
        self.assertIn("stalled", {i["name"]: i["reason"] for i in incomplete}["chat_size.gb1.open_ms_ratio"])

    def test_a_missing_base_makes_every_ratio_missing(self):
        data = self.full()
        data["sizes"]["mb1"] = {"error": "seed: exit 2", "runs": []}
        rows, incomplete, _table = csr.rows_from(data)
        self.assertFalse([r for r in rows if r["name"].endswith("_ratio") or r["name"] == "chat_size.ratio_max"])
        missing = {i["name"]: i["reason"] for i in incomplete}
        self.assertIn("chat_size.mb1.open_ms", missing)
        self.assertTrue(missing["chat_size.gb4.open_ms_ratio"].startswith("mb1: seed"))

    def test_one_missing_axis_holds_ratio_max(self):
        data = self.full()
        data["sizes"]["mb100"]["runs"][0]["key_paint_ms"] = None
        rows, incomplete, _table = csr.rows_from(data)
        names = by_name(rows)
        self.assertNotIn("chat_size.ratio_max", names)
        self.assertEqual([i["name"] for i in incomplete], ["chat_size.mb100.key_paint_ms_ratio", "chat_size.ratio_max"])
        self.assertEqual(names["chat_size.missing_readings"]["p95"], 1)


class Opens(unittest.TestCase):
    def test_open_failures(self):
        self.assertIsNone(csr.open_failure({}, {"first_content_ms": 120}, 120))
        self.assertIn("stalled", csr.open_failure({}, {"timed_out": True}, 120))
        self.assertEqual(csr.open_failure({}, {}, 120), "open: no first content")
        self.assertIn("refused", csr.open_failure({"error": "refused"}, {"first_content_ms": 1}, 120))
        self.assertIn("trace", csr.open_failure({}, None, 120))


class Command(unittest.TestCase):
    def test_rows_from_a_kept_report(self):
        with tempfile.TemporaryDirectory() as folder:
            kept, out = os.path.join(folder, "kept.json"), os.path.join(folder, "rows.json")
            data = Ratios().full()
            data["sizes"]["gb4"] = {"runs": [{"error": "the app exited during the open"}]}
            with open(kept, "w") as handle:
                json.dump(data, handle)
            self.assertEqual(csr.main(["--rows-from", kept, "--json", out, "--tag", "ignored"]), 1, "incomplete exits 1")
            with open(out) as handle:
                report = json.load(handle)
            self.assertIn("chat_size.gb4.open_ms_ratio", [i["name"] for i in report["incomplete"]])
            self.assertIn("chat_size.gb1.daemon_mb_ratio", [r["name"] for r in report["rows"]])


class PerfCron(unittest.TestCase):
    """The perf cron's chat-size part: declared, its rows routed to it, and the suite dispatched."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("perf_cron", os.path.join(HERE, "perf-cron.py"))
        cls.cron = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.cron)

    def test_part(self):
        part = self.cron.PART_BY_NAME["chat-size"]
        self.assertIn("--suite=chat-size", part["args"])
        self.assertEqual(part["kind"], "budgets")
        self.assertNotEqual(part.get("where"), "linux", "a Mac part")
        for name in ("chat_size.ratio_max@cmux20-bench", "chat_size.gb4.daemon_mb_ratio", "chat_size.mb1.open_ms"):
            self.assertEqual(self.cron.part_for_row(name), "chat-size", name)

    def test_rows_read_as_budgets_rows(self):
        rows, _incomplete, _table = csr.rows_from(Ratios().full())
        got = self.cron.rows_of_part(self.cron.PART_BY_NAME["chat-size"], {"rows": rows}, None, {})
        self.assertEqual(got["chat_size.ratio_max"]["p95"], 8.0)
        self.assertEqual(got["chat_size.gb4.open_ms_ratio"]["unit"], "x")

    def test_suite_is_dispatched(self):
        with open(os.path.join(HERE, "split-spring-terminal.py")) as handle:
            text = handle.read()
        self.assertIn('"--suite=chat-size"', text)
        self.assertIn("chat-size-ratio.py", text)


if __name__ == "__main__":
    unittest.main()
