#!/usr/bin/env python3
"""extension_timers.py and cef-idle-probe.py --extension-timers (p14-energy-108): an extension's background timers by
owner over a window. A recorded CDP message stream (uBlock Origin 1.75's idle owners) gives fires by callback, arms by
the stack that armed them and alarms by name, each pause resumed; the background target is the MV2 page before an MV3
service worker, of this extension only; cdp.Session.receive reads a frame that arrives in pieces whole and times out
only before a frame begins. Runs anywhere (no app, no Chromium).
Run: python3 -I scripts/cmux-next/tests/test_extension_timers.py"""
import importlib.util, io, json, os, socket, subprocess, sys, threading, unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
sys.path.insert(0, ROOT)
import extension_timers  # noqa: E402
from ext_e2e import cdp  # noqa: E402

spec = importlib.util.spec_from_file_location("cef_idle_probe", os.path.join(ROOT, "cef-idle-probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

UBO = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
ORIGIN = f"chrome-extension://{UBO}/"


def frame(script, line, function):
    return {"functionName": function, "url": "", "location": {"scriptId": script, "lineNumber": line - 1}}


def paused(event, *frames):
    return {"method": "Debugger.paused",
            "params": {"reason": "EventListener", "data": {"eventName": f"instrumentation:{event}"}, "callFrames": list(frames)}}


def parsed(script, path):
    return {"method": "Debugger.scriptParsed", "params": {"scriptId": script, "url": ORIGIN + path}}


def alarm(name):
    return {"method": "Runtime.consoleAPICalled",
            "params": {"type": "debug", "args": [{"type": "string", "value": extension_timers.ALARM_MARK},
                                                 {"type": "string", "value": name}]}}


TIMER_FIRE = paused("setTimeout.callback", frame("1", 58, ""))
GC_ARM = paused("setTimeout", frame("1", 57, "on"), frame("2", 448, "gc"), frame("1", 59, ""), frame("3", 1, "deeper"))


class FakeSession:
    """Answers each command with an empty result after the events queued for it; then plays `stream`."""

    def __init__(self, stream=(), on_command=None):
        self.stream, self.on_command = list(stream), on_command or {}
        self.inbox, self.sent, self.closed, self.next_id = [], [], False, 1

    def send(self, method, params=None):
        request_id = self.next_id
        self.next_id += 1
        self.sent.append((method, params))
        reply = self.on_command.get(method)
        self.inbox += reply(params) if callable(reply) else (reply or [])
        if method == "Runtime.evaluate" and "getAll" in (params or {}).get("expression", ""):
            self.inbox.append({"id": request_id, "result": {"result": {"value": [{"name": "assetUpdater",
                                                                               "period_min": None, "due_s": 3440}]}}})
        else:
            self.inbox.append({"id": request_id, "result": {}})
        return request_id

    def receive(self, timeout):
        if self.inbox:
            return self.inbox.pop(0)
        if self.stream:
            return self.stream.pop(0)
        return None

    def close(self):
        self.closed = True


class Clock:
    """Each read moves 1 s; run_until stops once the stream is drained and time passes the deadline."""

    def __init__(self):
        self.now = 0.0

    def __call__(self):
        self.now += 1.0
        return self.now


def started(stream):
    """A started profile on a FakeSession; scriptParsed arrives before Debugger.enable's answer, as Chromium sends it."""
    session = FakeSession(stream, {"Debugger.enable": [parsed("1", "js/vapi-common.js"), parsed("2", "js/traffic.js")]})
    profile = extension_timers.ExtensionTimerProfile(session, UBO, clock=Clock())
    profile.start()
    return profile, session


class ProfileTests(unittest.TestCase):
    def test_fires_arms_and_alarms_are_counted_by_owner_and_each_pause_resumed(self):
        stream = [TIMER_FIRE, GC_ARM] * 4 + [TIMER_FIRE, alarm("assetUpdater")]
        profile, session = started(stream)
        profile.run_until(len(stream) * 2 + 50)
        profile.stop()
        report = profile.report(120.0)
        rows = {(r["kind"], r["event"], r["where"]): r["count"] for r in report["rows"]}
        self.assertEqual(rows, {
            ("fire", "setTimeout", "js/vapi-common.js:58 (anonymous)"): 5,
            ("arm", "setTimeout", "js/vapi-common.js:57 on < js/traffic.js:448 gc < js/vapi-common.js:59 (anonymous)"): 4,
            ("fire", "alarm", "assetUpdater"): 1,
        })
        self.assertEqual(report["fires_per_s"], round(6 / 120, 4))
        self.assertEqual(report["arms_per_s"], round(4 / 120, 4))
        self.assertEqual(report["alarms"], [{"name": "assetUpdater", "period_min": None, "due_s": 3440}])
        self.assertEqual(report["unwatched"], [])
        resumes = [m for m, _ in session.sent if m == "Debugger.resume"]
        self.assertEqual(len(resumes), 9)
        self.assertTrue(session.closed)

    def test_every_timer_and_its_callback_is_watched_and_removed_at_stop(self):
        profile, session = started([])
        profile.stop()
        set_names = [p["eventName"] for m, p in session.sent if m == "EventBreakpoints.setInstrumentationBreakpoint"]
        removed = [p["eventName"] for m, p in session.sent if m == "EventBreakpoints.removeInstrumentationBreakpoint"]
        expected = [f"{t}{s}" for t in extension_timers.TIMERS for s in ("", ".callback")]
        self.assertEqual(set_names, expected)
        self.assertEqual(removed, expected)
        self.assertIn("Debugger.disable", [m for m, _ in session.sent])

    def test_a_build_without_event_breakpoints_falls_back_to_domdebugger_and_lists_what_neither_has(self):
        session = FakeSession()
        original = session.send

        def send(method, params=None):
            if method == "EventBreakpoints.setInstrumentationBreakpoint" or (
                    method == "DOMDebugger.setInstrumentationBreakpoint" and params["eventName"].startswith("requestIdle")):
                request_id = session.next_id
                session.next_id += 1
                session.sent.append((method, params))
                session.inbox.append({"id": request_id, "error": {"message": "not found"}})
                return request_id
            return original(method, params)
        session.send = send
        profile = extension_timers.ExtensionTimerProfile(session, UBO, clock=Clock())
        profile.start()
        report = profile.report(1.0)
        self.assertEqual(report["unwatched"], ["requestIdleCallback", "requestIdleCallback.callback"])
        self.assertEqual(profile.domains["setTimeout"], "DOMDebugger")

    def test_the_start_s_own_evaluations_are_not_counted(self):
        session = FakeSession(on_command={"Runtime.evaluate": [TIMER_FIRE]})
        profile = extension_timers.ExtensionTimerProfile(session, UBO, clock=Clock())
        profile.start()
        self.assertEqual(profile.report(1.0)["rows"], [])


class TargetTests(unittest.TestCase):
    def test_the_mv2_background_page_wins_and_other_extensions_are_ignored(self):
        targets = [
            {"type": "service_worker", "url": "chrome-extension://other/sw.js"},
            {"type": "background_page", "url": "chrome-extension://other/background.html"},
            {"type": "page", "url": ORIGIN + "dashboard.html"},
            {"type": "service_worker", "url": ORIGIN + "sw.js"},
            {"type": "background_page", "url": ORIGIN + "background.html"},
        ]
        self.assertEqual(extension_timers.background_target(targets, UBO)["url"], ORIGIN + "background.html")
        self.assertEqual(extension_timers.background_target(targets[:4], UBO)["url"], ORIGIN + "sw.js")
        self.assertIsNone(extension_timers.background_target(targets[:3], UBO))


def ws_frame(payload):
    data = json.dumps(payload).encode()
    return bytes([0x81, 126]) + len(data).to_bytes(2, "big") + data if len(data) >= 126 else bytes([0x81, len(data)]) + data


class ReceiveTests(unittest.TestCase):
    def session(self):
        a, b = socket.socketpair()
        session = cdp.Session.__new__(cdp.Session)
        session.sock, session.buffer, session.next_id = a, b"", 1
        return session, b

    def test_a_frame_that_arrives_in_pieces_is_read_whole(self):
        session, peer = self.session()
        message = {"method": "Debugger.paused", "params": {"pad": "x" * 300}}
        data = ws_frame(message)
        peer.sendall(data[:3])
        timer = threading.Timer(0.2, lambda: peer.sendall(data[3:]))
        timer.start()
        self.assertEqual(session.receive(1.0), message)
        timer.join()
        session.close()
        peer.close()

    def test_no_frame_within_the_timeout_is_none(self):
        session, peer = self.session()
        self.assertIsNone(session.receive(0.05))
        peer.sendall(ws_frame({"id": 1}))
        self.assertEqual(session.receive(1.0), {"id": 1})
        session.close()
        peer.close()


class ProbeTests(unittest.TestCase):
    def test_finish_prints_one_line_per_owner_and_the_totals(self):
        profile, _ = started([TIMER_FIRE, GC_ARM])
        profile.run_until(60)
        out = io.StringIO()
        with redirect_stdout(out):
            report = probe.finish_extension(profile, {"type": "background_page"}, 0.0)
        lines = out.getvalue().splitlines()
        self.assertEqual([line.split(" ", 1)[0] for line in lines], ["CEF-IDLE-EXT-TIMER"] * 2 + ["CEF-IDLE-EXT"])
        summary = json.loads(lines[-1].split(" ", 1)[1])
        self.assertEqual((summary["target"], summary["extension"]), ("background_page", UBO))
        self.assertNotIn("rows", summary)
        self.assertEqual(len(report["rows"]), 2)

    def run_probe(self, *args):
        return subprocess.run([sys.executable, "-I", os.path.join(ROOT, "cef-idle-probe.py"), *args],
                              capture_output=True, text=True, timeout=30)

    def options(self, **values):
        import argparse
        opts = argparse.Namespace(**{"queue": False, "trace": None, "window": None, "extension_timers": None, **values})
        return probe.extension_options(opts, argparse.ArgumentParser())

    def test_the_default_window_sees_the_30_s_owner_four_times_in_both_modes(self):
        self.assertEqual(self.options(extension_timers=UBO), (120.0, UBO))
        self.assertEqual(self.options(), (120.0, UBO))  # --cdp-port alone: the built-in uBlock Origin
        self.assertEqual(self.options(window=60.0, extension_timers="other"), (60.0, "other"))

    def test_a_window_too_short_for_the_owner_is_refused_before_the_app_launches(self):
        for args in (["--app", "/nonexistent.app", "--extension-timers"],
                     ["--cdp-port", "1", "--extension-timers", UBO]):
            result = self.run_probe(*args, "--window", "10")
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("--window >= 60", result.stderr)

    def test_the_profiler_never_shares_a_trace_or_queue_window(self):
        result = self.run_probe("--app", "/nonexistent.app", "--extension-timers", "--queue")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("--queue", result.stderr)
        result = self.run_probe("--trace", "/nonexistent.json", "--seconds", "100", "--extension-timers")
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_help_names_the_flags(self):
        out = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "cef-idle-probe.py"), "--help"],
                             capture_output=True, text=True, check=True).stdout
        self.assertIn("--extension-timers", out)
        self.assertIn("--cdp-port", out)


if __name__ == "__main__":
    unittest.main()
