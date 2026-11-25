#!/usr/bin/env python3
"""idle_cpu.py's Chromium trace of the app at idle (--cef-trace): Chromium's own startup trace, a ring buffer of capped
size kept in a folder removed after, read into tasks per second for each process and thread and the place that posted
them. It names what makes Chrome_IOThread ask the main thread for work about once a second (task 21, step 7289b85b).
Run: python3 -I scripts/cmux-next/tests/test_idle_cpu_cef_trace.py (not a CI job)."""
import ctypes, os, sys, unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
if sys.platform == "darwin":
    import idle_cpu  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import idle_cpu  # noqa: E402

S = 1_000_000  # trace timestamps are microseconds


def task(ts_s, func, file="a/b.cc", tid=1, pid=10, style="src"):
    args = ({"src_func": func, "src_file": file} if style == "src"
            else {"task": {"posted_from": {"function_name": func, "file_name": file}}})
    return {"ph": "X", "name": "ThreadControllerImpl::RunTask", "ts": ts_s * S, "dur": 5, "pid": pid, "tid": tid,
            "args": args}


META = [{"ph": "M", "name": "process_name", "pid": 10, "args": {"name": "Browser"}},
        {"ph": "M", "name": "thread_name", "pid": 10, "tid": 1, "args": {"name": "CrBrowserMain"}},
        {"ph": "M", "name": "thread_name", "pid": 10, "tid": 2, "args": {"name": "Chrome_IOThread"}}]


class CefTraceSwitches(unittest.TestCase):
    def test_a_capped_ring_buffer_into_the_given_file(self):
        got = idle_cpu.cef_trace_switches("/tmp/t/cef-trace.json", 150).split(":")
        self.assertIn("trace-startup-file=/tmp/t/cef-trace.json", got)
        self.assertIn("trace-startup-duration=150", got)
        self.assertIn("trace-startup-record-mode=record-continuously", got)   # keeps the idle tail, not the startup
        self.assertIn(f"trace-buffer-size-in-kb={idle_cpu.CEF_TRACE_BUFFER_KB}", got)
        self.assertIn("trace-startup-format=json", got)
        self.assertTrue(any(s.startswith("trace-startup=") and "toplevel" in s for s in got))

    def test_joined_with_the_bench_switches(self):
        self.assertEqual(idle_cpu.join_switches("disable-component-update", "x=1"), "disable-component-update:x=1")
        self.assertEqual(idle_cpu.join_switches("none", "x=1"), "x=1")
        self.assertEqual(idle_cpu.join_switches("a", ""), "a")

    def test_a_path_with_a_colon_is_refused(self):
        with self.assertRaises(ValueError):
            idle_cpu.cef_trace_switches("/tmp/a:b/t.json", 150)

    def test_the_option_is_bounded(self):
        self.assertEqual(idle_cpu.parse_args(["--app", "/x.app", "--cef-trace", "150"]).cef_trace, 150)
        for bad in ("10", "601", "-1"):
            with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
                idle_cpu.check_args(idle_cpu.parse_args(["--app", "/x.app", "--cef-trace", bad]))


class CefTraceTasks(unittest.TestCase):
    def test_tasks_per_second_after_the_startup_busiest_first(self):
        events = META + [task(0, "Startup")] * 50 + [task(t, "OnTimer", tid=1) for t in range(30, 130)] \
            + [task(t, "OnIpc", tid=2, style="task") for t in range(30, 130, 2)] + [task(130, "End")]
        got = idle_cpu.cef_trace_tasks({"traceEvents": events}, skip_s=30)
        self.assertEqual(got["seconds"], 100.0)
        rows = got["tasks"]
        self.assertEqual((rows[0]["process"], rows[0]["thread"], rows[0]["posted_from"], rows[0]["per_s"]),
                         ("Browser", "CrBrowserMain", "OnTimer (a/b.cc)", 1.0))
        self.assertEqual((rows[1]["thread"], rows[1]["posted_from"], rows[1]["per_s"]),
                         ("Chrome_IOThread", "OnIpc (a/b.cc)", 0.5))
        self.assertNotIn("Startup (a/b.cc)", [r["posted_from"] for r in rows], "startup tasks are skipped")

    def test_ipc_messages_on_the_browser_threads_by_name(self):
        # The main thread's wakes from Chrome_IOThread (task 21, ~0.9/s) are IPC messages the I/O thread forwards; the
        # mojom category names each one. RunTask rows say only "Accept (ipc_mojo_bootstrap.cc)".
        def ev(ts_s, name, tid, ph="X"):
            return {"ph": ph, "name": name, "ts": ts_s * S, "dur": 3, "pid": 10, "tid": tid, "args": {}}
        events = META + [task(0, "Startup")] \
            + [ev(t, "Receive blink.mojom.LocalFrameHost::UpdateState", 1) for t in range(30, 130)] \
            + [ev(t, "Send cef.mojom.RenderFrame::SendMessage", 2, ph="i") for t in range(30, 130, 4)] \
            + [ev(t, "ThreadControllerImpl::RunTask", 1) for t in range(30, 130)] \
            + [{"ph": "X", "name": "Other", "ts": 50 * S, "dur": 1, "pid": 11, "tid": 1, "args": {}}, task(130, "End")]
        rows = idle_cpu.cef_trace_tasks({"traceEvents": events}, skip_s=30)["events"]
        self.assertEqual([(r["thread"], r["name"], r["per_s"]) for r in rows],
                         [("CrBrowserMain", "Receive blink.mojom.LocalFrameHost::UpdateState", 1.0),
                          ("Chrome_IOThread", "Send cef.mojom.RenderFrame::SendMessage", 0.25)])

    def test_a_bare_event_list_and_no_tasks(self):
        self.assertEqual(idle_cpu.cef_trace_tasks(META, skip_s=30)["tasks"], [])

    def test_a_file_is_read_and_removed(self):
        import json, tempfile
        folder = tempfile.mkdtemp(prefix="cef-trace-test-")
        path = os.path.join(folder, "cef-trace.json")
        with open(path, "w") as handle:
            json.dump({"traceEvents": META + [task(t, "OnTimer") for t in range(0, 61)]}, handle)
        got = idle_cpu.read_cef_trace(folder, skip_s=0)
        self.assertEqual(got["tasks"][0]["per_s"], 1.02)
        self.assertFalse(os.path.exists(folder), "the folder is removed")

    def test_a_missing_file_is_an_error_not_a_raise(self):
        import tempfile
        folder = tempfile.mkdtemp(prefix="cef-trace-test-")
        self.assertIn("error", idle_cpu.read_cef_trace(folder, skip_s=0))
        self.assertFalse(os.path.exists(folder))


if __name__ == "__main__":
    unittest.main()
