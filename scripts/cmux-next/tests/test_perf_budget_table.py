#!/usr/bin/env python3
"""The budget of every producer (scripts/cmux-next/perf-budget-table.py) and its place in the perf cron's report and
issue. Pure functions only. Run: python3 -I scripts/cmux-next/tests/test_perf_budget_table.py"""
import datetime, importlib.util, os, re, tempfile, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "..", file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bt = load("perf_budget_table", "perf-budget-table.py")
cron = load("perf_cron", "perf-cron.py")
NOW = datetime.datetime(2026, 11, 19, 7, 0, tzinfo=datetime.timezone.utc)


def iso(hours_ago):
    return (NOW - datetime.timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def table(*rows):
    return [{"name": n, "producer": "p", "most": most, "unit": "ms", "rows": re.compile(rx) if rx else None,
             "max_age_h": 96.0, "harness": "h", "what": "w"} for n, most, rx in rows]


class Evaluate(unittest.TestCase):
    def test_no_value_is_not_measured_never_a_pass(self):
        r = bt.evaluate(table(("a", 8.33, r"panes\..*\.frame"), ("b", 2, "")), {}, NOW)
        self.assertEqual((r["over"], r["not_measured"]), (0, 2))
        self.assertEqual([e["why"] for e in r["rows"]], ["the cron has no row it matches", "no harness feeds the perf cron"])

    def test_worst_newest_value_on_any_host_counts(self):
        state = {"part_rows": {"panes.split.frame@m1": {"p95": 9.0, "at": iso(1), "sha": "a" * 40},
                               "panes.close.frame@m2": {"p95": 7.0, "at": iso(1)}},
                 # An older, larger value of the same row is not its newest.
                 "row_history": {"panes.split.frame@m1": [{"p95": 30.0, "at": iso(5)}]}}
        r = bt.evaluate(table(("a", 8.33, r"panes\..*\.frame")), state, NOW)
        e = r["rows"][0]
        self.assertEqual((e["state"], e["value"], e["worst"]), ("over", 9.0, "panes.split.frame@m1"))
        self.assertEqual(bt.summary_line(r), "Budget: 1 over, 0 not measured (1 rows)")

    def test_a_regressed_row_reads_its_bad_value_not_its_last_good_one(self):
        state = {"row_history": {"anim.x.main_ms_max@m": [{"p95": 5.0, "at": iso(30)}]},
                 "last": {"sha": "b" * 40, "measured_at": iso(2), "rows": {"anim.x.main_ms_max@m": {"p95": 50.0}}},
                 "regressions": [{"name": "anim.x.main_ms_max@m", "p95": 50.0}]}
        e = bt.evaluate(table(("t", 8.33, r"anim\.[^.]+\.main_ms_max")), state, NOW)["rows"][0]
        self.assertEqual((e["state"], e["value"]), ("over", 50.0))

    def test_an_old_value_is_not_measured(self):
        state = {"part_rows": {"idle.terminals.app_cpu_pct@m": {"p95": 0.1, "at": iso(97)}}}
        e = bt.evaluate(table(("c", 0.5, r"idle\.[^.]+\.app_cpu_pct")), state, NOW)["rows"][0]
        self.assertEqual(e["state"], "not measured")
        self.assertIn("no value in 96 h", e["why"])

    def test_within_limit_is_ok(self):
        state = {"pending": {"idle.terminals.app_cpu_pct@m": {"values": [{"p95": 0.2, "at": iso(1)}]}}}
        r = bt.evaluate(table(("c", 0.5, r"idle\.[^.]+\.app_cpu_pct")), state, NOW)
        self.assertEqual((r["over"], r["not_measured"], r["rows"][0]["state"]), (0, 0, "ok"))

    def test_text_lines_name_every_row_over_or_not_measured(self):
        state = {"part_rows": {"a.x@m": {"p95": 3.0, "at": iso(1)}, "b.x@m": {"p95": 1.0, "at": iso(1)}}}
        lines = bt.text_lines(bt.evaluate(table(("a", 2, r"a\.x"), ("b", 2, r"b\.x"), ("c", 2, "")), state, NOW))
        self.assertEqual(lines[0], "Budget: 1 over, 1 not measured (3 rows)")
        self.assertTrue(lines[1].startswith("OVER a "))
        self.assertTrue(lines[2].startswith("NOT MEASURED c "))
        self.assertEqual(len(lines), 3)


class Table(unittest.TestCase):
    def test_the_checked_in_table_parses_and_covers_every_producer(self):
        rows = bt.load_table()
        producers = {r["producer"] for r in rows}
        for p in ("terminal draw", "page frame", "chat transcript", "sidebar", "daemon", "main-thread turn",
                  "CPU at rest", "memory", "disk"):
            self.assertIn(p, producers)
        # Every regex names a part the cron runs (a row no part measures would be not measured for ever).
        for r in rows:
            if r["rows"] is not None:
                base = r["rows"].pattern
                self.assertTrue(any(re.match(rx, base.replace("\\", "")) for rx, _ in cron.ROW_PARTS), r["name"])

    def test_a_malformed_line_raises(self):
        with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as f:
            f.write("a\tb\t1\n")
        try:
            with self.assertRaises(ValueError):
                bt.load_table(f.name)
        finally:
            os.unlink(f.name)


class InTheCron(unittest.TestCase):
    def test_the_issue_body_carries_the_budget(self):
        body = cron.issue_body(cron.empty_state(NOW), "o/r", NOW)
        self.assertIn("Budget: 0 over, ", body)
        self.assertIn("not measured", body)

    def test_cost_does_not_grow_with_the_history(self):
        """The report reads one newest value a row: 10x the history of each row costs about the same."""
        rows = {f"anim.m{i}.main_ms_max@h": {"p95": 1.0, "at": iso(1)} for i in range(900)}

        def state(n):
            return {"part_rows": rows, "row_history": {k: [{"p95": 1.0, "at": iso(2)}] * n for k in rows}}

        def cost(s):
            t0 = time.perf_counter()
            for _ in range(5):
                bt.evaluate(bt.load_table(), s, NOW)
            return (time.perf_counter() - t0) / 5

        small, big = cost(state(12)), cost(state(120))
        self.assertLess(big, small * 3 + 0.01)


if __name__ == "__main__":
    unittest.main()
