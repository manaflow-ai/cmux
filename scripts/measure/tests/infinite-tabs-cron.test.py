#!/usr/bin/env python3
"""infinite-tabs-cron.py's rows (the perf cron's infinite-tabs part): the bench's PERF_ROW lines become rows, noise
lines and malformed rows are skipped, and a later row of a name wins."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("itabs_cron", os.path.join(HERE, "..", "infinite-tabs-cron.py"))
itc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(itc)


class RowsFrom(unittest.TestCase):
    def test_perf_rows_are_read_and_noise_is_skipped(self):
        log = "\n".join([
            "INFTABS-SUMMARY memory_vs_empty=1.9",
            'PERF_ROW {"name": "infinite_tabs.mac.memory_vs_empty", "p50": 1.9, "p95": 1.9, "unit": "x"}',
            "PERF_ROW {not json",
            'PERF_ROW {"name": "infinite_tabs.mac.idle_cpu_pct", "p50": 0.4, "p95": 0.4, "unit": "%"}',
            'PERF_ROW {"name": "infinite_tabs.mac.memory_vs_empty", "p50": 1.7, "p95": 1.7, "unit": "x"}',
            'PERF_ROW {"name": "no_p95"}',
            "PERF_REPORT {}"])
        by = {r["name"]: r for r in itc.rows_from(log)}
        self.assertEqual(sorted(by), ["infinite_tabs.mac.idle_cpu_pct", "infinite_tabs.mac.memory_vs_empty"])
        self.assertEqual(by[itc.GOAL_ROW]["p95"], 1.7)


if __name__ == "__main__":
    unittest.main()
