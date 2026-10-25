#!/usr/bin/env python3
"""host_env.py on canned probe outputs: one reason per failing check, a stable fingerprint, bounded waits.

  python3 -m unittest scripts/perf-lab/tests/test_host_env.py
"""
import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


host_env = load("host_env_under_test", HERE.parent / "host_env.py")

BENCH = "bench"
APP_PID, DAEMON_PID = 4100, 4101
THERM_OK = """Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
"""
THERM_THROTTLED = """Note: No thermal warning level has been recorded
CPU Power notify
\tCPU_Scheduler_Limit \t= 100
\tCPU_Available_CPUs \t= 12
\tCPU_Speed_Limit \t= 78
"""
PMSET_OK = """System-wide power settings:
Currently in use:
 standby              0
 Sleep On Power Button 1
 hibernatemode        0
 powernap             0
 disksleep            0
 sleep                0 (sleep prevented by sharingd, powerd)
 displaysleep         0
 lowpowermode         0
"""
LOADAVG_OK = "{ 0.42 0.80 1.10 }\n"
LOADAVG_HIGH = "{ 2.30 1.80 1.10 }\n"
VM_STAT_OK = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              400000.
Pages active:                            300000.
Pages inactive:                          300000.
Pages speculative:                        10000.
"""
VM_STAT_LOW = VM_STAT_OK.replace("400000.", "100000.").replace("Pages inactive:                          300000.",
                                                               "Pages inactive:                          100000.")
MDUTIL_OFF = "/System/Volumes/Data:\n\tIndexing disabled.\n"
MDUTIL_ON = "/System/Volumes/Data:\n\tIndexing enabled. \n"
SCUTIL_BENCH = "<dictionary> {\n  GID : 20\n  Name : bench\n  UID : 501\n}\n"
SCUTIL_LOGINWINDOW = "<dictionary> {\n  Name : loginwindow\n}\n"
PS_OK = f"""    1 /sbin/launchd
 {APP_PID} /tmp/work/app/cmux DEV perf-lab.app/Contents/MacOS/cmux DEV
 {DAEMON_PID} /tmp/work/app/cmux DEV perf-lab.app/Contents/Resources/bin/cmux-tui
 4200 /tmp/work/app/cmux DEV perf-lab.app/Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper
"""
PS_OTHER = PS_OK + " 900 /Applications/cmux.app/Contents/MacOS/cmux\n"
NETTOP_HEADER = "time,,interface,state,bytes_in,bytes_out,\n"
NETTOP_LOCAL = NETTOP_HEADER + f"""12:00:00.000001,cmux DEV.{APP_PID},,,100,100,
12:00:00.000002,tcp4 127.0.0.1:50211<->127.0.0.1:41000,lo0,Established,100,100,
12:00:00.000003,tcp6 ::1.50212<->::1.41001,lo0,Established,0,0,
12:00:00.000004,udp4 *:5353<->*:*,,,0,0,
12:00:00.000005,cmux-tui.{DAEMON_PID},,,0,0,
"""
NETTOP_EGRESS = NETTOP_LOCAL + "12:00:01.000000,tcp4 192.168.1.20:50300<->17.57.146.20:443,en0,Established,0,10,\n"
NETTOP_OTHER_PROCESS = NETTOP_LOCAL + """12:00:01.000000,apsd.300,,,0,0,
12:00:01.000001,tcp4 192.168.1.20:50300<->17.57.146.20:5223,en0,Established,0,10,
"""
VDISPLAY_120 = "ready 7 8.333 main=7\n"
VDISPLAY_60 = "ready 7 16.667 main=7\n"
SYSCTL = {"machdep.cpu.brand_string": "Apple M4 Pro", "hw.memsize": str(24 * 2**30)}
SW_VERS = {"-productVersion": "26.1", "-buildVersion": "25B78"}


class FakeClock:
    def __init__(self):
        self.now, self.slept = 1000.0, []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.now += seconds


class FakeCommands:
    """Canned stdout per probe; `nettop` advances the fake clock by the window it watches."""

    def __init__(self, clock, **overrides):
        self.clock, self.calls = clock, []
        self.out = {"therm": THERM_OK, "pmset": PMSET_OK, "loadavg": [LOADAVG_OK], "vm_stat": VM_STAT_OK,
                    "mdutil": MDUTIL_OFF, "scutil": SCUTIL_BENCH, "ps": PS_OK, "nettop": NETTOP_LOCAL,
                    "nettop_seconds": host_env.NETTOP_WINDOW_S, **overrides}

    def run(self, argv, timeout=host_env.COMMAND_TIMEOUT_S, stdin=None):
        self.calls.append((argv, timeout))
        tool = Path(argv[0]).name
        if tool == "pmset":
            text = self.out["therm"] if argv[1:] == ["-g", "therm"] else self.out["pmset"]
        elif tool == "sysctl":
            if argv[-1] == "vm.loadavg":
                loads = self.out["loadavg"]
                text = loads.pop(0) if len(loads) > 1 else loads[0]
            else:
                text = SYSCTL.get(argv[-1])
        elif tool == "sw_vers":
            text = SW_VERS.get(argv[-1])
        elif tool == "nettop":
            self.clock.now += min(self.out["nettop_seconds"], timeout)
            text = self.out["nettop"]
        else:
            text = self.out[{"vm_stat": "vm_stat", "mdutil": "mdutil", "scutil": "scutil", "ps": "ps"}[tool]]
        return None if text is None else host_env.CommandResult(text, 0)


def run(vdisplay=VDISPLAY_120, pids=(APP_PID, DAEMON_PID), **overrides):
    clock = FakeClock()
    commands = FakeCommands(clock, **overrides)
    report = host_env.validate(commands=commands, clock=clock, bench_user=BENCH, vdisplay_text=vdisplay,
                               egress_pids=pids)
    return report, commands, clock


class ValidHost(unittest.TestCase):
    def test_a_quiet_120hz_host_is_valid(self):
        report, _, _ = run()
        self.assertTrue(report["ok"], report["reasons"])
        self.assertEqual(report["reasons"], [])
        self.assertEqual(report["hz"], 120)
        self.assertNotIn("refusal", report)
        self.assertRegex(report["fingerprint"], r"^[0-9a-f]{64}$")
        self.assertEqual(report["class"], "apple-m4-pro/24gb/120hz")

    def test_60hz_is_keyed_not_refused(self):
        report, _, _ = run(vdisplay=VDISPLAY_60)
        self.assertTrue(report["ok"], report["reasons"])
        self.assertEqual(report["hz"], 60)
        self.assertEqual(report["class"], "apple-m4-pro/24gb/60hz")

    def test_probe_main_line_is_read(self):
        report, _, _ = run(vdisplay="main 1 8.4\n")
        self.assertEqual(report["hz"], 120)


class EachFailingCheckHasItsOwnReason(unittest.TestCase):
    CASES = {
        "thermal-limit": dict(therm=THERM_THROTTLED),
        "system-sleep": dict(pmset=PMSET_OK.replace(" sleep                0", " sleep                10")),
        "low-power-mode": dict(pmset=PMSET_OK.replace("lowpowermode         0", "lowpowermode         1")),
        "load-high": dict(loadavg=[LOADAVG_HIGH]),
        "memory-low": dict(vm_stat=VM_STAT_LOW),
        "spotlight-on": dict(mdutil=MDUTIL_ON),
        "no-gui-session": dict(scutil=SCUTIL_LOGINWINDOW),
        "other-cmux-app": dict(ps=PS_OTHER),
        "network-egress": dict(nettop=NETTOP_EGRESS),
    }

    def test_each_case_yields_exactly_its_reason(self):
        for code, overrides in self.CASES.items():
            with self.subTest(code):
                report, _, _ = run(**overrides)
                self.assertFalse(report["ok"])
                self.assertEqual(report["reasons"], [code])
                self.assertEqual(report["refusal"], "env-invalid")
                self.assertTrue(report["details"][code])

    def test_another_console_user_is_no_gui_session(self):
        report, _, _ = run(scutil=SCUTIL_BENCH.replace("Name : bench", "Name : ec2-user"))
        self.assertEqual(report["reasons"], ["no-gui-session"])
        self.assertIn("ec2-user", report["details"]["no-gui-session"])

    def test_all_failures_are_reported_together(self):
        overrides = {k: v for case in self.CASES.values() for k, v in case.items() if k != "pmset"}
        report, _, _ = run(**overrides)
        self.assertEqual(sorted(report["reasons"]),
                         sorted(code for code in self.CASES if code not in ("system-sleep", "low-power-mode")))

    def test_vdisplay_not_ready(self):
        for text in ("", "error: CGVirtualDisplay failed\n", "ready 7 0 main=7\n"):
            with self.subTest(text):
                report, _, _ = run(vdisplay=text)
                self.assertEqual(report["reasons"], ["vdisplay-not-ready"])
                self.assertIsNone(report["fingerprint"])

    def test_slower_than_60hz_refuses(self):
        report, _, _ = run(vdisplay="ready 7 33.3 main=7\n")
        self.assertEqual(report["reasons"], ["refresh-below-60"])

    def test_egress_of_an_unwatched_process_is_ignored(self):
        report, _, _ = run(nettop=NETTOP_OTHER_PROCESS)
        self.assertTrue(report["ok"], report["reasons"])

    def test_unreadable_probes_fail_closed(self):
        cases = {"thermal-unreadable": dict(therm=None), "memory-unreadable": dict(vm_stat=None),
                 "spotlight-unreadable": dict(mdutil="something else\n"),
                 "other-cmux-app-unreadable": dict(ps=None), "network-egress-unreadable": dict(nettop=None),
                 "load-unreadable": dict(loadavg=[None])}
        for code, overrides in cases.items():
            with self.subTest(code):
                report, _, _ = run(**overrides)
                self.assertEqual(report["reasons"], [code])

    def test_scutil_with_no_answer_is_no_gui_session(self):
        report, _, _ = run(scutil=None)
        self.assertEqual(report["reasons"], ["no-gui-session"])

    def test_missing_pmset_rows_fail_closed(self):
        report, _, _ = run(pmset="System-wide power settings:\n")
        self.assertEqual(report["reasons"], ["system-sleep-unreadable", "low-power-mode-unreadable"])


class BoundedWaits(unittest.TestCase):
    def test_load_wait_is_bounded_to_30s(self):
        report, _, clock = run(loadavg=[LOADAVG_HIGH])
        self.assertEqual(report["reasons"], ["load-high"])
        load_wait = sum(clock.slept)
        self.assertLessEqual(load_wait, host_env.LOAD_WAIT_S)
        self.assertGreaterEqual(load_wait, host_env.LOAD_WAIT_S - host_env.LOAD_POLL_S)

    def test_load_that_drops_within_30s_passes(self):
        report, _, clock = run(loadavg=[LOADAVG_HIGH, LOADAVG_HIGH, LOADAVG_OK])
        self.assertTrue(report["ok"], report["reasons"])
        self.assertEqual(clock.slept, [host_env.LOAD_POLL_S, host_env.LOAD_POLL_S])

    def test_nettop_watches_one_60s_window_with_a_bounded_timeout(self):
        report, commands, _ = run()
        nettop = [(argv, timeout) for argv, timeout in commands.calls if argv[0].endswith("nettop")]
        self.assertEqual(len(nettop), 1)
        argv, timeout = nettop[0]
        self.assertEqual(argv[argv.index("-L") + 1], "60")
        self.assertEqual(argv.count("-p"), 2)
        self.assertLessEqual(timeout, host_env.NETTOP_WINDOW_S + host_env.NETTOP_GRACE_S)
        self.assertTrue(report["facts"]["egress_checked"])

    def test_a_short_nettop_window_is_not_a_pass(self):
        report, _, _ = run(nettop_seconds=5)
        self.assertEqual(report["reasons"], ["network-egress-unreadable"])

    def test_no_pids_skips_nettop(self):
        # Before the job launches its app (no pids yet), any running cmux app is another one.
        report, commands, clock = run(pids=(), ps="    1 /sbin/launchd\n")
        self.assertTrue(report["ok"], report["reasons"])
        self.assertFalse(report["facts"]["egress_checked"])
        self.assertFalse(any(argv[0].endswith("nettop") for argv, _ in commands.calls))
        self.assertEqual(clock.now, 1000.0)


class Fingerprint(unittest.TestCase):
    def test_stable_and_sensitive_to_each_input(self):
        base = host_env.fingerprint("Apple M4 Pro", "25B78", 120, 24 * 2**30)
        self.assertEqual(base, host_env.fingerprint("Apple M4 Pro", "25B78", 120, 24 * 2**30))
        self.assertEqual(base, run()[0]["fingerprint"])
        for changed in (("Apple M4", "25B78", 120, 24 * 2**30), ("Apple M4 Pro", "25C56", 120, 24 * 2**30),
                        ("Apple M4 Pro", "25B78", 60, 24 * 2**30), ("Apple M4 Pro", "25B78", 120, 16 * 2**30)):
            self.assertNotEqual(base, host_env.fingerprint(*changed))

    def test_class_excludes_the_macos_build(self):
        first = host_env.host_class("Apple M4 Pro", 24 * 2**30, 120)
        self.assertEqual(first, "apple-m4-pro/24gb/120hz")
        self.assertNotIn("25B78", first)

    def test_matches_bench_launch_host_record(self):
        bench_launch = load("bench_launch_under_test", ROOT / "scripts" / "cmux-next" / "bench_launch.py")
        record = bench_launch.host_record("Apple M4 Pro", 24 * 2**30, "26.1", "25B78", 120)
        report = run()[0]
        self.assertEqual(record["fingerprint"], report["fingerprint"])
        self.assertEqual(record["class"], report["class"])


class Parsers(unittest.TestCase):
    def test_nettop_endpoints(self):
        self.assertEqual(host_env.remote_host("17.57.146.20:443"), "17.57.146.20")
        self.assertEqual(host_env.remote_host("fe80::1%en0.5223"), "fe80::1")
        self.assertEqual(host_env.remote_host("::1.41001"), "::1")
        self.assertIsNone(host_env.remote_host("*:*"))

    def test_ipv6_egress_is_found(self):
        text = NETTOP_LOCAL + "12:00:02.0,tcp6 2001:db8::5.50300<->2606:4700::1.443,en0,Established,0,0,\n"
        self.assertEqual(len(host_env.parse_egress(text, {DAEMON_PID})), 1)
        self.assertEqual(host_env.parse_egress(text, {APP_PID}), [])

    def test_cmux_apps_skip_nested_helpers_and_daemons(self):
        self.assertEqual([pid for pid, _ in host_env.parse_cmux_apps(PS_OTHER)], [APP_PID, 900])


if __name__ == "__main__":
    unittest.main()
