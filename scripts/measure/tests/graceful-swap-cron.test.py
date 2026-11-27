#!/usr/bin/env python3
"""graceful-swap-cron.py's rows (the perf cron's hot-swap part): a valid run gives each surface's p95 row under its
bar; a run that lost a draft or showed a transient frame gives red count rows and no p95; a surface with no receipt
is named incomplete."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gsw_cron", os.path.join(HERE, "..", "graceful-swap-cron.py"))
gsw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gsw)


def receipt(surface, watch, p95, kept=20, transient=0, runs=20, n=20):
    return {"surface": surface, "watch": watch, "runs": runs,
            "regions": {watch: {"n": n, "missed": runs - n, "p50_ms": p95 and p95 / 2, "p95_ms": p95},
                        "other": {"kept": kept, "lost": runs - kept, "transient_frames": transient}}}


class RowsFrom(unittest.TestCase):
    def test_valid_runs_give_p95_rows_with_bars(self):
        rows, incomplete = gsw.rows_from([receipt("focused", "chat-a", 90), receipt("unfocused", "chat-b", 210),
                                          receipt("hidden", "chat-c", 60)])
        by = {r["name"]: r for r in rows}
        self.assertEqual(incomplete, [])
        self.assertEqual(by["hot_swap.mac.focused_pane.p95_ms"]["budget"], 150.0)
        self.assertEqual(by["hot_swap.mac.unfocused_pane.p95_ms"]["p95"], 210)
        self.assertEqual(by["hot_swap.mac.unfocused_pane.p95_ms"]["budget"], 300.0)
        self.assertEqual(by["hot_swap.mac.hidden_tab.p95_ms"]["budget"], 100.0)
        self.assertEqual(by["hot_swap.mac.hidden_tab.drafts_lost"]["p95"], 0)

    def test_a_lost_draft_or_transient_frame_is_invalid(self):
        rows, incomplete = gsw.rows_from([receipt("focused", "chat-a", 90, kept=19),
                                          receipt("unfocused", "chat-b", 210, transient=2)])
        names = {r["name"]: r for r in rows}
        self.assertNotIn("hot_swap.mac.focused_pane.p95_ms", names)
        self.assertNotIn("hot_swap.mac.unfocused_pane.p95_ms", names)
        self.assertEqual(names["hot_swap.mac.focused_pane.drafts_lost"]["p95"], 1)
        self.assertEqual(names["hot_swap.mac.unfocused_pane.transient_frames"]["p95"], 2)
        self.assertTrue(any(w.startswith("focused: invalid run") for w in incomplete))
        self.assertIn("hidden: no latency receipt", incomplete)

    def test_a_watched_region_that_never_changed_has_no_p95(self):
        rows, incomplete = gsw.rows_from([receipt("hidden", "chat-c", None, n=0)])
        self.assertNotIn("hot_swap.mac.hidden_tab.p95_ms", {r["name"] for r in rows})
        self.assertTrue(any("never changed" in w for w in incomplete))


if __name__ == "__main__":
    unittest.main()
