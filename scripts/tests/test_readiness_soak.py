"""readiness-soak.py counts only its own app copy's crash reports.

The soak runs on capture minis, where other tagged builds crash into the same
~/Library/Logs/DiagnosticReports (the 2026-10-11 cua-2 soak failed on 9 reports, none of them
its app's). A report is the soak's when its header names the copy's bundle ID or its process is
one the soak saw (the app, its daemon, acpmux).
"""

import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).parents[2]

# The soak reads macOS process stats (libproc) at import; its helpers are not under test.
for name, attrs in {
    "bench_idle": ("Client", "process_table", "usage"),
    "daemon_teardown": ("daemon_status", "request", "terminal_hosts"),
    "tag_teardown": ("TagTeardown",),
}.items():
    sys.modules.setdefault(name, types.SimpleNamespace(**{attr: None for attr in attrs}))
SPEC = importlib.util.spec_from_file_location("readiness_soak", ROOT / "scripts" / "cmux-next" / "readiness-soak.py")
soak_module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(soak_module)

SOAK_BUNDLE = "com.cmuxterm.app.debug.soak"


def write_report(directory, name, header, pid, mtime, parent=1, body=None):
    path = os.path.join(directory, name)
    with open(path, "w") as handle:
        handle.write(json.dumps(header) + "\n")
        handle.write(body if body is not None else json.dumps(
            {"pid": pid, "parentPid": parent, "procPath": "/Users/USER/*/x", "threads": []}))
    os.utime(path, (mtime, mtime))
    return path


class CrashReportTests(unittest.TestCase):
    def test_counts_only_the_soak_copys_reports(self):
        with tempfile.TemporaryDirectory() as home:
            reports = os.path.join(home, "Library", "Logs", "DiagnosticReports")
            os.makedirs(reports)
            started = 1_800_000_000
            after = started + 60
            # Another lane's tagged build on the same capture mini.
            write_report(reports, "cmux DEV-2026-10-11-035305.ips",
                         {"bundleID": "com.cmuxterm.app.debug.hcomb.capslot1", "app_name": "cmux DEV"}, 81950, after)
            # A report from before the soak, rewritten after it started.
            write_report(reports, "cmux DEV-2026-10-10-183016.ips",
                         {"bundleID": "com.cmuxterm.app.debug.sweep5.capslot2", "app_name": "cmux DEV"}, 91891, after)
            # Another copy's acpmux.
            write_report(reports, "acpmux-2026-10-11-090000.ips", {"app_name": "acpmux"}, 999, after)
            ours_app = write_report(reports, "cmux DEV-2026-10-11-120000.ips",
                                    {"bundleID": SOAK_BUNDLE, "app_name": "cmux DEV"}, 56604, after)
            ours_daemon = write_report(reports, "cmux-tui-2026-10-11-130000.ips", {"app_name": "cmux-tui"}, 56650, after)
            # One of the soak's terminal hosts (a cmux-tui process the soak saw).
            ours_host = write_report(reports, "cmux-tui-2026-10-11-140000.ips", {"app_name": "cmux-tui"}, 56700, after)
            # A helper the app started and that crashed before any sample saw it.
            ours_helper = write_report(reports, "cmux DEV Helper-2026-10-11-150000.ips",
                                       {"bundleID": "com.cmuxterm.app.debug.soak.helper"}, 60001, after, parent=56604)
            # This copy's report whose body is not JSON: the header alone says whose it is.
            ours_header_only = write_report(reports, "cmux DEV-2026-10-11-160000.ips", {"bundleID": SOAK_BUNDLE},
                                            0, after, body="not json")
            # This copy's report from an earlier run.
            write_report(reports, "cmux DEV-2026-10-09-120000.ips", {"bundleID": SOAK_BUNDLE}, 100, started - 3600)

            soak = soak_module.Soak.__new__(soak_module.Soak)
            soak.started = started
            soak.bundle_id = SOAK_BUNDLE
            soak.seen_pids = {56604, 56650, 56700}
            soak.app_pid = 56604
            with mock.patch.dict(os.environ, {"HOME": home}):
                self.assertEqual(soak.crash_reports(), sorted([ours_app, ours_daemon, ours_host, ours_helper, ours_header_only]))


class FakeClient:
    """bench_idle.Client's wire behavior (one JSON line each way) without its macOS imports."""

    def __init__(self, path, timeout=10.0):
        import socket
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buffer = b""

    def call(self, method, params=None, timeout=None):
        self.sock.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(1 << 16)
            if not chunk:
                raise ConnectionError("socket closed")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)


class FakeControlSocket:
    """A Unix socket that answers each request line with `reply`, sent in two halves `delay` seconds apart,
    or holds it when `reply` is None."""

    def __init__(self, path, reply, delay=0):
        import socket
        import threading
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(8)
        self.reply, self.delay, self.held = reply, delay, []
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            if self.reply is None:
                self.held.append(connection)  # never answers: a slow app
                continue
            buffer = b""
            while b"\n" not in buffer:
                chunk = connection.recv(1 << 16)
                if not chunk:
                    break
                buffer += chunk
            if b"\n" not in buffer:
                connection.close()  # the client hung up without a request
                continue
            # In two halves, `delay` before each: every recv beats the client's timeout, the reply does not.
            line = (json.dumps(self.reply) + "\n").encode()
            for part in (line[:len(line) // 2], line[len(line) // 2:]):
                time.sleep(self.delay)
                connection.sendall(part)
            connection.close()

    def close(self):
        self.server.close()
        for connection in self.held:
            connection.close()


class ControlRoundTripTests(unittest.TestCase):
    """A control round trip that fails at once is an error, with its text; only a slow one is a hang.

    The 2026-10-12 and 2026-10-13 soaks on one capture mini logged ~1100 "hang" events each, 0.1 ms apiece:
    the socket file had been deleted at ~11:00Z (ENOENT), and the report said hang without the error."""

    def soak(self, path, hang_after=0.3):
        soak = soak_module.Soak.__new__(soak_module.Soak)
        soak.socket = path
        soak.events = []
        soak.args = types.SimpleNamespace(hang_after=hang_after)
        return soak

    def kinds(self, soak):
        return [event["kind"] for event in soak.events]

    def test_missing_socket_is_a_control_error_with_its_message(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(soak_module, "Client", FakeClient):
            soak = self.soak(os.path.join(directory, "gone.sock"))
            soak.check_control()
            self.assertEqual(self.kinds(soak), ["control-error"])
            self.assertIn("control error:", soak.events[0]["detail"])
            self.assertIn("No such file or directory", soak.events[0]["detail"])

    def test_error_reply_is_a_control_error_with_the_reply(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(soak_module, "Client", FakeClient):
            path = os.path.join(directory, "app.sock")
            server = FakeControlSocket(path, {"id": 1, "error": {"code": "denied", "message": "not authorized"}})
            try:
                soak = self.soak(path)
                soak.check_control()
            finally:
                server.close()
            self.assertEqual(self.kinds(soak), ["control-error"])
            self.assertIn("not authorized", soak.events[0]["detail"])

    def test_a_reply_slower_than_hang_after_is_a_hang(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(soak_module, "Client", FakeClient):
            path = os.path.join(directory, "app.sock")
            server = FakeControlSocket(path, None)
            try:
                soak = self.soak(path, hang_after=0.2)
                soak.check_control()
            finally:
                server.close()
            self.assertEqual(self.kinds(soak), ["hang"])
            self.assertIn("slow", soak.events[0]["detail"])

    def test_a_good_reply_after_hang_after_is_a_hang(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(soak_module, "Client", FakeClient):
            path = os.path.join(directory, "app.sock")
            server = FakeControlSocket(path, {"id": 1, "ok": True, "result": {}}, delay=0.25)
            try:
                soak = self.soak(path, hang_after=0.4)
                soak.check_control()
            finally:
                server.close()
            self.assertEqual(self.kinds(soak), ["hang"])
            self.assertIn("reply after", soak.events[0]["detail"])

    def test_a_slow_reply_still_counts_when_the_other_call_failed(self):
        class PingFails(FakeClient):
            def call(self, method, params=None):
                if method == "system.ping":
                    self.sock.close()  # the fake server answers one connection at a time
                    raise ConnectionRefusedError(61, "Connection refused")
                return super().call(method, params)

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(soak_module, "Client", PingFails):
            path = os.path.join(directory, "app.sock")
            server = FakeControlSocket(path, {"id": 1, "ok": True, "result": {}}, delay=0.25)
            try:
                soak = self.soak(path, hang_after=0.4)
                soak.check_control()
            finally:
                server.close()
            self.assertEqual(self.kinds(soak), ["control-error", "hang"])
            self.assertIn("snapshot.get: reply after", soak.events[1]["detail"])

    def test_a_good_reply_records_nothing(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(soak_module, "Client", FakeClient):
            path = os.path.join(directory, "app.sock")
            server = FakeControlSocket(path, {"id": 1, "ok": True, "result": {}})
            try:
                soak = self.soak(path)
                ping_ms, snapshot_ms = soak.check_control()
            finally:
                server.close()
            self.assertEqual(soak.events, [])
            self.assertLess(max(ping_ms, snapshot_ms), 300)


class WebKitMatcherTests(unittest.TestCase):
    """WebKit processes count only when the app is responsible for them (the 2026-10-14 end spike: two iOS
    simulators booted on the soak mini, and their 12 WebKit processes counted as the app's)."""

    def test_counts_only_webkit_processes_the_app_is_responsible_for(self):
        app_pid = 90859
        table = [
            (app_pid, 1, "/private/var/folders/x/cmux-soak-1/cmux NEXT DEV.app/Contents/MacOS/cmux"),
            (90938, 1, "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"),
            (90940, 1, "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"),
            (7530, 65614, "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/com.apple.WebKit.WebContent"),
            (1390, 1, "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"),
        ]
        responsible = {app_pid: app_pid, 90938: app_pid, 90940: app_pid, 7530: 2239, 1390: 1154}
        soak = soak_module.Soak.__new__(soak_module.Soak)
        soak.setup, soak.app_exit = {"identity": {"pid": app_pid}}, None
        soak.app = "/private/var/folders/x/cmux-soak-1/cmux NEXT DEV.app"
        soak.work = "/private/var/folders/x/cmux-soak-1"
        soak.tag = "next-soak1"
        soak.webkit_before = set()
        with mock.patch.object(soak_module, "process_table", lambda: table), \
                mock.patch.object(soak_module, "terminal_hosts", lambda daemon, tag: []), \
                mock.patch.object(soak_module, "responsible_pid", responsible.get, create=True):
            found = soak.kinds()
        self.assertEqual({pid for pid, kind in found.items() if kind == "webkit"}, {90938, 90940})

    def test_without_the_responsibility_call_webkit_started_after_the_app_counts(self):
        soak = soak_module.Soak.__new__(soak_module.Soak)
        soak.webkit_before = {1390}
        with mock.patch.object(soak_module, "responsible_pid", lambda pid: None):
            self.assertTrue(soak.owns_webkit(90938, 90859))
            self.assertFalse(soak.owns_webkit(1390, 90859))
        with mock.patch.object(soak_module, "responsible_pid", lambda pid: -1):
            self.assertFalse(soak.owns_webkit(90938, 90859), "a pid the call has no answer for is not the app's")


ASAN_REPORT = """=================================================================
==4242==ERROR: AddressSanitizer: heap-use-after-free on address 0x602000000010 at pc 0x0001 bp 0x0002 sp 0x0003
READ of size 8 at 0x602000000010 thread T0
    #0 0x0001 in CmuxNextApp.Workspace.close() Workspace.swift:42
SUMMARY: AddressSanitizer: heap-use-after-free Workspace.swift:42 in CmuxNextApp.Workspace.close()
==4242==ABORTING
"""
TSAN_REPORT = """==================
WARNING: ThreadSanitizer: data race (pid=5151)
  Write of size 8 at 0x7b0400000000 by thread T3:
    #0 CmuxNextControl.Router.route() Router.swift:10
SUMMARY: ThreadSanitizer: data race Router.swift:10 in CmuxNextControl.Router.route()
==================
"""


def report_soak(args=None, setup=None, events=None, zombies=None, out=None):
    """A Soak whose report() runs on the given state, with no app: no samples file, a full-length run."""
    soak = soak_module.Soak.__new__(soak_module.Soak)
    defaults = dict(app_config=None, stress=False, zombie_gate="warn", warmup=0, settle=0, idle=0, hours=0,
                    max_growth_mb=300, max_growth_percent=25, max_fd_growth=100, max_app_cpu=10, max_daemon_cpu=5,
                    max_idle_app_cpu=1, max_idle_daemon_cpu=0.5, max_idle_acpmux_cpu=0.5, idle_cpu_gate="warn",
                    terminals=0, browsers=0, agents=0)
    soak.args = types.SimpleNamespace(**{**defaults, **(args or {})})
    if out is None:
        soak.scratch = tempfile.TemporaryDirectory()  # removed with the soak
        out = soak.scratch.name
    soak.out = out
    soak.samples = None
    soak.setup = {"terminals": 0, "browsers": 0, "agents": 0, **(setup or {})}
    soak.events = events or []
    soak.zombies = zombies or {}
    soak.sanitizer_count = sum(1 for e in soak.events if e.get("sanitizer"))
    soak.app = "/tmp/app"
    return soak


class SanitizerReportTests(unittest.TestCase):
    """--app-config asan|tsan: each sanitizer report in the log_path folder or app.log is a crash event."""

    def test_headers_name_tool_kind_and_pid(self):
        reports = soak_module.sanitizer_reports("noise\n" + ASAN_REPORT + "more\n" + TSAN_REPORT)
        self.assertEqual(reports, [{"tool": "AddressSanitizer", "what": "heap-use-after-free", "pid": 4242},
                                   {"tool": "ThreadSanitizer", "what": "data race", "pid": 5151}])

    def test_summary_lines_and_plain_warnings_are_not_reports(self):
        text = "SUMMARY: AddressSanitizer: heap-use-after-free x\nWARNING: something else\n==1==ABORTING\n"
        self.assertEqual(soak_module.sanitizer_reports(text), [])

    def test_a_new_report_is_a_crash_event_once(self):
        with tempfile.TemporaryDirectory() as out:
            folder = os.path.join(out, "sanitizer")
            os.makedirs(folder)
            app_log = os.path.join(out, "app.log")
            with open(app_log, "w") as handle:
                handle.write(TSAN_REPORT)  # an earlier run's log: not this run's
            soak = report_soak(args={"app_config": "asan"}, out=out)
            soak.sanitizer = soak_module.SanitizerLogs(folder, [app_log])
            soak.check_sanitizer()
            self.assertEqual(soak.events, [])
            log = os.path.join(folder, "asan.cmux.4242")
            with open(log, "w") as handle:
                handle.write(ASAN_REPORT[:120])  # still being written: no full header line yet
            soak.check_sanitizer()
            self.assertEqual(soak.events, [])
            with open(log, "a") as handle:
                handle.write(ASAN_REPORT[120:])
            soak.check_sanitizer()
            soak.check_sanitizer()
            self.assertEqual([e["kind"] for e in soak.events], ["crash"])
            self.assertIn("AddressSanitizer report: heap-use-after-free (pid 4242, asan.cmux.4242)", soak.events[0]["detail"])
            with open(app_log, "a") as handle:  # a helper without log_path writes to stderr
                handle.write(TSAN_REPORT)
            soak.check_sanitizer()
            self.assertEqual(soak.sanitizer_count, 2)
            result = soak.report()
            self.assertFalse(result["ok"])
            self.assertIn("2 crash event(s)", result["failures"])
            self.assertEqual(result["sanitizer"], {"mode": "asan", "logs": None, "reports": 2})

    def test_options_keep_the_callers_and_set_the_log_path(self):
        env = soak_module.sanitizer_env("asan", "/out/sanitizer", {"ASAN_OPTIONS": "detect_leaks=1"})
        self.assertEqual(env, {"ASAN_OPTIONS": "detect_leaks=1:log_path='/out/sanitizer/asan':log_exe_name=1"})
        self.assertTrue(soak_module.sanitizer_env("tsan", "/o", {})["TSAN_OPTIONS"].startswith("log_path='/o/tsan':"))

    def test_a_path_with_a_space_comma_or_colon_stays_one_value(self):
        # compiler-rt's parser ends a bare value at a space, comma or colon (sanitizer_flag_parser.cpp is_space).
        folder = "/Users/a/Library/Application Support/x,y:z/sanitizer"
        with mock.patch.object(soak_module, "TSAN_SUPPRESSIONS", "/checkout two/tsan-suppressions.txt"), \
                mock.patch.object(soak_module.os.path, "exists", lambda path: True):
            options = soak_module.sanitizer_env("tsan", folder, {})["TSAN_OPTIONS"]
        self.assertEqual(options, f"log_path='{folder}/tsan':log_exe_name=1:"
                                  "suppressions='/checkout two/tsan-suppressions.txt'")
        self.assertEqual(soak_module.sanitizer_path_value("/it's"), '"/it\'s"')
        with self.assertRaisesRegex(SystemExit, "both quote characters"):
            soak_module.sanitizer_path_value("/it's \"x\"")

    def test_each_run_logs_to_an_empty_folder_of_its_own(self):
        with tempfile.TemporaryDirectory() as out:
            soak = report_soak(args={"app_config": "asan"}, out=out)
            soak.begin()
            first = soak.sanitizer_dir
            soak.samples.close()
            # An earlier run's report under the name a new process may get again (<mode>.<exe>.<pid>).
            with open(os.path.join(first, "asan.cmux.4242"), "w") as handle:
                handle.write(ASAN_REPORT)
            soak.begin()
            soak.samples.close()
            self.assertNotEqual(soak.sanitizer_dir, first)
            self.assertEqual(os.path.dirname(soak.sanitizer_dir), os.path.join(out, "sanitizer"))
            self.assertEqual(os.listdir(soak.sanitizer_dir), [])
            self.assertEqual(soak.setup["sanitizer_logs"], soak.sanitizer_dir)
            # This run's log, already longer than a poll would have seen, is read from its start.
            with open(os.path.join(soak.sanitizer_dir, "asan.cmux.4242"), "w") as handle:
                handle.write("noise\n" * 50 + ASAN_REPORT)
            soak.check_sanitizer()
            self.assertEqual(soak.sanitizer_count, 1)

    def test_a_report_written_at_quit_counts(self):
        with tempfile.TemporaryDirectory() as out:
            soak = report_soak(args={"app_config": "asan"}, out=out)
            folder = os.path.join(out, "sanitizer")
            os.makedirs(folder)
            soak.sanitizer = soak_module.SanitizerLogs(folder, [os.path.join(out, "app.log")])
            soak.check_sanitizer()  # the loop's last poll: nothing yet

            def quit():  # the app's exit: LeakSanitizer reports only now
                with open(os.path.join(folder, "asan.cmux.4242"), "w") as handle:
                    handle.write("==4242==ERROR: LeakSanitizer: detected memory leaks\n")
            soak.quit = quit
            soak.finish()
            result = soak.report()
            self.assertEqual(result["sanitizer"]["reports"], 1)
            self.assertIn("1 crash event(s)", result["failures"])
            self.assertIn("LeakSanitizer report: detected memory leaks", soak.events[0]["detail"])

    def test_app_config_must_match_the_builds_runtime(self):
        with tempfile.TemporaryDirectory() as app:
            os.makedirs(os.path.join(app, "Contents/Frameworks"))
            soak = report_soak(args={"app_config": "asan"})
            soak.app = app
            with self.assertRaisesRegex(SystemExit, "not a asan build"):
                soak.identify()
            open(os.path.join(app, "Contents/Frameworks", soak_module.SANITIZER_RUNTIMES["tsan"]), "w").close()
            soak.args.app_config = None
            with self.assertRaisesRegex(SystemExit, "run it with --app-config tsan"):
                soak.identify()


class ChromiumOffTests(unittest.TestCase):
    VMMAP = """Process:         cmux [4242]

MALLOC ZONE                                    SIZE       SIZE       SIZE       SIZE      COUNT  ALLOCATED  FRAG SIZE  % FRAG   COUNT
===========                                 =======  =========  =========  =========  =========  =========  =========  ======  ======
DefaultMallocZone_0x100f2c000                 30.0M      12.1M      12.1M         0K     100000      10.0M       2.1M     18%       5
PartitionAlloc_0x10a000000                    50.0M      40.0M      40.0M         0K          0         0K         0K      0%       0
===========                                 =======  =========  =========  =========  =========  =========  =========  ======  ======
TOTAL                                         80.0M      52.1M      52.1M         0K     100000      10.0M       2.1M     18%       5
"""

    def test_vmmap_zone_names(self):
        self.assertEqual(soak_module.malloc_zones(self.VMMAP), ["DefaultMallocZone", "PartitionAlloc"])

    def test_partition_alloc_makes_the_run_invalid(self):
        soak = report_soak(args={"app_config": "asan"})
        soak.chromium_off, soak.app_pid = True, 4242
        listed = types.SimpleNamespace(returncode=0, stdout=self.VMMAP)
        with mock.patch.object(soak_module, "run", lambda *argv, **kw: listed):
            soak.check_chromium_off({4242: "app"})
        self.assertEqual([e["kind"] for e in soak.events], ["chromium-loaded"])
        self.assertTrue(any(f.startswith("invalid asan run: Chromium loaded") for f in soak.report()["failures"]))

    def test_system_zone_only_passes(self):
        soak = report_soak(args={"app_config": "asan"})
        soak.chromium_off, soak.app_pid = True, 4242
        listed = types.SimpleNamespace(returncode=0, stdout=self.VMMAP.replace("PartitionAlloc_0x10a000000", "QuartzCore_0x1"))
        with mock.patch.object(soak_module, "run", lambda *argv, **kw: listed):
            soak.check_chromium_off({4242: "app"})
        self.assertEqual(soak.events, [])
        self.assertEqual(soak.report()["failures"], [])

    def test_a_failed_read_keeps_the_last_good_zones(self):
        # An ASan finding aborts the app, so the read after the loop fails: setup still has the zones read live.
        soak = report_soak(args={"app_config": "asan"})
        soak.chromium_off, soak.app_pid = True, 4242
        good = types.SimpleNamespace(returncode=0, stdout=self.VMMAP.replace("PartitionAlloc_0x10a000000", "QuartzCore_0x1"))
        with mock.patch.object(soak_module, "run", lambda *argv, **kw: good):
            soak.check_chromium_off({4242: "app"})
        read_at = soak.setup["malloc_zones_at"]
        with mock.patch.object(soak_module, "run", lambda *argv, **kw: types.SimpleNamespace(returncode=1, stdout="")):
            soak.check_chromium_off({})
        self.assertEqual(soak.setup["malloc_zones"], ["DefaultMallocZone", "QuartzCore"])
        self.assertEqual(soak.setup["malloc_zones_at"], read_at)
        self.assertIn("malloc_zones_failed_at", soak.setup)
        result = soak.report()
        self.assertEqual((result["failures"], result["warnings"]), ([], []))

    def test_zones_never_read_is_a_warning(self):
        soak = report_soak(args={"app_config": "asan"})
        soak.chromium_off, soak.app_pid = True, 4242
        with mock.patch.object(soak_module, "run", lambda *argv, **kw: types.SimpleNamespace(returncode=1, stdout="")):
            soak.check_chromium_off({4242: "app"})
        self.assertNotIn("malloc_zones", soak.setup)
        self.assertTrue(any("Chromium off is not proven" in w for w in soak.report()["warnings"]))

    def wiring_soak(self, app_config):
        soak = report_soak(args={"app_config": app_config})
        soak.chromium_off = bool(app_config)
        soak.config = os.path.join(soak.out, "cmux.json")
        return soak

    def test_config_turns_chromium_off_only_with_app_config(self):
        # The bench defaults (bench_env: the updater off) under the soak's own keys, as BenchApp writes them.
        bench_defaults = {"updates": {"checkAutomatically": False}}
        soak = self.wiring_soak("asan")
        soak.write_config("keep")
        with open(soak.config) as handle:
            self.assertEqual(json.load(handle), {"app": {"quitBehavior": "keep"}, "browser": {"defaultEngine": "webkit"},
                                                 **bench_defaults})
        soak = self.wiring_soak(None)
        soak.write_config("end-everything")
        with open(soak.config) as handle:
            self.assertEqual(json.load(handle), {"app": {"quitBehavior": "end-everything"}, **bench_defaults})

    def test_browser_tabs_are_webkit_only_with_app_config(self):
        class Control:
            def __init__(self):
                self.asked = []

            def action(self, name, timeout=None, **kw):
                self.asked.append(name)
                return {"ok": True}

        for app_config, engine in (("tsan", "openBrowser.webkit"), (None, "openBrowser.chromium")):
            soak = self.wiring_soak(app_config)
            soak.args.browsers, soak.work = 3, soak.out
            soak.control = Control()
            if app_config:
                soak.begin()
                soak.samples.close()
            soak.start_browsers()
            self.assertEqual(soak.control.asked, [engine] * 3, app_config)
            self.assertEqual(soak.setup["browsers"], 3)

    def test_quiet_phase_stops_every_busy_stress_terminal(self):
        sent = []
        soak = report_soak()
        soak.stress = types.SimpleNamespace(busy=["t1", "t2", "t3"], send=lambda tab, text: sent.append((tab, text)))
        soak.quiet_stress()
        self.assertEqual(sent, [("t1", "\x03"), ("t2", "\x03"), ("t3", "\x03")])
        soak.stress = None
        soak.quiet_stress()  # no --stress: nothing to stop


class ZombieTests(unittest.TestCase):
    """A child of this copy's processes left in state Z for a whole sample interval is a zombie, counted per hour."""

    PS = "  100     1 Ss\n  201   100 Z\n  202   100 Z+\n  203   900 Z\n  204   100 S\n  300   150 Z\n"

    def test_zombies_of_the_copys_processes_only(self):
        self.assertEqual(soak_module.zombies_in(self.PS, {100: "app", 150: "webkit"}), [(201, 100), (202, 100), (300, 150)])

    def test_counted_after_two_samples_and_reported_per_hour(self):
        soak = report_soak()
        soak.zombies_last = set()
        kinds = {100: "app", 150: "webkit"}
        with mock.patch.object(soak_module, "run", lambda *argv, **kw: types.SimpleNamespace(stdout=self.PS)):
            self.assertEqual(soak.check_zombies(kinds, 100), 0, "a child exiting this tick may be reaped by the next")
            self.assertEqual(soak.check_zombies(kinds, 4000), 2)
            self.assertEqual(soak.check_zombies(kinds, 8000), 2)
        self.assertEqual(sorted(soak.zombies), [201, 202], "a WebKit process's children are not this copy's")
        samples = [{"elapsed_s": 9000, "zombies": 2}]
        summary = soak.zombie_summary(samples)
        self.assertEqual(summary, {"total": 2, "per_hour": [0, 2, 0], "by_parent_kind": {"app": 2}, "at_end": 2})
        result = soak.report()
        self.assertEqual(result["zombies"]["total"], 2)
        self.assertTrue(any("2 zombie children" in w for w in result["warnings"]))
        soak.args.zombie_gate = "fail"
        self.assertTrue(any("2 zombie children" in f for f in soak.report()["failures"]))


class StressTests(unittest.TestCase):
    def test_chromium_pages_become_webkit_with_chromium_off(self):
        asked = []

        class Base:
            made = {}

            def add_tab(self, workspace_id, pane_id, kind):
                asked.append(kind)
                self.made.setdefault(pane_id, []).append((kind, f"tab-{len(asked)}", False))

            def size_window(self):
                raise ShapeError("display too small")

        class ShapeError(RuntimeError):
            pass

        module = types.SimpleNamespace(Stress=Base, StressShapeError=ShapeError)
        off = soak_module.soak_stress(module, chromium_off=True)()
        for kind in ("terminal", "chromium", "webkit", "chat"):
            off.add_tab("w", "p", kind)
        soak_module.soak_stress(module, chromium_off=False)().add_tab("w", "p", "chromium")
        self.assertEqual(asked, ["terminal", "webkit", "webkit", "chat", "chromium"])
        # STRESS's pane mix counts what was asked: the WebKit page stands for a Chromium one.
        self.assertEqual([kind for kind, _, _ in off.made["p"]], ["terminal", "chromium", "webkit", "chat", "chromium"])
        self.assertEqual(off.made["p"][1], ("chromium", "tab-2", False))
        self.assertEqual(off.size_window(), {})
        self.assertEqual(off.window_note, "display too small")

    def test_the_real_stress_module_loads_and_has_the_hooks(self):
        module = soak_module.load_stress()
        for name in ("add_tab", "size_window", "build", "send", "close"):
            self.assertTrue(callable(getattr(module.Stress, name)), name)
        self.assertTrue(issubclass(module.StressShapeError, RuntimeError))

    STRESS = {"workspaces": 60, "measured_panes": 14, "shown_columns": 4, "measured_tabs": {"terminal": 28, "browser": 42,
              "conversation": 14}, "busy_terminals": 10, "background_chromium": [2] * 10, "build_s": 1.0,
              # debug.cef with Chromium off: never ready.
              "chromium_unavailable": ["Chromium state unavailable, not ready"]}

    def stress_setup(self, summary, chromium_off):
        module = soak_module.load_stress()

        class Built(module.Stress):
            window_note = None

            def build(self, check=True):
                return summary
        fake = types.SimpleNamespace(Stress=Built, StressShapeError=module.StressShapeError, socket_rpc=lambda path: None)
        soak = report_soak(args={"stress": True, "app_config": "asan" if chromium_off else None})
        soak.chromium_off, soak.socket = chromium_off, "/tmp/none.sock"
        with mock.patch.object(soak_module, "load_stress", lambda: fake), \
                mock.patch.object(soak_module, "soak_stress", lambda module, off: module.Stress):
            soak.start_stress()
        return soak

    def test_stress_shape_holds_with_chromium_off(self):
        self.assertNotIn("stress_shape", self.stress_setup(self.STRESS, chromium_off=True).setup)
        on = self.stress_setup(self.STRESS, chromium_off=False)
        self.assertIn("Chromium is not available", on.setup["stress_shape"])

    def test_a_short_stress_is_a_shape_warning_with_chromium_off(self):
        soak = self.stress_setup(dict(self.STRESS, workspaces=59), chromium_off=True)
        self.assertIn("59 workspaces, not 60", soak.setup["stress_shape"])
        self.assertNotIn("Chromium is not available", soak.setup["stress_shape"])
        self.assertTrue(any(w.startswith("STRESS shape:") for w in soak.report()["warnings"]))

    def test_stress_not_built_fails_the_run(self):
        soak = report_soak(args={"stress": True}, setup={"stress": "not built: display too small"})
        self.assertIn("setup: STRESS not built: display too small", soak.report()["failures"])


if __name__ == "__main__":
    unittest.main()
