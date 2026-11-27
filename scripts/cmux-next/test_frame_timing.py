#!/usr/bin/env python3
"""frame_timing: the transition frame log reader's p50 / p95 / count (python3 scripts/cmux-next/test_frame_timing.py)."""
import io, json, os, sys, tempfile, unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import frame_timing as ft  # noqa: E402


def line(ms, transition="divider_drag", event=True, path=None):
    row = {"transition": transition, "ms": ms, "commit_ms": ms - 1, "input_ts": 1.0, "first_frame_ts": 1.0 + ms / 1000,
           "event": event, "build": "1", "at_ms": 0}
    if path:
        row["path"] = path
    return json.dumps(row)


class ReaderTests(unittest.TestCase):
    def test_p95_of_one_to_hundred_is_ninety_five(self):
        rows, skipped = ft.read_lines([line(ms) for ms in range(1, 101)])
        stats = ft.summarize(rows)["divider_drag"]
        self.assertEqual(skipped, 0)
        self.assertEqual(stats["count"], 100)
        self.assertEqual(stats["p50_ms"], 51)
        self.assertEqual(stats["p95_ms"], 95)
        self.assertEqual(stats["max_ms"], 100)

    def test_the_slowest_tenth_sets_the_p95_and_one_in_twenty_does_not(self):
        rows, _ = ft.read_lines([line(8.3)] * 18 + [line(140.0)] * 2)
        stats = ft.summarize(rows)["divider_drag"]
        self.assertEqual((stats["p50_ms"], stats["p95_ms"], stats["max_ms"]), (8.3, 140.0, 140.0))
        rows, _ = ft.read_lines([line(8.3)] * 19 + [line(140.0)])
        self.assertEqual(ft.summarize(rows)["divider_drag"]["p95_ms"], 8.3)  # nearest rank 18 of 0..19

    def test_bad_lines_are_skipped_and_counted(self):
        rows, skipped = ft.read_lines(["", "not json", "[1]", json.dumps({"transition": "divider_drag", "ms": "x"}),
                                       json.dumps({"transition": "divider_drag", "ms": True}),
                                       json.dumps({"transition": "divider_drag", "ms": -1}), line(10)])
        self.assertEqual(len(rows), 1)
        self.assertEqual(skipped, 5)

    def test_transitions_are_apart_and_filter_and_last_apply(self):
        rows, _ = ft.read_lines([line(100)] * 5 + [line(10)] * 5 + [line(50, transition="other", event=False)])
        both = ft.summarize(rows)
        self.assertEqual(sorted(both), ["divider_drag", "other"])
        self.assertEqual(both["other"]["from_event"], 0)
        self.assertEqual(list(ft.summarize(rows, transition="divider_drag")), ["divider_drag"])
        newest = ft.summarize(rows, transition="divider_drag", last=5)["divider_drag"]
        self.assertEqual((newest["count"], newest["p95_ms"]), (5, 10))

    def test_a_path_splits_a_transition_and_the_filter_keeps_both(self):
        rows, _ = ft.read_lines([line(40, "right_split_open", path="live")] * 3 + [line(5, "right_split_open", path="snapshot")] * 3)
        stats = ft.summarize(rows, transition="right_split_open")
        self.assertEqual(sorted(stats), ["right_split_open/live", "right_split_open/snapshot"])
        self.assertEqual((stats["right_split_open/live"]["p50_ms"], stats["right_split_open/snapshot"]["p50_ms"]), (40, 5))

    def test_work_lines_get_each_counters_mean_and_max_per_drag(self):
        work = [json.dumps({"transition": "divider_drag_work", "ms": 400, "moves": 30, "fence_joined": j, "detaches": 0,
                            "build": "1", "at_ms": 0}) for j in (90, 30)]
        stats = ft.summarize(ft.read_lines(work + [line(10)])[0])
        per = stats["divider_drag_work"]["per_drag"]
        self.assertEqual(per["fence_joined"], {"mean": 60, "max": 90})
        self.assertEqual(per["moves"], {"mean": 30, "max": 30})
        self.assertNotIn("at_ms", per)
        self.assertNotIn("per_drag", stats["divider_drag"])

    def test_empty_is_none(self):
        self.assertIsNone(ft.pct([], 0.95))
        self.assertEqual(ft.summarize([]), {})

    def test_main_reads_both_halves_older_first(self):
        with tempfile.TemporaryDirectory() as home:
            folder = os.path.join(home, "Library", "Logs", "cmux-next", "release")
            os.makedirs(folder)
            with open(os.path.join(folder, ft.OLDER), "w") as f:
                f.write("\n".join(line(200) for _ in range(5)) + "\n")
            with open(os.path.join(folder, ft.FILE), "w") as f:
                f.write("\n".join(line(10) for _ in range(5)) + "\n")
            groups = ft.default_files(home)
            self.assertEqual(list(groups), ["release"])
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(ft.main(groups["release"] + ["--json"]), 0)
            stats = json.loads(out.getvalue())["files"]["transitions"]["divider_drag"]
            self.assertEqual((stats["count"], stats["p50_ms"], stats["p95_ms"]), (10, 10, 200))
            out = io.StringIO()
            with redirect_stdout(out):
                ft.main(groups["release"] + ["--last", "5"])
            self.assertIn("divider_drag: count 5  p50 10.0 ms  p95 10.0 ms", out.getvalue())


FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "frame-timing-table.jsonl")


class TableTests(unittest.TestCase):
    """`--table`: one row per surface x transition from a fixture log, worst first-frame p95 first."""

    def rows(self):
        with open(FIXTURE, encoding="utf-8") as handle:
            rows, skipped = ft.read_lines(handle)
        self.assertEqual(skipped, 0)
        return rows

    def test_one_row_per_surface_and_transition_worst_first(self):
        table = ft.table(self.rows())
        self.assertEqual([(r["surface"], r["transition"]) for r in table],
                         [("terminal", "side_close"), ("browser", "pane_close"), ("mixed", "right_split_open/live"),
                          ("terminal", "split_open"), ("unknown", "divider_drag")])  # no work line
        worst = table[0]
        self.assertEqual((worst["n"], worst["first_p50_ms"], worst["first_p95_ms"], worst["settled_p95_ms"]), (4, 57, 61, 181))
        self.assertEqual((worst["blank_pct"], worst["max_drift_px"], worst["budget"]), (75.0, 0.0, "over"))

    def test_budget_blank_and_drift_per_row(self):
        by = {(r["surface"], r["transition"]): r for r in ft.table(self.rows())}
        split = by[("terminal", "split_open")]
        self.assertEqual((split["first_p95_ms"], split["blank_pct"], split["budget"]), (12, 25.0, "ok"))
        self.assertEqual(by[("browser", "pane_close")]["max_drift_px"], 1.5)
        self.assertEqual(by[("mixed", "right_split_open/live")]["budget"], "ok")  # 15 ms: within 16
        old = by[("unknown", "divider_drag")]  # a line from before the settle: its first frame is its settle
        self.assertEqual((old["settled_p95_ms"], old["blank_pct"], old["max_drift_px"]), (8.0, None, None))

    def test_the_text_table_has_a_header_and_dashes_for_missing_fields(self):
        text = ft.format_table(ft.table(self.rows()))
        lines = text.splitlines()
        self.assertEqual(len(lines), 6)
        for head in ("surface", "transition", "ff p50", "ff p95", "settled p95", "blank %", "max drift px", "16ms"):
            self.assertIn(head, lines[0])
        self.assertTrue(lines[1].startswith("terminal  side_close"))
        self.assertTrue(lines[-1].startswith("unknown") and " - " in lines[-1])
        self.assertEqual(ft.format_table([]), "no timed transitions")

    def test_main_table_prints_it_and_json_has_it(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(ft.main([FIXTURE, "--table"]), 0)
        self.assertIn("terminal  side_close", out.getvalue())
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(ft.main([FIXTURE, "--table", "--json"]), 0)
        self.assertEqual(json.loads(out.getvalue())["files"]["table"][0]["transition"], "side_close")

    def test_new_fields_are_no_per_drag_counters(self):
        stats = ft.summarize(self.rows())
        self.assertNotIn("per_drag", stats["side_close"])


if __name__ == "__main__":
    unittest.main()
