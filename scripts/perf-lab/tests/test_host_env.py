#!/usr/bin/env python3
"""host_env.py on canned probe outputs: one reason per failing check, a stable fingerprint, bounded waits.

  python3 -m unittest scripts/perf-lab/tests/test_host_env.py
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
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
THERM_INTEL_OK = THERM_THROTTLED.replace("= 78", "= 100") + "Note: No performance warning level has been recorded\n"
# Apple silicon throttling: a warning level is recorded and there is still no CPU power block.
THERM_AS_THERMAL = """Thermal_Level\t= 1
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
"""
THERM_AS_PERFORMANCE = """Note: No thermal warning level has been recorded
Performance Warning Level = 2
Note: No CPU power status has been recorded
"""
THERM_AS_LEVEL_ZERO = THERM_AS_THERMAL.replace("= 1", "= 0")
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
# A Mac with High Power Mode (M4 Pro Mac mini) prints `powermode` (0 automatic, 1 low, 2 high), no lowpowermode.
PMSET_POWERMODE = PMSET_OK.replace(" lowpowermode         0", " powermode            0")
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
PS_SAMPLER = PS_OK + " 950 /usr/bin/powermetrics\n"
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
    """Canned stdout per probe; `nettop` advances the fake clock by the window it watches. A probe named in `exit_1`
    ("therm", "pmset", "nettop", ...) prints its stdout and exits 1."""

    def __init__(self, clock, exit_1=(), **overrides):
        self.clock, self.calls, self.exit_1 = clock, [], frozenset(exit_1)
        self.out = {"therm": THERM_OK, "pmset": PMSET_OK, "loadavg": [LOADAVG_OK], "vm_stat": VM_STAT_OK,
                    "mdutil": MDUTIL_OFF, "scutil": SCUTIL_BENCH, "ps": PS_OK, "nettop": NETTOP_LOCAL,
                    "nettop_seconds": host_env.NETTOP_WINDOW_S, **overrides}

    def run(self, argv, timeout=host_env.COMMAND_TIMEOUT_S, stdin=None):
        self.calls.append((argv, timeout))
        tool = Path(argv[0]).name
        probe = tool
        if tool == "pmset":
            probe = "therm" if argv[1:] == ["-g", "therm"] else "pmset"
            text = self.out[probe]
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
        return None if text is None else host_env.CommandResult(text, 1 if probe in self.exit_1 else 0)


def run(vdisplay=VDISPLAY_120, pids=(APP_PID, DAEMON_PID), pre_launch=False, **overrides):
    clock = FakeClock()
    commands = FakeCommands(clock, **overrides)
    report = host_env.validate(commands=commands, clock=clock, bench_user=BENCH, vdisplay_text=vdisplay,
                               egress_pids=pids, pre_launch=pre_launch)
    return report, commands, clock


class ValidHost(unittest.TestCase):
    def test_a_quiet_120hz_host_is_valid(self):
        report, _, _ = run()
        self.assertTrue(report["ok"], report["reasons"])
        self.assertEqual(report["reasons"], [])
        self.assertEqual(report["hz"], 120)
        self.assertNotIn("refusal", report)
        self.assertEqual((report["mode"], report["checks_skipped"]), ("full", []))
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
        "network-egress-no-pids": dict(pids=(), ps="    1 /sbin/launchd\n"),
        "system-sleep": dict(pmset=PMSET_OK.replace(" sleep                0", " sleep                10")),
        "low-power-mode": dict(pmset=PMSET_OK.replace("lowpowermode         0", "lowpowermode         1")),
        "load-high": dict(loadavg=[LOADAVG_HIGH]),
        "memory-low": dict(vm_stat=VM_STAT_LOW),
        "spotlight-on": dict(mdutil=MDUTIL_ON),
        "no-gui-session": dict(scutil=SCUTIL_LOGINWINDOW),
        "other-cmux-app": dict(ps=PS_OTHER),
        "powermetrics-running": dict(ps=PS_SAMPLER),
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
        skipped = ("system-sleep", "low-power-mode", "network-egress-no-pids")
        overrides = {k: v for case in self.CASES.values() for k, v in case.items() if k not in ("pmset", "pids")}
        overrides["ps"] = PS_OTHER + PS_SAMPLER.removeprefix(PS_OK)
        report, _, _ = run(**overrides)
        self.assertEqual(sorted(report["reasons"]), sorted(code for code in self.CASES if code not in skipped))

    def test_apple_silicon_warning_levels_are_throttling(self):
        for text in (THERM_AS_THERMAL, THERM_AS_PERFORMANCE):
            with self.subTest(text):
                report, _, _ = run(therm=text)
                self.assertEqual(report["reasons"], ["thermal-limit"])
                self.assertEqual(report["facts"]["cpu_speed_limit"], 100)

    def test_unthrottled_therm_outputs_pass(self):
        for text in (THERM_OK, THERM_INTEL_OK, THERM_AS_LEVEL_ZERO):
            with self.subTest(text):
                report, _, _ = run(therm=text)
                self.assertTrue(report["ok"], report["reasons"])

    def test_therm_without_every_note_or_value_is_unreadable(self):
        for text in ("Note: No CPU power status has been recorded\n", "Thermal warning: unknown\n",
                     THERM_OK.replace("Note: No performance warning level has been recorded\n",
                                      "Error: No performance warning level with error code 0xe00002c2\n")):
            with self.subTest(text):
                report, _, _ = run(therm=text)
                self.assertEqual(report["reasons"], ["thermal-unreadable"])

    def test_powermode_row_is_read_when_there_is_no_lowpowermode(self):
        for value, reasons in (("0", []), ("2", []), ("1", ["low-power-mode"]), ("7", ["low-power-mode-unreadable"])):
            with self.subTest(value):
                pmset = PMSET_POWERMODE.replace("powermode            0", f"powermode            {value}")
                report, _, _ = run(pmset=pmset)
                self.assertEqual(report["reasons"], reasons)
                self.assertEqual(report["facts"]["powermode"], value)

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

    def test_a_probe_that_exits_non_zero_fails_closed(self):
        cases = {"thermal-unreadable": dict(therm=THERM_OK + "\tCPU_Speed_Limit \t= 100\n", exit_1={"therm"}),
                 "system-sleep-unreadable": dict(exit_1={"pmset"}), "memory-unreadable": dict(exit_1={"vm_stat"}),
                 "network-egress-unreadable": dict(exit_1={"nettop"})}
        for code, overrides in cases.items():
            with self.subTest(code):
                report, _, _ = run(**overrides)
                self.assertEqual(report["reasons"][0], code)
                self.assertFalse(report["ok"])

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
        self.assertIn("powermode", report["details"]["low-power-mode-unreadable"])


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
        self.assertNotIn("network-egress", report["checks_skipped"])

    def test_a_short_nettop_window_is_not_a_pass(self):
        report, _, _ = run(nettop_seconds=5)
        self.assertEqual(report["reasons"], ["network-egress-unreadable"])

    def test_pre_launch_skips_nettop_and_says_so(self):
        # Before the job launches its app (no pids yet), any running cmux app is another one.
        report, commands, clock = run(pids=(), pre_launch=True, ps="    1 /sbin/launchd\n")
        self.assertTrue(report["ok"], report["reasons"])
        self.assertEqual((report["mode"], report["checks_skipped"]), ("pre-launch", ["network-egress"]))
        self.assertFalse(any(argv[0].endswith("nettop") for argv, _ in commands.calls))
        self.assertEqual(clock.now, 1000.0)

    def test_no_pids_without_pre_launch_is_not_valid(self):
        report, commands, _ = run(pids=(), ps="    1 /sbin/launchd\n")
        self.assertFalse(report["ok"])
        self.assertEqual(report["reasons"], ["network-egress-no-pids"])
        self.assertEqual((report["mode"], report["checks_skipped"]), ("full", []))
        self.assertFalse(any(argv[0].endswith("nettop") for argv, _ in commands.calls))

    def test_the_cli_refuses_pre_launch_with_pids(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            host_env.main(["--pre-launch", "--pid", str(APP_PID)])


bench_launch = host_env.load_bench_launch()
perf_result = bench_launch.load_by_path("perf_result", ROOT / "scripts" / "perf-lab" / "perf_result.py")


class Fingerprint(unittest.TestCase):
    def test_stable_and_keyed_by_hz(self):
        base = run()[0]
        self.assertEqual(base["fingerprint"], run()[0]["fingerprint"])
        self.assertNotEqual(base["fingerprint"], run(vdisplay=VDISPLAY_60)[0]["fingerprint"])

    def test_class_excludes_the_macos_build(self):
        report = run()[0]
        self.assertEqual(report["class"], "apple-m4-pro/24gb/120hz")
        self.assertNotIn("25B78", report["class"])

    def test_the_host_block_is_bench_launch_host_record(self):
        record = bench_launch.host_record("Apple M4 Pro", 24 * 2**30, "26.1", "25B78", 120)
        report = run()[0]
        self.assertEqual(report["host"], record)
        self.assertEqual((report["fingerprint"], report["class"]), (record["fingerprint"], record["class"]))
        self.assertEqual(report["facts"]["memory_bytes"], 24 * 2**30)


class OneHzSource(unittest.TestCase):
    """A vdisplay made at 120 Hz that ticks at 16.7 ms: host_env and result-v1 both key the host at 60 Hz."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="host-env-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        nominal = bench_launch.main_display_hz
        bench_launch.main_display_hz = lambda: 120  # the CoreGraphics mode refresh: nominal, never read here
        self.addCleanup(setattr, bench_launch, "main_display_hz", nominal)

    def test_measured_60hz_is_recorded_in_result_v1(self):
        report = run(vdisplay=VDISPLAY_60)[0]
        path = os.path.join(self.tmp, "host.json")
        host_env.write_host_out(path, report)
        app = bench_launch.BenchApp(os.path.join(self.tmp, "cmux DEV host-env.app"), out=os.path.join(self.tmp, "out"),
                                    teardown=False, host=host_env.host_reader(path))
        self.addCleanup(shutil.rmtree, app.scratch, True)
        recorded = perf_result.Host.from_dict(app.read_host()).to_dict()
        self.assertEqual(recorded["display_hz"], 60)
        self.assertEqual(recorded["class"], report["class"])
        self.assertEqual(recorded["class"], "apple-m4-pro/24gb/60hz")
        self.assertEqual(recorded["fingerprint"], report["fingerprint"])

    def test_a_refused_host_leaves_no_host_block(self):
        path = os.path.join(self.tmp, "host.json")
        host_env.write_host_out(path, run()[0])
        with open(path, encoding="utf-8") as f:
            self.assertEqual(json.load(f)["display_hz"], 120)
        host_env.write_host_out(path, run(therm=THERM_THROTTLED)[0])
        self.assertFalse(os.path.exists(path))


class Parsers(unittest.TestCase):
    def test_nettop_endpoints(self):
        self.assertEqual(host_env.remote_host("17.57.146.20:443"), "17.57.146.20")
        self.assertEqual(host_env.remote_host("fe80::1%en0.5223"), "fe80::1")
        self.assertEqual(host_env.remote_host("::1.41001"), "::1")
        self.assertIsNone(host_env.remote_host("*:*"))

    def test_an_ipv6_flow_with_no_interface_keeps_its_owner(self):
        text = NETTOP_HEADER + f"""12:00:00.1,cmux-tui.{DAEMON_PID},,,0,0,
12:00:00.2,tcp6 2001:db8::5.50300<->2606:4700::1.443,,SynSent,0,0,
12:00:00.3,tcp4 192.168.1.20:50300<->17.57.146.20:443,en0,Established,0,10,
"""
        flows = host_env.parse_egress(text, {DAEMON_PID})
        self.assertEqual([pid for pid, _ in flows], [DAEMON_PID, DAEMON_PID])
        self.assertIn("2606:4700::1.443", flows[0][1])
        self.assertIn("17.57.146.20:443", flows[1][1])

    def test_an_unparsed_flow_of_a_watched_pid_is_egress(self):
        text = NETTOP_HEADER + f"12:00:00.1,cmux-tui.{DAEMON_PID},,,0,0,\n12:00:00.2,tcp4 something odd,en0,,0,0,\n"
        self.assertEqual(len(host_env.parse_egress(text, {DAEMON_PID})), 1)

    def test_ipv6_egress_is_found(self):
        text = NETTOP_LOCAL + "12:00:02.0,tcp6 2001:db8::5.50300<->2606:4700::1.443,en0,Established,0,0,\n"
        self.assertEqual(len(host_env.parse_egress(text, {DAEMON_PID})), 1)
        self.assertEqual(host_env.parse_egress(text, {APP_PID}), [])

    def test_powermetrics_is_found_by_its_executable_only(self):
        text = PS_SAMPLER + " 951 powermetrics\n 952 /tmp/powermetrics-notes/less\n 953 /usr/bin/powermetrics2\n"
        self.assertEqual(host_env.parse_powermetrics(text), [950, 951])

    def test_the_jobs_own_powermetrics_is_not_refused(self):
        report, _, _ = run(ps=PS_SAMPLER, pids=(APP_PID, DAEMON_PID, 950))
        self.assertNotIn("powermetrics-running", report["reasons"])

    def test_cmux_apps_skip_nested_helpers_and_daemons(self):
        self.assertEqual([pid for pid, _ in host_env.parse_cmux_apps(PS_OTHER)], [APP_PID, 900])


def pool_host(name="cmux17", hz_tail="120hz", refresh_ms=8.33, env_job="9d680ac2fd82628fdee6a038", **changes):
    host = {"name": name, "role": "waterfall", "class": "m6", "host_class": f"apple-m6/16gb/{hz_tail}", "shard": 0,
            "refresh_ms": refresh_ms, "env_job": env_job}
    host.update(changes)
    return host


class PoolRates(unittest.TestCase):
    """pool.json's measured rate per lab host (p12-perf-process-160): hz from the recorded interval, 60 unmeasured."""

    def test_a_host_that_held_8_33_ms_is_120hz(self):
        self.assertEqual(host_env.pool_hz(pool_host()), 120)
        self.assertEqual(host_env.pool_problems({"hosts": [pool_host()]}), [])

    def test_a_host_that_could_not_hold_8_33_ms_is_60hz(self):
        host = pool_host(hz_tail="60hz", refresh_ms=16.67)
        self.assertEqual(host_env.pool_hz(host), 60)
        self.assertEqual(host_env.pool_problems({"hosts": [host]}), [])

    def test_an_unmeasured_host_has_no_rate_and_keeps_its_nominal_class(self):
        host = pool_host(refresh_ms=None, env_job=None)
        self.assertIsNone(host_env.pool_hz(host))
        self.assertEqual(host_env.pool_problems({"hosts": [host]}), [])

    def test_a_60hz_measurement_cannot_keep_a_120hz_class(self):
        problems = host_env.pool_problems({"hosts": [pool_host(refresh_ms=16.67)]})
        self.assertEqual(len(problems), 1)
        self.assertIn("must end in /60hz (job 9d680ac2fd82628fdee6a038 measured 16.67 ms)", problems[0])

    def test_refresh_and_job_are_recorded_together(self):
        for host in (pool_host(env_job=None), pool_host(hz_tail="60hz", refresh_ms=None)):
            self.assertIn("recorded together", host_env.pool_problems({"hosts": [host]})[0])

    def test_bad_records_are_problems(self):
        cases = {"not a positive number": pool_host(refresh_ms=0), "not a controller job id": pool_host(env_job="x"),
                 "slower than 60 Hz": pool_host(refresh_ms=40.0)}
        for fragment, host in cases.items():
            with self.subTest(fragment):
                self.assertIn(fragment, host_env.pool_problems({"hosts": [host]})[0])
        self.assertEqual(host_env.pool_problems({}), ["no hosts list"])

    def test_the_checkout_pool_is_consistent(self):
        pool = json.loads((HERE.parent / "pool.json").read_text())
        self.assertEqual(host_env.pool_problems(pool), [])
        measured = [host for host in pool["hosts"] if host_env.pool_hz(host) is not None]
        self.assertTrue(measured, "task 160 recorded at least one host's measured refresh")


if __name__ == "__main__":
    unittest.main()
