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
        soak.setup = {"identity": {"pid": app_pid}}
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


if __name__ == "__main__":
    unittest.main()
