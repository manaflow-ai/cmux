#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the budget check and the perf cron rows."""

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

    def test_checked_in_budget_parses(self):
        budget = ib.json.load(open(ib.BUDGET_FILE))
        self.assertEqual(budget["kinds"]["app"]["main_wakes_per_s"], 0)

    def test_checked_in_budget_has_the_d15_zeros(self):
        with open(ib.BUDGET_FILE) as handle:
            budget = ib.json.load(handle)
        self.assertEqual(budget["all_kinds"], {"disk_bytes_per_s": 0, "log_lines": 0, "network_bytes": 0})
        for rule in budget["allowed_periodic"]:
            self.assertGreaterEqual(rule["period_s"], 15)
            self.assertTrue(rule["owner"] and rule["why"] and rule["kind"] and rule["metrics"])


# ---------------------------------------------------------------------------------------------------------
# D15: disk, network, log and WindowServer (task p14-energy-105)

# `nettop -x -n -d -L 3 -s 1`: sample 0 (totals so far) and two window samples. The app has a TLS flow and a
# listening socket; the daemon only a loopback flow; mDNSResponder is not in the set.
NETTOP = """time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
12:00:00.000000,cmux DEV t.501,,,90000,80000,0,0,0,,,,,,,,,,,,
12:00:00.000000,tcp4 192.168.1.20:50001<->17.253.4.125:443,en0,Established,90000,80000,0,0,0,20.0 ms,131072,131072,BE,-,cubic,,,,,,
12:00:00.000000,cmux-tui.502,,,5000,5000,0,0,0,,,,,,,,,,,,
12:00:00.000000,tcp4 127.0.0.1:50002<->127.0.0.1:9222,lo0,Established,5000,5000,0,0,0,,,,,,,,,,,,
time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
12:00:01.000000,cmux DEV t.501,,,120,80,0,0,0,,,,,,,,,,,,
12:00:01.000000,tcp4 192.168.1.20:50001<->17.253.4.125:443,en0,Established,120,80,0,0,0,20.0 ms,131072,131072,BE,-,cubic,,,,,,
12:00:01.000000,tcp4 *:7000<->*:*,lo0,Listen,0,0,0,0,0,,,,,,,,,,,,
12:00:01.000000,cmux-tui.502,,,0,0,0,0,0,,,,,,,,,,,,
12:00:01.000000,tcp4 127.0.0.1:50002<->127.0.0.1:9222,lo0,Established,0,0,0,0,0,,,,,,,,,,,,
12:00:01.000000,mDNSResponder.300,,,64,64,0,0,0,,,,,,,,,,,,
time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
12:00:02.000000,cmux DEV t.501,,,0,0,0,0,0,,,,,,,,,,,,
12:00:02.000000,tcp4 192.168.1.20:50001<->17.253.4.125:443,en0,Established,0,0,0,0,0,20.0 ms,131072,131072,BE,-,cubic,,,,,,
12:00:02.000000,tcp4 *:7000<->*:*,lo0,Listen,0,0,0,0,0,,,,,,,,,,,,
12:00:02.000000,cmux-tui.502,,,0,0,0,0,0,,,,,,,,,,,,
12:00:02.000000,tcp4 127.0.0.1:50002<->127.0.0.1:9222,lo0,Established,0,0,0,0,0,,,,,,,,,,,,
"""

# `log show --style ndjson --info --debug`: two app lines in the window (one subsystem, one with none), one daemon
# line, one app line before the window, a line of a pid outside the set and log's closing summary object.
LOG = "\n".join(ib.json.dumps(event) for event in [
    {"timestamp": "2026-10-25 12:00:00.500000+0000", "processID": 501, "subsystem": "com.cmuxterm.next", "category": "pump",
     "eventMessage": "tick"},
    {"timestamp": "2026-10-25 12:00:01.250000+0000", "processID": 501, "subsystem": "com.cmuxterm.next", "category": "pump",
     "eventMessage": "tick"},
    {"timestamp": "2026-10-25 12:00:01.500000+0000", "processID": 501, "subsystem": "", "category": "",
     "senderImagePath": "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", "eventMessage": "x"},
    {"timestamp": "2026-10-25 12:00:01.700000+0000", "processID": 502, "subsystem": "", "category": "",
     "senderImagePath": "/x/cmux-tui", "eventMessage": "y"},
    {"timestamp": "2026-10-25 12:00:01.800000+0000", "processID": 999, "subsystem": "com.apple.x", "category": "y"},
]) + "\n{\"count\":5,\"finished\":1}\n"
WINDOW_START = ib.procs.datetime.datetime(2026, 10, 25, 12, 0, 1, tzinfo=ib.procs.datetime.timezone.utc).timestamp()
WINDOW_END = WINDOW_START + 2

TOP = """Processes: 512 total, 3 running, 509 sleeping, 2401 threads
PID    IDLEW
157    48211+
"""


def counters_at(wakeups=0, disk=0):
    """One end of a window for process_row: (rusage counters, overhead, threads)."""
    return ((0, 0, wakeups, 0), (disk, 10, 0, 0, 0), {})


class D15ParserTests(unittest.TestCase):
    def test_nettop_counts_the_window_samples_per_pid(self):
        net = ib.procs.parse_nettop(NETTOP)
        self.assertEqual(net[501]["bytes"], 200)
        self.assertEqual(net[501]["connections"], 1)
        self.assertEqual(net[501]["remotes"], ["tcp4 17.253.4.125:443"])
        self.assertEqual(net[502], {"bytes": 0, "loopback_bytes": 0, "connections": 1, "remotes": ["tcp4 127.0.0.1:9222"]})
        self.assertEqual(net[300]["bytes"], 128)

    def test_nettop_counts_loopback_bytes_and_skips_the_totals_sample(self):
        text = NETTOP.replace("12:00:01.000000,cmux-tui.502,,,0,0", "12:00:01.000000,cmux-tui.502,,,300,0")
        text = text.replace("12:00:01.000000,tcp4 127.0.0.1:50002<->127.0.0.1:9222,lo0,Established,0,0",
                            "12:00:01.000000,tcp4 127.0.0.1:50002<->127.0.0.1:9222,lo0,Established,300,0")
        net = ib.procs.parse_nettop(text)
        self.assertEqual(net[502]["bytes"], 300)  # not the 10000 of sample 0
        self.assertEqual(net[502]["loopback_bytes"], 300)
        self.assertEqual(net[501]["loopback_bytes"], 0)

    def test_nettop_of_nothing_is_empty(self):
        self.assertEqual(ib.procs.parse_nettop(""), {})

    def test_nettop_command_covers_the_window(self):
        command = ib.procs.nettop_command(60)
        self.assertEqual(command[0], "/usr/bin/nettop")
        self.assertEqual(command[command.index("-L") + 1], "61")
        self.assertIn("-x", command)
        self.assertIn("-d", command)

    def test_log_counts_lines_of_the_set_inside_the_window(self):
        logs = ib.procs.parse_log(LOG, {501, 502}, WINDOW_START, WINDOW_END)
        self.assertEqual(logs[501], {"lines": 2, "owners": {"com.cmuxterm.next:pump": 1, "AppKit": 1}})
        self.assertEqual(logs[502], {"lines": 1, "owners": {"cmux-tui": 1}})
        self.assertNotIn(999, logs)
        self.assertEqual(ib.procs.parse_log(LOG, {501})[501]["lines"], 3)  # no window: every line

    def test_log_command_names_every_pid(self):
        command = ib.procs.log_command({502, 501}, WINDOW_START + 0.4, WINDOW_END + 0.2)
        self.assertEqual(command[command.index("--predicate") + 1], "processID == 501 OR processID == 502")
        self.assertIn("ndjson", command)
        self.assertIn("--debug", command)

    def test_top_idlew(self):
        self.assertEqual(ib.procs.parse_top_idlew(TOP, 157), 48211)
        self.assertIsNone(ib.procs.parse_top_idlew(TOP, 158))


class D15BudgetTests(unittest.TestCase):
    BUDGET = {"all_kinds": {"disk_bytes_per_s": 0, "log_lines": 0, "network_bytes": 0},
              "kinds": {"app": {"wakeups_per_s": 1.0}}}

    def rows(self, network, logs, app_disk=0):
        procs_ = {501: f"{APP}/Contents/MacOS/cmux DEV", 502: f"{APP}/Contents/Resources/bin/cmux-tui server --socket s"}
        return [ib.process_row(pid, cmd, counters_at(), counters_at(disk=app_disk if pid == 501 else 0), 60.0, network, logs)
                for pid, cmd in procs_.items()]

    def test_rows_and_kinds_carry_disk_network_and_log(self):
        network = ib.procs.parse_nettop(NETTOP)
        logs = ib.procs.parse_log(LOG, {501, 502}, WINDOW_START, WINDOW_END)
        kinds = ib.aggregate({"processes": self.rows(network, logs, app_disk=6000)})
        self.assertEqual(kinds["app"]["disk_bytes"], 6000)
        self.assertEqual(kinds["app"]["disk_bytes_per_s"], 100.0)
        self.assertEqual(kinds["app"]["network_bytes"], 200)
        self.assertEqual(kinds["app"]["connections"], 1)
        self.assertEqual(kinds["app"]["log_lines"], 2)
        self.assertEqual(kinds["daemon"]["disk_bytes_per_s"], 0)
        self.assertEqual(kinds["daemon"]["network_bytes"], 0)
        self.assertEqual(kinds["daemon"]["log_lines"], 1)

    def test_4kb_written_by_the_app_prints_an_over(self):
        kinds = ib.aggregate({"processes": self.rows({}, {}, app_disk=4096)})
        overs = ib.over_budget("light", kinds, self.BUDGET)
        self.assertEqual(overs, [("app", "disk_bytes_per_s", round(4096 / 60, 3), 0)])
        self.assertEqual(ib.over_lines("light", overs, kinds),
                         [f"IDLE-BUDGET-OVER light app disk_bytes_per_s {round(4096 / 60, 3)} > 0 pids=501"])

    def test_quiet_processes_are_in_budget(self):
        kinds = ib.aggregate({"processes": self.rows({}, {})})
        self.assertEqual(ib.over_budget("light", kinds, self.BUDGET), [])

    def test_a_failed_reader_is_not_measured_not_a_pass_or_an_over(self):
        kinds = ib.aggregate({"processes": self.rows(None, None)})
        self.assertIsNone(kinds["app"]["network_bytes"])
        self.assertIsNone(kinds["app"]["log_lines"])
        self.assertEqual(ib.over_budget("light", kinds, self.BUDGET), [])

    def test_log_and_network_overs_name_their_owners(self):
        network = ib.procs.parse_nettop(NETTOP)
        logs = ib.procs.parse_log(LOG, {501, 502}, WINDOW_START, WINDOW_END)
        kinds = ib.aggregate({"processes": self.rows(network, logs)})
        lines = ib.over_lines("light", ib.over_budget("light", kinds, self.BUDGET), kinds)
        self.assertIn("IDLE-BUDGET-OVER light app network_bytes 200 > 0 remotes=tcp4 17.253.4.125:443", lines)
        self.assertIn("IDLE-BUDGET-OVER light app log_lines 2 > 0 owners=com.cmuxterm.next:pump=1,AppKit=1", lines)
        self.assertIn("IDLE-BUDGET-OVER light daemon log_lines 1 > 0 owners=cmux-tui=1", lines)

    def test_allowed_periodic_excuses_only_its_kind_metric_and_remote(self):
        network = ib.procs.parse_nettop(NETTOP)
        kinds = ib.aggregate({"processes": self.rows(network, {})})
        rule = {"owner": "PL-sync", "period_s": 30, "why": "feed poll", "kind": "app", "metrics": ["network_bytes"],
                "remote": "17.253.4.125:443"}
        self.assertEqual(ib.over_budget("light", kinds, {**self.BUDGET, "allowed_periodic": [rule]}), [])
        other = {**rule, "remote": "1.1.1.1:443"}
        self.assertEqual([o[:2] for o in ib.over_budget("light", kinds, {**self.BUDGET, "allowed_periodic": [other]})],
                         [("app", "network_bytes")])

    def test_kind_limits_override_all_kinds(self):
        budget = {**self.BUDGET, "kinds": {"daemon": {"log_lines": {"stress": 5}}, "holder": {"log_lines": None}}}
        logs = ib.procs.parse_log(LOG, {501, 502}, WINDOW_START, WINDOW_END)
        kinds = ib.aggregate({"processes": self.rows({}, logs)})
        kinds["holder"] = {**kinds["daemon"], "log_lines": 9}
        self.assertEqual([o[:2] for o in ib.over_budget("stress", kinds, budget)], [("app", "log_lines")])
        # light has no daemon number: all_kinds' 0 judges it; the holder's explicit null is reported, not judged
        self.assertEqual([o[:2] for o in ib.over_budget("light", kinds, budget)],
                         [("daemon", "log_lines"), ("app", "log_lines")])
        self.assertEqual(ib.kind_limits(budget, "daemon", "light")["log_lines"], 0)
        self.assertEqual(ib.kind_limits(budget, "daemon", "stress")["log_lines"], 5)
        self.assertIsNone(ib.kind_limits(budget, "holder", "light")["log_lines"])

    def test_cron_rows_have_the_d15_units(self):
        report = {"sessions": {"light": {"kinds": {"app": {"disk_bytes_per_s": 68.267, "network_bytes": 0, "log_lines": None}}}}}
        rows = ib.cron_rows(report, self.BUDGET)
        self.assertEqual(rows["idle_budget.light.app.disk_bytes_per_s"],
                         {"p50": 68.267, "p95": 68.267, "unit": "B/s", "budget": 0, "floor": 0.5})
        self.assertEqual(rows["idle_budget.light.app.network_bytes"]["unit"], "bytes")
        self.assertNotIn("idle_budget.light.app.log_lines", rows)


class WindowServerTests(unittest.TestCase):
    def test_rate_and_delta_against_the_hidden_reference(self):
        rate = ib.windowserver_rate((157, 1000, "rusage", 10.0), (157, 1600, "rusage", 70.0))
        self.assertEqual(rate, 10.0)
        self.assertEqual(ib.windowserver_report(rate, 7.5, "rusage"),
                         {"source": "rusage", "wakeups_per_s": 10.0, "hidden_reference_per_s": 7.5, "delta_per_s": 2.5})

    def test_no_rate_across_a_restart_or_a_source_change(self):
        self.assertIsNone(ib.windowserver_rate((157, 1000, "rusage", 0.0), (158, 1600, "rusage", 60.0)))
        self.assertIsNone(ib.windowserver_rate((157, 1000, "rusage", 0.0), (157, 1600, "top-idlew", 60.0)))
        self.assertIsNone(ib.windowserver_report(None, 7.5, "unreadable")["delta_per_s"])

    def test_windowserver_is_reported_never_judged(self):
        kinds = {"app": {"wakeups_per_s": 0.1}}
        budget = {"all_kinds": {"disk_bytes_per_s": 0}, "kinds": {"windowserver": {"wakeups_per_s": 0}}}
        self.assertEqual(ib.over_budget("light", kinds, budget), [])


if __name__ == "__main__":
    unittest.main()
