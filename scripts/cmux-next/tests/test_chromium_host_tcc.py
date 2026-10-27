#!/usr/bin/env python3
"""chromium-host-bench.py's TCC attribution rows (chromium_host_tcc.py, task 089) judge the evidence right.

The rows pass only when tccd, locationd and nehelper charge a host page's requests to cmux's bundle id and main
executable, fail when the host executable, a helper or a bundle of their own is charged, and never pass on missing or
redacted evidence. Drives TccRows with a stand-in host page, log, window list and clock (no app, GUI or macOS).

    python3 scripts/cmux-next/tests/test_chromium_host_tcc.py
"""
from __future__ import annotations

import ast
import importlib.util
import json
import re
import sys
import unittest
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import chromium_host_tcc as tcc  # noqa: E402

BENCH = Path(__file__).resolve().parent.parent / "chromium-host-bench.py"

APP = "/Applications/cmux DEV t89.app"
BUNDLE = tcc.Bundle(path=APP, identifier="com.cmuxterm.app.debug.t89", display_name="cmux DEV t89",
                    executable=APP + "/Contents/MacOS/cmux DEV")
RELEASE = tcc.Bundle(path="/Applications/cmux.app", identifier="com.cmuxterm.app", display_name="cmux",
                     executable="/Applications/cmux.app/Contents/MacOS/cmux")
HOST = APP + "/Contents/MacOS/cmux DEV Chromium Host"
HELPER = APP + "/Contents/Frameworks/cmux DEV Helper.app/Contents/MacOS/cmux DEV Helper"


def tccd_lines(msg, service, subject=BUNDLE.identifier, responsible_id=BUNDLE.identifier,
               responsible_path=BUNDLE.executable, accessing=HELPER):
    return [
        f"AUTHREQ_ATTRIBUTION: msgID={msg}, attribution={{responsible={{TCCDProcess: identifier={responsible_id}, pid=501, "
        f"auid=501, euid=501, responsible_path={responsible_path}, binary_path={responsible_path}}}, "
        f"accessing={{TCCDProcess: identifier=com.cmuxterm.app.debug.t89.helper, pid=777, auid=501, euid=501, "
        f"binary_path={accessing}}}, requesting={{TCCDProcess: identifier=com.apple.appleh13camerad, pid=88, auid=0, "
        f"euid=0, binary_path=/usr/libexec/appleh13camerad}}, }},",
        f"AUTHREQ_CTX: msgID={msg}, function=TCCAccessRequest, service={service}, preflight=yes, query=1, client_dict=(null)",
        f"AUTHREQ_SUBJECT: msgID={msg}, subject={subject},",
        f"AUTHREQ_RESULT: msgID={msg}, authValue=0, authReason=2, authVersion=1, desired_auth=0, error=(null),",
    ]


class TccdTests(unittest.TestCase):
    def test_parses_one_request_per_msg_id(self):
        requests = tcc.tccd_requests(tccd_lines("12.1", "kTCCServiceCamera") + tccd_lines("12.2", "kTCCServiceMicrophone"))
        self.assertEqual(len(requests), 2)
        camera = next(r for r in requests if r["service"] == "kTCCServiceCamera")
        self.assertEqual(camera["subject"], BUNDLE.identifier)
        self.assertEqual(camera["responsible"]["responsible_path"], BUNDLE.executable)
        self.assertEqual(camera["accessing"]["binary_path"], HELPER)
        self.assertEqual(camera["auth_value"], 0)

    def test_cmux_charged_passes(self):
        verdict = tcc.judge_tcc(tcc.tccd_requests(tccd_lines("1.1", "kTCCServiceCamera")), "kTCCServiceCamera", BUNDLE)
        self.assertTrue(verdict["pass"], verdict)

    def test_host_as_its_own_responsible_process_fails(self):
        # The host started by LaunchServices (not cmux's child) is its own responsible process: same bundle id,
        # its own executable. The prompt then belongs to the host and the grant is not cmux's.
        lines = tccd_lines("1.1", "kTCCServiceCamera", responsible_path=HOST)
        verdict = tcc.judge_tcc(tcc.tccd_requests(lines), "kTCCServiceCamera", BUNDLE)
        self.assertFalse(verdict["pass"])
        self.assertIn("another identity", verdict["reason"])

    def test_host_bundle_of_its_own_fails(self):
        lines = tccd_lines("1.1", "kTCCServiceMicrophone", subject=BUNDLE.identifier + ".chromium-host",
                           responsible_id=BUNDLE.identifier + ".chromium-host",
                           responsible_path=APP + "/Contents/Frameworks/cmux DEV Chromium Host.app/Contents/MacOS/cmux DEV Chromium Host")
        verdict = tcc.judge_tcc(tcc.tccd_requests(lines), "kTCCServiceMicrophone", BUNDLE)
        self.assertFalse(verdict["pass"])

    def test_no_request_fails(self):
        verdict = tcc.judge_tcc(tcc.tccd_requests(tccd_lines("1.1", "kTCCServiceCamera")), "kTCCServiceBluetoothAlways", BUNDLE)
        self.assertFalse(verdict["pass"])
        self.assertIn("no kTCCServiceBluetoothAlways request", verdict["reason"])

    def test_other_apps_requests_are_ignored(self):
        lines = tccd_lines("1.1", "kTCCServiceCamera") + tccd_lines(
            "2.1", "kTCCServiceCamera", subject="com.apple.FaceTime", responsible_id="com.apple.FaceTime",
            responsible_path="/System/Applications/FaceTime.app/Contents/MacOS/FaceTime",
            accessing="/System/Applications/FaceTime.app/Contents/MacOS/FaceTime")
        verdict = tcc.judge_tcc(tcc.tccd_requests(lines), "kTCCServiceCamera", BUNDLE)
        self.assertTrue(verdict["pass"], verdict)
        self.assertEqual(len(verdict["requests"]), 1)

    def test_redacted_log_fails(self):
        lines = tccd_lines("1.1", "kTCCServiceCamera", subject="<private>")
        verdict = tcc.judge_tcc(tcc.tccd_requests(lines), "kTCCServiceCamera", BUNDLE)
        self.assertFalse(verdict["pass"])
        self.assertIn("redacts", verdict["reason"])


class DaemonTests(unittest.TestCase):
    def test_cmux_only_passes(self):
        lines = [("locationd", '{"msg":"client authorization", "Client":"icom.cmuxterm.app.debug.t89:"}')]
        self.assertTrue(tcc.judge_daemon(lines, ("locationd",), BUNDLE)["pass"])

    def test_helper_identity_fails(self):
        lines = [("nehelper", "Local network prompt for com.cmuxterm.app.debug.t89.helper"),
                 ("nehelper", "client com.cmuxterm.app.debug.t89")]
        verdict = tcc.judge_daemon(lines, ("nehelper",), BUNDLE)
        self.assertFalse(verdict["pass"])
        self.assertEqual(verdict["foreign"], ["com.cmuxterm.app.debug.t89.helper"])

    def test_chromium_identity_fails(self):
        lines = [("locationd", "client org.chromium.ContentShell and com.cmuxterm.app.debug.t89")]
        self.assertFalse(tcc.judge_daemon(lines, ("locationd",), BUNDLE)["pass"])

    def test_other_process_and_silence_fail(self):
        verdict = tcc.judge_daemon([("tccd", "com.cmuxterm.app.debug.t89")], ("locationd",), BUNDLE)
        self.assertFalse(verdict["pass"])
        self.assertIn("never names", verdict["reason"])

    def test_longer_bundle_id_is_not_cmux(self):
        names = tcc.identities("client com.cmuxterm.app.debug.t890", BUNDLE)
        self.assertEqual(names, set())


class PromptTests(unittest.TestCase):
    def test_text_must_name_cmux_and_not_chromium(self):
        good = {"text": ["“cmux DEV t89” would like to access the camera."]}
        host = {"text": ["“cmux DEV t89 Chromium Host” would like to access the camera."]}
        unreadable = {"text": None, "error": "not allowed assistive access"}
        self.assertTrue(tcc.judge_prompts([good, unreadable], BUNDLE)["pass"])
        verdict = tcc.judge_prompts([good, host], BUNDLE)
        self.assertFalse(verdict["pass"])
        self.assertEqual(tcc.judge_prompts([unreadable], BUNDLE)["unreadable"], 1)


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class StandInHost:
    """A host page whose rows answer at once; `evidence(row)` is what the daemons log for a row's request."""

    def __init__(self, clock, evidence, windows=None, answer=True):
        self.clock, self.evidence, self.answer = clock, evidence, answer
        self.state = {}
        self.lines = []
        self.window_list = windows or []
        self.allows = 0
        self.opened = None

    def open_host(self, url):
        self.opened = url
        return {"phase": "shown"}

    def title(self):
        return tcc.TITLE_PREFIX + json.dumps(self.state) if self.opened else None

    def press(self, key):
        row = next(r for r in tcc.ROWS if r.key == key)
        self.state[row.name] = {"state": "rejected" if self.answer else "pending", "error": "NotAllowedError"}
        self.lines += [(self.clock() + 0.1, process, message) for process, message in self.evidence(row)]

    def allow(self):
        self.allows += 1

    def between(self, start, end):
        return [(p, m) for at, p, m in self.lines if start <= at <= end]

    def windows(self):
        return list(self.window_list)


def cmux_evidence(row):
    if row.kind == "tcc":
        return [("tccd", line) for line in tccd_lines(f"{ord(row.key)}.1", row.service)]
    return [(row.processes[0], f"client {BUNDLE.identifier}")]


def rows_with(host, clock, bundle=BUNDLE, os_major=26, keychain=lambda service: True, prompt=None):
    seams = tcc.Seams(log=host, windows=host.windows, prompt=prompt or (lambda owner: {"text": None, "error": "no AX"}),
                      keychain=keychain, clock=clock, sleep=clock.sleep, os_major=os_major)
    return tcc.TccRows(bundle, host.open_host, host.title, host.press, host.allow, seams=seams)


class RunTests(unittest.TestCase):
    def test_every_row_passes_when_cmux_is_charged(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        result = rows_with(host, clock).run("http://127.0.0.1:1/tcc.html")
        for name in ("camera", "microphone", "location", "local_network", "screen", "bluetooth"):
            self.assertTrue(result["rows"][name]["pass"], (name, result["rows"][name]))
        # A development bundle never reads the real keychain: the row says so instead of passing.
        self.assertIsNone(result["rows"]["keychain"]["pass"])
        self.assertEqual(result["not_measurable"], ["keychain"])
        self.assertFalse(result["pass"])
        self.assertGreaterEqual(host.allows, 6)

    def test_release_bundle_keychain_passes_without_prompt(self):
        clock = Clock()

        def evidence(row):
            if row.kind == "tcc":
                return [("tccd", line) for line in tccd_lines(
                    f"{ord(row.key)}.1", row.service, subject=RELEASE.identifier, responsible_id=RELEASE.identifier,
                    responsible_path=RELEASE.executable,
                    accessing="/Applications/cmux.app/Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper")]
            return [(row.processes[0], f"client {RELEASE.identifier}")]
        host = StandInHost(clock, evidence)
        result = rows_with(host, clock, bundle=RELEASE).run("http://127.0.0.1:1/tcc.html")
        self.assertTrue(result["pass"], json.dumps(result, indent=1)[:2000])
        print_lines = []
        tcc.print_rows(result, print_lines.append)
        self.assertIn("TCC-ROW keychain PASS", print_lines)

    def test_keychain_prompt_fails(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        rows = rows_with(host, clock, bundle=RELEASE)
        host.window_list = []
        original = host.press

        def press(key):
            original(key)
            host.window_list = [{"id": 9, "owner": "SecurityAgent", "pid": 50, "layer": 1500}]
        rows.press = press
        result = rows.run("http://127.0.0.1:1/tcc.html")
        self.assertFalse(result["rows"]["keychain"]["pass"])
        self.assertIn("SecurityAgent", result["rows"]["keychain"]["prompt_owners"])

    def test_preexisting_windows_are_not_this_runs_prompts(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence, windows=[{"id": 3, "owner": "SecurityAgent", "pid": 50, "layer": 1500}])
        result = rows_with(host, clock, bundle=RELEASE).run("http://127.0.0.1:1/tcc.html")
        self.assertEqual(result["rows"]["keychain"]["prompt_owners"], [])

    def test_local_network_does_not_apply_on_14(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        result = rows_with(host, clock, os_major=14).run("http://127.0.0.1:1/tcc.html")
        row = result["rows"]["local_network"]
        self.assertFalse(row["applies"])
        self.assertTrue(row["pass"])
        lines = []
        tcc.print_rows(result, lines.append)
        self.assertTrue(any(line.startswith("TCC-ROW local_network N/A") for line in lines))

    def test_prompt_naming_the_host_fails_its_row_and_is_denied(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        asked = []

        def prompt(owner):
            asked.append(owner)
            return {"text": ["“cmux DEV t89 Chromium Host” would like to access the camera."], "clicked": "Don’t Allow"}
        rows = rows_with(host, clock, prompt=prompt)
        original = host.press

        def press(key):
            original(key)
            if key == "c":
                host.window_list = [{"id": 11, "owner": "UserNotificationCenter", "pid": 60, "layer": 2000}]
        rows.press = press
        result = rows.run("http://127.0.0.1:1/tcc.html")
        self.assertFalse(result["rows"]["camera"]["pass"])
        self.assertIn("does not name", result["rows"]["camera"]["reason"])
        self.assertEqual(asked, ["UserNotificationCenter"])  # read and answered once
        self.assertTrue(result["rows"]["microphone"]["pass"])

    def test_unanswered_row_ends_at_its_limit(self):
        clock = Clock()
        host = StandInHost(clock, lambda row: [], answer=False)
        start = clock()
        result = rows_with(host, clock).run("http://127.0.0.1:1/tcc.html")
        self.assertFalse(result["rows"]["camera"]["pass"])
        self.assertEqual(result["rows"]["camera"]["page"]["state"], "pending")
        self.assertLess(clock() - start, 7 * (tcc.ROW_LIMIT_S + tcc.LOG_GRACE_S + 1) + 60)

    def test_page_that_never_shows_fails(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        host.title = lambda: None
        result = rows_with(host, clock).run("http://127.0.0.1:1/tcc.html")
        self.assertFalse(result["pass"])
        self.assertIn("never showed", result["error"])


class PageTests(unittest.TestCase):
    def test_page_has_every_row_and_title_round_trips(self):
        html = tcc.page(lan_url="http://192.168.64.2:5/lan")
        for row in tcc.ROWS:
            self.assertIn(f'"{row.key}": ["{row.name}"', html)
        self.assertIn('const LAN = "http://192.168.64.2:5/lan"', html)
        self.assertEqual(tcc.page_state('tcc {"camera": {"state": "resolved"}}'), {"camera": {"state": "resolved"}})
        self.assertIsNone(tcc.page_state("probe {}"))
        self.assertEqual(len({row.key for row in tcc.ROWS}), len(tcc.ROWS))

    def test_pages_serve_probe_and_lan_target(self):
        pages = tcc.Pages()
        url, lan = pages.start()
        try:
            body = urllib.request.urlopen(url, timeout=5).read().decode()
            self.assertIn("TCC attribution probe", body)
            if lan:
                lan_url = body.split('const LAN = "')[1].split('"')[0]
                reply = urllib.request.urlopen(lan_url, timeout=5)
                self.assertEqual(reply.headers["Access-Control-Allow-Origin"], "*")
                self.assertEqual(pages.lan_hits, 1)
        finally:
            pages.stop()

    def test_page_background_is_not_the_helper_pixel_probes(self):
        # The helper's pixels row counts the probe's background on screen before its host page opens.
        spec = importlib.util.spec_from_file_location("chromium_host_bench_089", BENCH)
        bench = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bench)
        background = re.search(r"background:#([0-9a-f]{6})", tcc.page()).group(1)
        rgb = tuple(int(background[i:i + 2], 16) for i in (0, 2, 4))
        self.assertTrue(any(abs(c - p) > bench.PROBE_TOLERANCE for c, p in zip(rgb, bench.PROBE_RGB)), background)


class BenchWiringTests(unittest.TestCase):
    """run_tcc's debug.chromium_host calls, read from chromium-host-bench.py's source."""

    def setUp(self):
        tree = ast.parse(BENCH.read_text())
        run_tcc = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "run_tcc")
        self.params = [{k.value: v.value for k, v in zip(n.keys, n.values) if isinstance(v, ast.Constant)}
                       for n in ast.walk(run_tcc) if isinstance(n, ast.Dict) and "op" in
                       [k.value for k in n.keys if isinstance(k, ast.Constant)]]

    def test_the_host_page_opens_focused(self):
        # The rows' keys are the page's user activation: without focus they go to another responder.
        self.assertEqual([p.get("focus") for p in self.params if p.get("op") == "open"], [True])

    def test_the_host_closes_before_the_helper_rows(self):
        self.assertIn({"op": "close"}, self.params)


if __name__ == "__main__":
    unittest.main()
