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


    # Session facts of sessions task 003 adds (minimized, tabs-static), until they are in ib.SESSIONS.
    FIXTURE_SESSIONS = {**ib.SESSIONS, "minimized": {"shown": False}, "tabs-static": {"shown": True, "chromium_tabs_shown": 1}}

    def test_role_audit_flags_a_hidden_renderer_at_foreground_priority(self):
        # `ps -axo pid=,pri=,nice=,flags=` of a light-hidden run: the app napped (suppressed to 28), one renderer
        # darwin background, one renderer at foreground priority (47), one at the default 31, the daemon and
        # its terminal host at 31. The darwinbg read gives only pid 201's bit.
        ps = (" 100  28   0     4004\n"
              " 200  47   0     4004\n"
              " 201   4   0     4004\n"
              " 202  31   0     4004\n"
              " 300  31   0     4004\n"
              " 301  31   0     4004\n"
              " 999  31   0     4004\n"
              "garbage line\n")
        kinds = {100: "app", 200: "cef-renderer", 201: "cef-renderer", 202: "cef-renderer", 300: "daemon",
                 301: "terminal-host"}
        priority = ib.procs.priorities(kinds, ps_output=ps, darwinbg_of=lambda pid: pid == 201)
        self.assertEqual(priority[100], {"pri": 28, "nice": 0, "flags": 0x4004, "darwinbg": False})
        self.assertNotIn(999, priority)
        rows = [{"pid": pid, "kind": kinds[pid], "role": ib.observed_role(priority[pid]), "pooled": False}
                for pid in sorted(kinds)]
        self.assertEqual([r["role"] for r in rows], ["low", "foreground", "darwinbg", "default", "default", "default"])
        mismatches = ib.role_mismatches("light-hidden", rows)
        self.assertEqual(mismatches, [{"kind": "cef-renderer", "pids": [200], "observed": "foreground",
                                       "expected": "best-effort"},
                                      {"kind": "cef-renderer", "pids": [202], "observed": "default",
                                       "expected": "best-effort"}])
        self.assertEqual(ib.role_over_line("light-hidden", mismatches[0]),
                         "IDLE-BUDGET-OVER light-hidden cef-renderer role owner=role pids=200 "
                         "observed=foreground expected=best-effort")

    def test_observed_role_bands(self):
        self.assertEqual(ib.observed_role({"pri": 47, "darwinbg": False}), "foreground")
        self.assertEqual(ib.observed_role({"pri": 63, "darwinbg": False}), "foreground")
        self.assertEqual(ib.observed_role({"pri": 46, "darwinbg": False}), "background-app")
        self.assertEqual(ib.observed_role({"pri": 31, "darwinbg": None}), "default")
        self.assertEqual(ib.observed_role({"pri": 28, "darwinbg": False}), "low")
        self.assertEqual(ib.observed_role({"pri": 46, "darwinbg": True}), "darwinbg")
        self.assertIsNone(ib.observed_role(None))
        self.assertIsNone(ib.observed_role({"pri": None}))

    def test_role_audit_app_not_napped_and_backgrounded_daemon(self):
        rows = [{"pid": 1, "kind": "app", "role": "background-app"}, {"pid": 2, "kind": "daemon", "role": "darwinbg"},
                {"pid": 3, "kind": "holder", "role": "darwinbg"}, {"pid": 4, "kind": "cef-gpu", "role": None}]
        hidden = ib.role_mismatches("minimized", rows, sessions=self.FIXTURE_SESSIONS)
        self.assertEqual(hidden, [{"kind": "app", "pids": [1], "observed": "background-app", "expected": "napped"}])
        self.assertEqual([m["kind"] for m in ib.role_mismatches("light", rows)], ["daemon"])
        shown = [{"pid": 5, "kind": "terminal-host", "role": "background-app"}]
        self.assertEqual(ib.role_mismatches("light", shown), [])

    def test_session_facts_live_in_sessions(self):
        self.assertIs(ib.SESSIONS["light-hidden"]["shown"], False)
        self.assertEqual(ib.SESSIONS["light-webkit"]["chromium_tabs_shown"], 0)
        self.assertFalse(hasattr(ib, "ROLE_SESSIONS"))
        renderer = [{"pid": 9, "kind": "cef-renderer", "role": "default"}]
        self.assertEqual(ib.role_mismatches("light-webkit", renderer)[0]["expected"], "best-effort-beyond-0-shown")

    def test_role_audit_allows_only_the_shown_tabs_renderers_above_best_effort(self):
        sessions = self.FIXTURE_SESSIONS
        rows = [{"pid": 10, "kind": "cef-renderer", "role": "default"},
                {"pid": 11, "kind": "cef-renderer", "role": "darwinbg"},
                {"pid": 12, "kind": "cef-renderer", "role": "low"}]
        self.assertEqual(ib.role_mismatches("tabs-static", rows, sessions=sessions), [])
        rows.append({"pid": 13, "kind": "cef-renderer", "role": "foreground"})
        self.assertEqual(ib.role_mismatches("tabs-static", rows, sessions=sessions),
                         [{"kind": "cef-renderer", "pids": [10, 13], "observed": "2-above-best-effort",
                           "expected": "best-effort-beyond-1-shown"}])
        extension = [{"pid": 20, "kind": "cef-extension", "role": "default"}]
        self.assertEqual(ib.role_mismatches("tabs-static", extension, sessions=sessions)[0]["expected"], "best-effort")

    def test_budget_role_override(self):
        budget = {"sessions": {"light": {"kinds": {"cef-gpu": {"role": "best-effort"}}}}}
        rows = [{"pid": 7, "kind": "cef-gpu", "role": "default"}]
        self.assertEqual(ib.role_mismatches("light", rows, budget)[0]["expected"], "best-effort")
        self.assertEqual(ib.role_mismatches("light", rows), [])
        self.assertEqual(ib.role_budget_errors(budget), [])

    def test_budget_role_override_applies_to_the_shown_renderer_count(self):
        budget = {"sessions": {"tabs-static": {"kinds": {"cef-renderer": {"role": "darwinbg"}}}}}
        rows = [{"pid": 10, "kind": "cef-renderer", "role": "default"},
                {"pid": 11, "kind": "cef-renderer", "role": "low"}]
        self.assertEqual(ib.role_mismatches("tabs-static", rows, sessions=self.FIXTURE_SESSIONS), [])
        self.assertEqual(ib.role_mismatches("tabs-static", rows, budget, sessions=self.FIXTURE_SESSIONS),
                         [{"kind": "cef-renderer", "pids": [10, 11], "observed": "2-above-darwinbg",
                           "expected": "darwinbg-beyond-1-shown"}])

    def test_unknown_budget_role_is_refused(self):
        budget = {"sessions": {"light": {"kinds": {"cef-gpu": {"role": "best-efort"}, "app": {"cpu_pct": 1}}}}}
        self.assertEqual(ib.role_budget_errors(budget),
                         ["sessions.light.kinds.cef-gpu.role is 'best-efort', not one of "
                          "best-effort, napped, darwinbg, not-background"])
        with self.assertRaises(ib.RoleBudgetError):
            ib.role_mismatches("light", [{"pid": 7, "kind": "cef-gpu", "role": "default"}], budget)

    def write_pool_record(self, pool, session, host_pid, nonce="ab12"):
        import json
        pool.mkdir(parents=True, exist_ok=True)
        (pool / f"{session}.json").write_text(json.dumps({"session_id": session, "start_nonce": nonce,
                                                          "host_pid": host_pid, "harness_pid": host_pid + 1}))
        return pool / f"{session}.{nonce}.live"

    def hold(self, path):
        import fcntl
        import os
        path.write_text("")
        fd = os.open(path, os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self.addCleanup(os.close, fd)

    def test_pooled_acpmux_agents_must_be_darwin_background(self):
        import tempfile
        with tempfile.TemporaryDirectory() as home:
            pool = Path(home, ".acpmux", "builds", "k1", "hosts", "pool")
            self.hold(self.write_pool_record(pool, "s1", 50))
            homes = ib.acpmux_homes({}, user_home=home)
            self.assertEqual(homes, [str(Path(home, ".acpmux")), str(Path(home, ".acpmux", "builds", "k1"))])
            table = [(50, 40, "acpmux __agent-host"), (51, 50, "claude"), (52, 51, "node mcp"), (60, 40, "acpmux __agent-host")]
            pooled = ib.pool_pids({40, 50, 51, 52, 60}, table, homes)
        self.assertEqual(pooled, {50, 51, 52})
        rows = [{"pid": 50, "kind": "acpmux", "role": "darwinbg", "pooled": True},
                {"pid": 51, "kind": "other:claude", "role": "low", "pooled": True},
                {"pid": 60, "kind": "acpmux", "role": "default", "pooled": False}]
        self.assertEqual(ib.role_mismatches("light", rows),
                         [{"kind": "other:claude", "pids": [51], "observed": "low", "expected": "darwinbg"}])

    def test_stale_pool_record_with_a_reused_pid_marks_nothing(self):
        import tempfile
        # pid 300 is now the cmux-tui daemon; a dead host's record still names it (no lock held, or the lock
        # file gone), and a held lock whose pid runs something other than __agent-host is not trusted either.
        table = [(300, 1, "/x/cmux DEV t.app/Contents/Resources/bin/cmux-tui server"), (301, 300, "cmux-tui __terminal-host"),
                 (302, 301, "-zsh")]
        with tempfile.TemporaryDirectory() as home:
            pool = Path(home, ".acpmux", "hosts", "pool")
            free = self.write_pool_record(pool, "dead", 300, nonce="aa")
            free.write_text("")
            self.write_pool_record(pool, "gone", 300, nonce="bb")
            self.hold(self.write_pool_record(pool, "held", 300, nonce="cc"))
            self.assertEqual(ib.pool_pids({300, 301, 302}, table, ib.acpmux_homes({}, user_home=home)), set())

    def test_acpmux_homes_follow_the_app_not_home(self):
        import os
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as account, tempfile.TemporaryDirectory() as scratch:
            Path(account, ".acpmux", "builds", "k1").mkdir(parents=True)
            Path(account, ".cmux", "chief", "com.cmuxterm.app.debug.t", "acpmux").mkdir(parents=True)
            with mock.patch.dict(os.environ, {"HOME": scratch}), \
                    mock.patch("pwd.getpwuid", return_value=mock.Mock(pw_dir=account)):
                homes = ib.acpmux_homes({"CMUX_NEXT_CHIEF_HOME": f"{scratch}/chief"})
        self.assertEqual(homes, [f"{account}/.acpmux", f"{account}/.acpmux/builds/k1", f"{scratch}/chief/acpmux",
                                 f"{account}/.cmux/chief/com.cmuxterm.app.debug.t/acpmux"])
        self.assertNotIn(f"{scratch}/.acpmux", homes)
        explicit = ib.acpmux_homes({"CMUX_NEXT_ACPMUX_ROOT": "/r", "ACPMUX_HOME": "/h"}, user_home="/u")
        self.assertEqual(explicit, ["/r", "/h"])

    def test_pool_record_under_a_chief_home_is_found(self):
        import tempfile
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as scratch:
            pool = Path(scratch, "chief", "acpmux", "hosts", "pool")
            self.hold(self.write_pool_record(pool, "c1", 70))
            homes = ib.acpmux_homes({"CMUX_NEXT_CHIEF_HOME": str(Path(scratch, "chief"))}, user_home=home)
            pooled = ib.pool_pids({70, 71}, [(70, 1, "acpmux __agent-host"), (71, 70, "codex")], homes)
        self.assertEqual(pooled, {70, 71})

    def test_aggregate_counts_roles(self):
        kinds = ib.aggregate({"processes": [{**row("cef-renderer", 10, 0.0), "role": "darwinbg"},
                                            {**row("cef-renderer", 10, 0.0), "role": "default"},
                                            {**row("cef-renderer", 10, 0.0), "role": "darwinbg"}]})
        self.assertEqual(kinds["cef-renderer"]["roles"], {"darwinbg": 2, "default": 1})
        self.assertEqual(ib.role_counts(kinds["cef-renderer"]), "darwinbg 2, default 1")

    def test_checked_in_budget_parses(self):
        budget = ib.json.load(open(ib.BUDGET_FILE))
        self.assertEqual(budget["kinds"]["app"]["main_wakes_per_s"], 0)
        self.assertEqual(ib.role_budget_errors(budget), [])


if __name__ == "__main__":
    unittest.main()
