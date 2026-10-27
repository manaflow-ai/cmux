#!/usr/bin/env python3
"""chromium_host_crash_records.py, the crash record check of chromium-host-bench.py's --kill-host rows
(p01-process-085), against a fake `debug.crashes`: a SIGTRAPped host's record with its signal, fork API and a log
tail without URLs passes; no record, another host's record, another signal, no fork API, an empty log tail or a URL
left in the tail fails. The kill rows (chromium_host_kill.py) against a fake app carry it per signal: a row passes
with its host's record and fails without it. The bench's --kill-host and --signals flags parse, with host tabs on in
its tunables.
Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_crash_records.py"""
import importlib.util, io, os, signal, sys, types, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_crash_records as crash_records  # noqa: E402
import chromium_host_kill as kill  # noqa: E402

HOST = 4242


def record(**fields):
    base = {"kind": "chromium-host", "pid": HOST, "signal": int(signal.SIGTRAP), "signal_name": "SIGTRAP", "reason": "crashed",
            "said_hello": True, "fork_api": 30, "cef_version": "154.0.0",
            "log_tail": ["[INFO] line 1", "[FATAL] navigating to <url> from <url>"]}
    base.update(fields)
    return base


def run(listed, number=int(signal.SIGTRAP)):
    """The row against a `debug.crashes` that lists `listed` (None: a reply without `chromium_host`)."""
    def rpc(method, params=None, timeout=None):
        assert method == "debug.crashes", method
        return {"chromium": []} if listed is None else {"chromium": [], "chromium_host": listed}

    def wait(predicate, timeout, interval):
        return predicate()

    return crash_records.row(rpc, wait, HOST, number)


class CrashRecordRowTests(unittest.TestCase):
    def test_a_trapped_hosts_record_passes(self):
        result = run([record()])
        self.assertTrue(result["pass"], result)
        self.assertEqual(result["signal_name"], "SIGTRAP")
        self.assertEqual(result["log_tail_lines"], 2)
        self.assertEqual(result["urls"], 0)

    def test_no_record_fails(self):
        self.assertEqual(run(None), {"crash_record": False, "pass": False})
        self.assertFalse(run([])["pass"])

    def test_another_hosts_record_does_not_count(self):
        self.assertFalse(run([record(pid=HOST + 1)])["crash_record"])

    def test_the_newest_record_of_the_host_counts(self):
        result = run([record(signal=int(signal.SIGKILL)), record()])
        self.assertTrue(result["pass"], result)

    def test_another_signal_fails(self):
        self.assertFalse(run([record()], number=int(signal.SIGSEGV))["pass"])

    def test_a_record_without_the_fork_api_fails(self):
        self.assertFalse(run([record(fork_api=None)])["pass"])

    def test_a_url_left_in_the_tail_fails(self):
        for line in ["GET https://bank.example/x", "src=data:text/html,hi", "javascript:alert(1)", "chrome-extension://a/b"]:
            result = run([record(log_tail=[line])])
            self.assertEqual(result["urls"], 1, line)
            self.assertFalse(result["pass"], line)

    def test_chromium_log_prefixes_are_not_urls(self):
        tail = ["[1027/120000.123456:ERROR:gpu_process_host.cc(990)] GPU process exited", "metadata: 3 at 12:30:01"]
        self.assertEqual(crash_records.urls_in(tail), [])

    def test_more_than_20_lines_fails(self):
        self.assertFalse(run([record(log_tail=[f"line {n}" for n in range(21)])])["pass"])

    def test_an_empty_log_tail_fails(self):
        # The host writes its start line after CefInitialize, so a host that said hello has at least that line.
        result = run([record(log_tail=[])])
        self.assertEqual(result["log_tail_lines"], 0)
        self.assertFalse(result["pass"])


GONE_TEXT = "Aw, Snap!\nChromium stopped while it showed this page. Reload starts Chromium again.\nReload"


class FakeApp:
    """The app as the kill rows see it: a supervisor host (`HOST`) that a signal ends, a crash page whose Reload
    starts a new host, and `debug.crashes` that lists each end (`records` False: the supervisor records none)."""

    def __init__(self, records=True):
        self.records = records
        self.host, self.gone, self.next_host = HOST, False, HOST + 1
        self.sent, self.listed = [], []

    def rpc(self, method, params=None, timeout=None):
        params = params or {}
        if method == "debug.cef":
            return {"backend": "host", "host_supervisor": {"pid": self.host}}
        if method == "action.run":
            return {"ok": True}
        if method == "browser.page.eval":
            return {"tab": "t1", "value": None if self.gone else True}
        if method == "debug.browser.page_status":
            if params.get("press") == "reload":
                if not self.gone:
                    return {"pressed": "0"}
                self.gone, self.host, self.next_host = False, self.next_host, self.next_host + 1
                return {"pressed": "1"}
            return {"gone": "1" if self.gone else "0", "gone_text": GONE_TEXT if self.gone else ""}
        if method == "debug.crashes":
            return {"chromium": [], "chromium_host": self.listed}
        raise AssertionError(method)

    def send(self, pid, number):
        self.sent.append((pid, int(number)))
        if self.records:
            self.listed.append(record(pid=pid, signal=int(number)))
        self.gone, self.host = True, None


def drive(app, signals="TRAP"):
    def wait(predicate, timeout, interval):
        return predicate() or None

    return kill.run(app.rpc, wait, "file:///kill-host.html", kill.signal_numbers(signals), lambda: app.host, 7,
                    lambda pid: pid == 7, send=app.send,
                    record=lambda host, number: crash_records.row(app.rpc, wait, host, number))


class KillHostRowTests(unittest.TestCase):
    def test_the_trapped_hosts_row_carries_its_record_and_passes(self):
        app = FakeApp()
        rows, ok = drive(app)
        self.assertTrue(ok, rows)
        self.assertEqual(app.sent, [(HOST, int(signal.SIGTRAP))])
        self.assertTrue(rows["TRAP"]["crash_record"]["pass"], rows)
        self.assertEqual(rows["TRAP"]["crash_record"]["signal"], int(signal.SIGTRAP))

    def test_every_signal_row_checks_its_own_hosts_record(self):
        rows, ok = drive(FakeApp(), "TRAP,SEGV")
        self.assertTrue(ok, rows)
        self.assertEqual(rows["SEGV"]["host_pid"], HOST + 1)
        self.assertEqual(rows["SEGV"]["crash_record"]["signal"], int(signal.SIGSEGV))

    def test_a_host_end_without_a_record_fails_the_row(self):
        rows, ok = drive(FakeApp(records=False))
        self.assertFalse(ok)
        self.assertFalse(rows["TRAP"]["crash_record"]["crash_record"])
        self.assertTrue(rows["TRAP"]["crash_page"], rows)


def load_bench():
    """chromium-host-bench.py as a module. bench_power loads libproc at import (macOS only); the parse never calls
    it, so a stand-in module takes its place."""
    stand_in = types.ModuleType("bench_power")
    with mock.patch.dict(sys.modules, {"bench_power": sys.modules.get("bench_power", stand_in)}):
        spec = importlib.util.spec_from_file_location("chromium_host_bench_085", os.path.join(HERE, "..", "chromium-host-bench.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


class BenchFlagTests(unittest.TestCase):
    def test_kill_host_parses_its_signals_and_turns_host_tabs_on(self):
        bench = load_bench()
        args = bench.parse(["--app", "/x/cmux DEV t.app", "--out", "/x/out", "--kill-host", "--signals", "TRAP"])
        self.assertTrue(args.kill_host)
        self.assertEqual(args.signals, [("TRAP", signal.SIGTRAP)])
        args = bench.parse(["--app", "/x/cmux DEV t.app", "--out", "/x/out", "--kill-host", "--signals", "TRAP,SEGV"])
        self.assertEqual([number for _, number in args.signals], [signal.SIGTRAP, signal.SIGSEGV])
        self.assertTrue(bench.launch_tunables(["inproc", "helper"], kill_host=True)["values"]["browserHost.tabs"])
        self.assertFalse(bench.launch_tunables(["inproc", "helper"])["values"]["browserHost.tabs"])

    def test_kill_host_runs_alone_and_takes_only_its_signals(self):
        bench = load_bench()
        for extra in (["--find"], ["--native-ui"], ["--signals", "HUP"]):
            with self.assertRaises(SystemExit), mock.patch("sys.stderr", io.StringIO()):
                bench.parse(["--app", "/x/cmux DEV t.app", "--out", "/x/out", "--kill-host", *extra])

    def test_the_supervisors_host_pid_comes_first(self):
        bench = load_bench()
        self.assertEqual(bench.supervisor_host_pid(lambda method: {"host_supervisor": {"pid": 4242.0}}), 4242)


if __name__ == "__main__":
    unittest.main()
