#!/usr/bin/env python3
"""chromium_host_crash_records.py, the crash record half of chromium-host-bench.py's --kill-host rows
(p01-process-085), against a fake `debug.crashes`: a SIGTRAPped host's record with its signal, fork API and a log tail
without URLs passes; no record, another host's record, another signal, no fork API or a URL left in the tail fails.
Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_crash_records.py"""
import os, signal, sys, unittest

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


if __name__ == "__main__":
    unittest.main()
