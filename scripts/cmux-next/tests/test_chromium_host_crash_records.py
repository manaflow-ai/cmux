#!/usr/bin/env python3
"""chromium_host_crash_records.py, chromium-host-bench.py's --kill-host row (p01-process-085), against a fake
`debug.crashes`: a SIGTRAPped host's record with its signal, fork API and a log tail without URLs passes; no record,
another host's record, another signal, no fork API, an empty log tail or a URL left in the tail fails. The row's run
against a fake app: it signals the supervisor's host once the probe loaded, and does not run off the host backend.
The bench's --kill-host and --signal flags parse, with host tabs on in its tunables.
Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_crash_records.py"""
import importlib.util, io, os, signal, sys, types, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_crash_records as crash_records  # noqa: E402

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


class FakeApp:
    """`debug.cef`, `action.run` and `debug.crashes` of an app whose supervisor runs `host`; a signal to it leaves a
    record (`listed`), as the supervisor does."""

    def __init__(self, backend="host", host=HOST, loads=True):
        self.backend, self.host, self.loads = backend, host, loads
        self.calls, self.sent, self.listed = [], [], []

    def rpc(self, method, params=None, timeout=None):
        self.calls.append(method)
        if method == "debug.cef":
            return {"backend": self.backend, "host_supervisor": {"pid": self.host} if self.host else {}}
        if method == "action.run":
            return {"ok": True}
        if method == "debug.crashes":
            return {"chromium": [], "chromium_host": self.listed}
        raise AssertionError(method)

    def page_eval(self, script):
        return self.loads

    def send(self, pid, number):
        self.sent.append((pid, number))
        self.listed.append(record(pid=pid, signal=number))


def drive(app, number=int(signal.SIGTRAP)):
    def wait(predicate, timeout, interval):
        return predicate()

    return crash_records.run(app.rpc, wait, app.page_eval, "file:///probe.html", number, send=app.send)


class KillHostRunTests(unittest.TestCase):
    def test_the_supervisors_host_is_signalled_and_its_record_passes(self):
        app = FakeApp()
        result, ran = drive(app)
        self.assertTrue(ran)
        self.assertTrue(result["pass"], result)
        self.assertEqual(app.sent, [(HOST, int(signal.SIGTRAP))])
        self.assertEqual(result["host_pid"], HOST)

    def test_off_the_host_backend_nothing_runs(self):
        app = FakeApp(backend="inProcess")
        result, ran = drive(app)
        self.assertFalse(ran)
        self.assertIn("not_run", result)
        self.assertEqual(app.sent, [])
        self.assertNotIn("action.run", app.calls)

    def test_a_probe_that_never_loads_sends_no_signal(self):
        app = FakeApp(loads=False)
        result, ran = drive(app)
        self.assertFalse(ran)
        self.assertEqual(app.sent, [])

    def test_no_supervisor_host_sends_no_signal(self):
        app = FakeApp(host=None)
        result, ran = drive(app)
        self.assertFalse(ran)
        self.assertEqual(app.sent, [])

    def test_signal_names(self):
        self.assertEqual(crash_records.signal_number("TRAP"), int(signal.SIGTRAP))
        self.assertEqual(crash_records.signal_number("sigsegv"), int(signal.SIGSEGV))
        with self.assertRaises(ValueError):
            crash_records.signal_number("HUP")


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
    def test_kill_host_parses_its_signal_and_turns_host_tabs_on(self):
        bench = load_bench()
        args = bench.parse(["--app", "/x/cmux DEV t.app", "--out", "/x/out", "--kill-host"])
        self.assertTrue(args.kill_host)
        self.assertEqual(args.signal, int(signal.SIGTRAP))
        args = bench.parse(["--app", "/x/cmux DEV t.app", "--out", "/x/out", "--kill-host", "--signal", "SEGV"])
        self.assertEqual(args.signal, int(signal.SIGSEGV))
        self.assertTrue(bench.launch_tunables(["inproc", "helper"], kill_host=True)["values"]["browserHost.tabs"])
        self.assertFalse(bench.launch_tunables(["inproc", "helper"])["values"]["browserHost.tabs"])

    def test_kill_host_runs_alone_and_takes_only_its_signals(self):
        bench = load_bench()
        for extra in (["--find"], ["--native-ui"], ["--signal", "HUP"]):
            with self.assertRaises(SystemExit), mock.patch("sys.stderr", io.StringIO()):
                bench.parse(["--app", "/x/cmux DEV t.app", "--out", "/x/out", "--kill-host", *extra])


if __name__ == "__main__":
    unittest.main()
