#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the budget check, the role audit and the perf cron rows."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "perf-bench"))
spec = importlib.util.spec_from_file_location("idle_budget", HERE / "idle-budget.py")
ib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ib)

APP = "/Users/x/DerivedData/cmux-t/Build/Products/Debug/cmux DEV t.app"


def row(kind, threads, wakeups, cpu=0.0):
    return {"kind": kind, "threads": threads, "threads_ran": 0, "wakeups_per_s": wakeups, "csw_per_s": 0.0, "cpu_pct": cpu}


class IdleBudgetTests(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux DEV"), "app")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui server --socket s"), "daemon")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui __holder --socket s"), "holder")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui __terminal-host --owner a@1"), "terminal-host")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/acpmux daemon"), "acpmux")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/x --type=renderer"), "cef-renderer")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (GPU).app/x --type=gpu-process"), "cef-gpu")
        self.assertEqual(ib.kind("/bin/zsh -l"), "other:zsh")

    def test_aggregate_sums_and_maxes_per_kind(self):
        kinds = ib.aggregate({"processes": [row("terminal-host", 3, 0.0), row("terminal-host", 5, 0.5), row("app", 40, 2.0)],
                              "main_wakes_per_s": 1.5})
        self.assertEqual(kinds["terminal-host"]["n"], 2)
        self.assertEqual(kinds["terminal-host"]["threads"], 8)
        self.assertEqual(kinds["terminal-host"]["threads_max"], 5)
        self.assertEqual(kinds["terminal-host"]["wakeups_max"], 0.5)
        self.assertEqual(kinds["app"]["main_wakes_per_s"], 1.5)

    def test_over_budget_names_each_value_over_its_limit(self):
        budget = {"kinds": {"app": {"main_wakes_per_s": 0, "wakeups_per_s": 1.0, "threads_max": None},
                            "holder": {"wakeups_max": {"light": 0, "stress": 1}}}}
        kinds = {"app": {"main_wakes_per_s": 0.2, "wakeups_per_s": 0.9, "threads_max": 99},
                 "holder": {"wakeups_max": 0.5}}
        self.assertEqual(ib.over_budget("light", kinds, budget), [("app", "main_wakes_per_s", 0.2, 0), ("holder", "wakeups_max", 0.5, 0)])
        self.assertEqual(ib.over_budget("stress", kinds, budget), [("app", "main_wakes_per_s", 0.2, 0)])

    def test_cron_rows(self):
        report = {"sessions": {"light": {"kinds": {"app": {"wakeups_per_s": 0.4, "threads_max": 30, "main_wakes_per_s": 0}}}}}
        rows = ib.cron_rows(report, {"kinds": {"app": {"wakeups_per_s": 1.0}}})
        self.assertEqual(rows["idle_budget.light.app.wakeups_per_s"],
                         {"p50": 0.4, "p95": 0.4, "unit": "/s", "budget": 1.0, "floor": 0.5})
        self.assertEqual(rows["idle_budget.light.app.threads_max"]["unit"], "threads")
        self.assertIsNone(rows["idle_budget.light.app.threads_max"]["budget"])

    def test_role_audit_flags_a_hidden_renderer_at_foreground_priority(self):
        # `ps -axo pid=,pri=,nice=,flags=` of a light-hidden run: the app napped (suppressed to 28), one renderer
        # darwin background, one renderer still at the default 31, the daemon and its terminal host at 31.
        ps = (" 100  28   0     4004\n"
              " 200  31   0     4004\n"
              " 201   4   0     4004\n"
              " 300  31   0     4004\n"
              " 301  31   0     4004\n"
              "garbage line\n")
        priority = ib.procs.parse_priorities(ps)
        self.assertEqual(priority[100], {"pri": 28, "nice": 0, "flags": 0x4004})
        priority[201]["darwinbg"] = True
        kinds = {100: "app", 200: "cef-renderer", 201: "cef-renderer", 300: "daemon", 301: "terminal-host"}
        rows = [{"pid": pid, "kind": kinds[pid], "role": ib.observed_role(priority[pid]), "pooled": False}
                for pid in sorted(kinds)]
        self.assertEqual([r["role"] for r in rows], ["low", "default", "darwinbg", "default", "default"])
        mismatches = ib.role_mismatches("light-hidden", rows)
        self.assertEqual(mismatches, [{"kind": "cef-renderer", "pids": [200], "observed": "default",
                                       "expected": "best-effort"}])
        self.assertEqual(ib.role_over_line("light-hidden", mismatches[0]),
                         "IDLE-BUDGET-OVER light-hidden cef-renderer role owner=role pids=200 "
                         "observed=default expected=best-effort")

    def test_role_audit_app_not_napped_and_backgrounded_daemon(self):
        rows = [{"pid": 1, "kind": "app", "role": "foreground"}, {"pid": 2, "kind": "daemon", "role": "darwinbg"},
                {"pid": 3, "kind": "holder", "role": "darwinbg"}, {"pid": 4, "kind": "cef-gpu", "role": None}]
        self.assertEqual([m["kind"] for m in ib.role_mismatches("minimized", rows)], ["app"])
        self.assertEqual([m["kind"] for m in ib.role_mismatches("light", rows)], ["daemon"])
        self.assertEqual(ib.observed_role({"pri": 47, "darwinbg": False}), "foreground")
        self.assertIsNone(ib.observed_role(None))

    def test_role_audit_allows_only_the_shown_tabs_renderers_above_best_effort(self):
        rows = [{"pid": 10, "kind": "cef-renderer", "role": "default"},
                {"pid": 11, "kind": "cef-renderer", "role": "darwinbg"},
                {"pid": 12, "kind": "cef-renderer", "role": "low"}]
        self.assertEqual(ib.role_mismatches("tabs-static", rows), [])
        rows.append({"pid": 13, "kind": "cef-renderer", "role": "foreground"})
        self.assertEqual(ib.role_mismatches("tabs-static", rows),
                         [{"kind": "cef-renderer", "pids": [10, 13], "observed": "2-above-best-effort",
                           "expected": "best-effort-beyond-1-shown"}])
        extension = [{"pid": 20, "kind": "cef-extension", "role": "default"}]
        self.assertEqual(ib.role_mismatches("tabs-static", extension)[0]["expected"], "best-effort")

    def test_pooled_acpmux_agents_must_be_darwin_background(self):
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as home:
            pool = Path(home, ".acpmux", "builds", "k1", "hosts", "pool")
            pool.mkdir(parents=True)
            (pool / "s1.json").write_text(json.dumps({"host_pid": 50, "harness_pid": 51}))
            (pool / "s1.abc.live").write_text("")
            homes = ib.acpmux_homes(home)
            self.assertEqual(homes, [str(Path(home, ".acpmux")), str(Path(home, ".acpmux", "builds", "k1"))])
            table = [(50, 40, "acpmux __agent-host"), (51, 50, "claude"), (52, 51, "node mcp"), (60, 40, "acpmux __agent-host")]
            pooled = ib.pool_pids({40, 50, 51, 52, 60}, table, homes)
        self.assertEqual(pooled, {50, 51, 52})
        rows = [{"pid": 50, "kind": "acpmux", "role": "darwinbg", "pooled": True},
                {"pid": 51, "kind": "other:claude", "role": "low", "pooled": True},
                {"pid": 60, "kind": "acpmux", "role": "default", "pooled": False}]
        self.assertEqual(ib.role_mismatches("light", rows),
                         [{"kind": "other:claude", "pids": [51], "observed": "low", "expected": "darwinbg"}])

    def test_budget_role_override(self):
        budget = {"sessions": {"light": {"kinds": {"cef-gpu": {"role": "best-effort"}}}}}
        rows = [{"pid": 7, "kind": "cef-gpu", "role": "default"}]
        self.assertEqual(ib.role_mismatches("light", rows, budget)[0]["expected"], "best-effort")
        self.assertEqual(ib.role_mismatches("light", rows), [])

    def test_aggregate_counts_roles(self):
        kinds = ib.aggregate({"processes": [{**row("cef-renderer", 10, 0.0), "role": "darwinbg"},
                                            {**row("cef-renderer", 10, 0.0), "role": "default"},
                                            {**row("cef-renderer", 10, 0.0), "role": "darwinbg"}]})
        self.assertEqual(kinds["cef-renderer"]["roles"], {"darwinbg": 2, "default": 1})
        self.assertEqual(ib.role_counts(kinds["cef-renderer"]), "darwinbg 2, default 1")

    def test_checked_in_budget_parses(self):
        budget = ib.json.load(open(ib.BUDGET_FILE))
        self.assertEqual(budget["kinds"]["app"]["main_wakes_per_s"], 0)


if __name__ == "__main__":
    unittest.main()
