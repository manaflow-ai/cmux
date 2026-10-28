#!/usr/bin/env python3
"""chromium-host-bench.py's TCC attribution rows (chromium_host_tcc.py, task 089) judge the evidence right.

The rows pass only when tccd, locationd and nehelper charge a host page's requests to cmux's bundle id and main
executable, fail when the host executable, a helper or a bundle of their own is charged, and never pass on missing or
redacted evidence, on cmux's own requests alone, or on a keychain item the host did not create. The mode stops before
any row when cmux is not its own responsible process. Drives TccRows with a stand-in host page, log, window list and clock (no app, GUI or macOS).

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

    def test_cmux_own_request_alone_fails(self):
        # cmux's own preflight (SystemPermissionProbe) is charged to cmux too, but the host never asked.
        lines = tccd_lines("1.1", "kTCCServiceCamera", accessing=BUNDLE.executable)
        verdict = tcc.judge_tcc(tcc.tccd_requests(lines), "kTCCServiceCamera", BUNDLE)
        self.assertFalse(verdict["pass"])
        self.assertEqual((verdict["app_requests"], verdict["host_requests"]), (1, 0))
        self.assertIn("from the Chromium host or a helper", verdict["reason"])

    def test_cmux_own_request_beside_the_hosts_passes(self):
        lines = tccd_lines("1.1", "kTCCServiceCamera", accessing=BUNDLE.executable) + tccd_lines(
            "1.2", "kTCCServiceCamera", accessing=HOST)
        verdict = tcc.judge_tcc(tcc.tccd_requests(lines), "kTCCServiceCamera", BUNDLE)
        self.assertTrue(verdict["pass"], verdict)
        self.assertEqual((verdict["app_requests"], verdict["host_requests"]), (1, 1))

    def test_cmux_own_request_charged_elsewhere_fails(self):
        lines = tccd_lines("1.1", "kTCCServiceCamera", accessing=BUNDLE.executable,
                           responsible_path="/usr/bin/sshd", responsible_id="com.openssh.sshd") + tccd_lines(
            "1.2", "kTCCServiceCamera")
        verdict = tcc.judge_tcc(tcc.tccd_requests(lines), "kTCCServiceCamera", BUNDLE)
        self.assertFalse(verdict["pass"])
        self.assertIn("another identity", verdict["reason"])

    def test_redacted_log_fails(self):
        lines = tccd_lines("1.1", "kTCCServiceCamera", subject="<private>")
        verdict = tcc.judge_tcc(tcc.tccd_requests(lines), "kTCCServiceCamera", BUNDLE)
        self.assertFalse(verdict["pass"])
        self.assertIn("redacts", verdict["reason"])




class DaemonTests(unittest.TestCase):
    EVIDENCE = "the page got a position"

    def test_cmux_only_with_host_evidence_passes(self):
        lines = [("locationd", '{"msg":"client authorization", "Client":"icom.cmuxterm.app.debug.t89:"}')]
        self.assertTrue(tcc.judge_daemon(lines, ("locationd",), BUNDLE, self.EVIDENCE)["pass"])

    def test_cmux_only_lines_without_host_evidence_do_not_pass(self):
        # A line naming cmux may be about cmux's own work: with no sign the host's request got there it proves nothing.
        lines = [("locationd", "client com.cmuxterm.app.debug.t89"), ("nehelper", "client com.cmuxterm.app.debug.t89")]
        for processes in (("locationd",), ("nehelper",)):
            verdict = tcc.judge_daemon(lines, processes, BUNDLE, None)
            self.assertIsNone(verdict["pass"], verdict)
            self.assertIn("no evidence that the host's request reached", verdict["reason"])

    def test_helper_identity_fails(self):
        lines = [("nehelper", "Local network prompt for com.cmuxterm.app.debug.t89.helper"),
                 ("nehelper", "client com.cmuxterm.app.debug.t89")]
        for evidence in (self.EVIDENCE, None):
            verdict = tcc.judge_daemon(lines, ("nehelper",), BUNDLE, evidence)
            self.assertIs(verdict["pass"], False)
            self.assertEqual(verdict["foreign"], ["com.cmuxterm.app.debug.t89.helper"])

    def test_chromium_identity_fails(self):
        lines = [("locationd", "client org.chromium.ContentShell and com.cmuxterm.app.debug.t89")]
        self.assertIs(tcc.judge_daemon(lines, ("locationd",), BUNDLE, self.EVIDENCE)["pass"], False)

    def test_other_process_and_silence_fail(self):
        verdict = tcc.judge_daemon([("tccd", "com.cmuxterm.app.debug.t89")], ("locationd",), BUNDLE, self.EVIDENCE)
        self.assertIs(verdict["pass"], False)
        self.assertIn("never names", verdict["reason"])

    def test_longer_bundle_id_is_not_cmux(self):
        names = tcc.identities("client com.cmuxterm.app.debug.t890", BUNDLE)
        self.assertEqual(names, set())

    def test_a_line_names_the_host_by_pid_or_path(self):
        self.assertTrue(tcc.names_process("Local network access from pid 7123, client x", 7123, HOST))
        self.assertTrue(tcc.names_process("{pid=7123}", 7123, HOST))
        self.assertTrue(tcc.names_process(f"path {HOST}", None, HOST))
        self.assertFalse(tcc.names_process("pid 71234", 7123, HOST))
        self.assertFalse(tcc.names_process("anything", None, None))

    def test_location_reached_corelocation(self):
        self.assertIsNotNone(tcc.location_evidence({"state": "resolved", "value": "position"}, False))
        for code in ("2", "3"):
            self.assertIsNotNone(tcc.location_evidence({"state": "rejected", "message": f"geolocation {code}"}, False))
        denied = {"state": "rejected", "message": "geolocation 1"}
        # Chromium's own PERMISSION_DENIED (no site grant) never reached CoreLocation; after the grant it is macOS's.
        self.assertIsNone(tcc.location_evidence(denied, False))
        self.assertIsNotNone(tcc.location_evidence(denied, True))
        self.assertIsNone(tcc.location_evidence({"state": "pending"}, True))

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


class Keychain:
    """The login keychain's "Chromium Safe Storage" item. A host that starts makes it when it is missing
    (`host_creates`); one that finds it reads it, or replaces it (`host_reads` False: the read failed)."""

    def __init__(self, exists=False, created=None, host_creates=True, host_reads=True):
        self.exists, self.created = exists, created if exists else None
        self.host_creates, self.host_reads = host_creates, host_reads
        self.deletes = 0
        self.made = 0

    def info(self, service):
        return {"exists": self.exists, "created": self.created}

    def delete(self, service):
        self.deletes += 1
        self.exists, self.created = False, None
        return True

    def _make(self):
        self.made += 1
        self.exists, self.created = True, f"2026102712000{self.made}Z"

    def host_started(self):
        """Whether the host could read the item it started with (the cookie it stored before is readable)."""
        if not self.exists:
            if self.host_creates:
                self._make()
            return False
        if not self.host_reads:
            self._make()
            return False
        return True


class StandInHost:
    """A Chromium tab on the host: a row's request waits for cmux's prompt bar answer (`prompt_bar`: whether the
    bar asks at all) when its site permission needs one, and reaches macOS (`evidence(row)` logs its lines) only once
    answered. Each host start loads the page again with the cookie the last host stored, unless it lost the key."""

    def __init__(self, clock, evidence, keychain=None, windows=None, prompt_bar=True, answer="resolved", seed_cookie=""):
        self.clock, self.evidence, self.prompt_bar, self.answer = clock, evidence, prompt_bar, answer
        self.keychain = keychain or Keychain()
        self.state = {}
        self.lines = []
        self.window_list = windows or []
        self.allows = 0
        self.pending = None
        self.opened = None
        self.pid = 0
        self.cookie = seed_cookie
        self.lan = 0
        self.restarts = 0
        self.on_start = lambda: None

    def _start(self):
        self.pid += 7000
        read = self.keychain.host_started()
        load = {"t": f"load-{self.pid}", "prior": self.cookie if read else ""}
        self.cookie = load["t"]
        self.state = {"_load": load}
        self.on_start()

    def open_host(self, url):
        self.opened = url
        self._start()
        return {"tab": "tab-1"}

    def restart_host(self):
        old = self.pid
        self.restarts += 1
        self._start()
        return {"old_pid": old, "new_pid": self.pid, "error": None}

    def title(self):
        return tcc.TITLE_PREFIX + json.dumps(self.state) if self.opened else None

    def press(self, key):
        row = next(r for r in tcc.ROWS if r.key == key)
        self.state[row.name] = {"state": "pending"}
        if row.site in tcc.ALLOWED_SITES:
            self.pending = row
        elif row.site == tcc.SITE_NONE:
            self._reach(row)

    def _reach(self, row):
        if row.name == "local_network":
            self.lan += 1
        if self.answer == "resolved":
            self.state[row.name] = {"state": "resolved", "value": "position" if row.name == "location" else "stream"}
        else:
            self.state[row.name] = {"state": "rejected", "error": "NotAllowedError", "message": self.answer}
        self.lines += [(self.clock() + 0.1, process, message) for process, message in self.evidence(row, self.pid)]

    def allow(self):
        self.allows += 1
        if not self.prompt_bar or self.pending is None:
            return False
        row, self.pending = self.pending, None
        self._reach(row)
        return True

    def between(self, start, end):
        return [(p, m) for at, p, m in self.lines if start <= at <= end]

    def windows(self):
        return list(self.window_list)


def cmux_evidence(row, host_pid=0, bundle=BUNDLE, accessing=HOST):
    if row.kind == "tcc":
        return [("tccd", line) for line in tccd_lines(f"{ord(row.key)}.1", row.service, subject=bundle.identifier,
                                                      responsible_id=bundle.identifier,
                                                      responsible_path=bundle.executable, accessing=accessing)]
    return [(row.processes[0], f"client {bundle.identifier}")]


APP_PID = 4242
REAL = {"real_keychain": True, "may_delete": True, "existed": False}
SEED_CREATED = "20261027110000Z"
SEED = {"created": SEED_CREATED, "cookie": "seed-cookie", "backend": "inProcess"}
DEVELOPER_ID = "Developer ID Application: Manaflow, Inc. (7WLXT3NR37)"


def seeded(**options):
    """A keychain with the item cmux's in-process engine made in the seed launch."""
    return Keychain(exists=True, created=SEED_CREATED, **options)


def rows_with(host, clock, bundle=BUNDLE, os_major=26, prompt=None, plan=None, responsible=None, app_pid=APP_PID,
              seed=None, backend="host", authority=lambda path: "Apple Development: t89"):
    seams = tcc.Seams(log=host, windows=host.windows, prompt=prompt or (lambda owner: {"text": None, "error": "no AX"}),
                      keychain=host.keychain.info, delete_keychain=host.keychain.delete,
                      responsible=responsible or (lambda pid: pid), process_path=lambda pid: f"/proc/{pid}",
                      authority=authority, host_pid=lambda: host.pid or None, lan_hits=lambda: host.lan,
                      clock=clock, sleep=clock.sleep, os_major=os_major)
    return tcc.TccRows(bundle, host.open_host, host.title, host.press, host.allow, restart_host=host.restart_host,
                       backend=lambda: backend, seams=seams, app_pid=app_pid, keychain_plan=plan, seed=seed)


ATTRIBUTION_ROWS = ("camera", "microphone", "location", "local_network", "screen", "bluetooth")


class RunTests(unittest.TestCase):
    URL = "http://127.0.0.1:1/tcc.html"

    def test_rows_pass_when_cmux_is_charged_for_the_hosts_answered_requests(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        result = rows_with(host, clock).run(self.URL)
        for name in ("camera", "microphone", "location", "local_network"):
            row = result["rows"][name]
            self.assertTrue(row["pass"], (name, row))
            self.assertTrue(row["site"]["answered"], (name, row["site"]))
        self.assertGreater(result["rows"]["camera"]["site"]["prompts_allowed"], 0)
        self.assertIn("LAN target answered", result["rows"]["local_network"]["host_evidence"])
        self.assertEqual(result["rows"]["location"]["host_evidence"], "the page got a position")

    def test_a_row_whose_site_permission_was_never_answered_is_a_mode_error(self):
        # No question in cmux's prompt bar (the build lacks task 062's prompts): browser.prompt.allow has nothing to
        # answer, the request never reaches macOS, and no row is a PASS or an attribution FAIL.
        clock = Clock()
        host = StandInHost(clock, cmux_evidence, prompt_bar=False)
        result = rows_with(host, clock).run(self.URL)
        for name in ("camera", "microphone", "location"):
            row = result["rows"][name]
            self.assertTrue(row.get("mode_error"), (name, row))
            self.assertIsNone(row["pass"])
            self.assertFalse(row["site"]["answered"])
            self.assertEqual(row["site"]["prompts_allowed"], 0)
            self.assertIn("prompt bar never asked", row["reason"])
        self.assertGreater(host.allows, 0)
        self.assertIn("camera", result["mode_errors"])
        self.assertNotIn("camera", result["failing"] + result["not_measurable"])
        self.assertFalse(result["pass"])
        lines = []
        tcc.print_rows(result, lines.append)
        self.assertTrue(any(line.startswith("TCC-ROW camera MODE-ERROR") for line in lines), lines)

    def test_chooser_and_picker_rows_without_an_answer_are_mode_errors(self):
        # The bench has no answer for Web Bluetooth's chooser or the screen share picker (task 228).
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        original = host.allow

        def allow():
            if host.pending and host.pending.site == tcc.SITE_PICKER:
                host.pending = None  # the prompt is answered; the picker waits
                host.allows += 1
                return True
            return original()
        host.allow = allow
        result = rows_with(host, clock).run(self.URL)
        for name, missing in (("screen", "screen share picker"), ("bluetooth", "device chooser")):
            row = result["rows"][name]
            self.assertTrue(row.get("mode_error"), (name, row))
            self.assertIn(missing, row["reason"])

    def test_a_request_that_reached_macos_is_judged_even_without_an_answered_picker(self):
        clock = Clock()

        def evidence(row, pid):
            return cmux_evidence(row, pid, accessing=APP + "/Contents/MacOS/cmux DEV Chromium Host")
        host = StandInHost(clock, evidence)
        original = host.press

        def press(key):
            original(key)
            if key == "b":  # Chromium starts its Bluetooth adapter (tccd sees the host) before the chooser
                host.lines += [(clock() + 0.1, p, m) for p, m in evidence(tcc.ROWS[5], host.pid)]
        host.press = press
        row = rows_with(host, clock).run(self.URL)["rows"]["bluetooth"]
        self.assertTrue(row["pass"], row)
        self.assertFalse(row.get("mode_error"))

    def test_daemon_rows_with_cmux_lines_but_no_host_evidence_are_not_measurable(self):
        # Granted, but the fetch failed and locationd denied before CoreLocation: only unrelated cmux lines remain.
        clock = Clock()
        host = StandInHost(clock, cmux_evidence, answer="geolocation 1")
        host.press_original = host.press

        def press(key):
            host.press_original(key)
            if key == "n":
                host.lan -= 1  # the fetch never reached the LAN server
        host.press = press
        result = rows_with(host, clock, os_major=26).run(self.URL)
        location = result["rows"]["location"]
        self.assertTrue(location["pass"], location)  # granted, then macOS's PERMISSION_DENIED: it reached CoreLocation
        local = result["rows"]["local_network"]
        self.assertIsNone(local["pass"], local)
        self.assertFalse(local.get("mode_error"))
        self.assertIn("no evidence", local["reason"])
        self.assertIn("local_network", result["not_measurable"])

    def test_a_nehelper_line_naming_the_host_is_host_evidence(self):
        clock = Clock()

        def evidence(row, pid):
            lines = cmux_evidence(row, pid)
            if row.name == "local_network":
                lines.append(("nehelper", f"Local Network access check pid {pid} client {BUNDLE.identifier}"))
            return lines
        host = StandInHost(clock, evidence)
        original = host._reach

        def reach(row):
            original(row)
            if row.name == "local_network":
                host.lan -= 1
        host._reach = reach
        local = rows_with(host, clock).run(self.URL)["rows"]["local_network"]
        self.assertTrue(local["pass"], local)
        self.assertIn("names the host", local["host_evidence"])

    def test_in_process_chromium_is_a_mode_error(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        result = rows_with(host, clock, backend="inProcess").run(self.URL)
        self.assertTrue(result["mode_error"])
        self.assertIn("do not run in the Chromium host", result["error"])
        self.assertIsNone(host.opened, "no row runs")

    def test_cmux_charged_to_the_bench_is_a_mode_error(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        result = rows_with(host, clock, responsible=lambda pid: 77).run(self.URL)
        self.assertTrue(result["mode_error"])
        self.assertIn("mode error", result["error"])
        self.assertEqual(result["responsibility"],
                         {"app_pid": APP_PID, "responsible_pid": 77, "responsible_path": "/proc/77"})
        self.assertEqual(result["rows"], {})
        self.assertIsNone(host.opened, "no row runs")
        self.assertFalse(result["pass"])
        lines = []
        tcc.print_rows(result, lines.append)
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("TCC-ROWS FAIL (mode error"))

    def test_unknown_responsibility_is_a_mode_error(self):
        clock = Clock()
        for responsible, app_pid in ((lambda pid: None, APP_PID), (None, None)):
            result = rows_with(StandInHost(clock, cmux_evidence), clock, responsible=responsible, app_pid=app_pid).run(
                self.URL)
            self.assertTrue(result["mode_error"], result)

    def test_local_network_does_not_apply_on_14(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        result = rows_with(host, clock, os_major=14).run(self.URL)
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
        result = rows.run(self.URL)
        self.assertIs(result["rows"]["camera"]["pass"], False)
        self.assertIn("does not name", result["rows"]["camera"]["reason"])
        self.assertEqual(asked, ["UserNotificationCenter"])  # read and answered once
        self.assertTrue(result["rows"]["microphone"]["pass"])

    def test_unanswered_row_ends_at_its_limit(self):
        clock = Clock()
        host = StandInHost(clock, lambda row, pid: [], prompt_bar=False)
        start = clock()
        result = rows_with(host, clock).run(self.URL)
        self.assertEqual(result["rows"]["camera"]["page"]["state"], "pending")
        self.assertLess(clock() - start, 7 * (tcc.ROW_LIMIT_S + tcc.LOG_GRACE_S + 1) + 60)

    def test_page_that_never_shows_fails(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        host.title = lambda: None
        result = rows_with(host, clock).run(self.URL)
        self.assertFalse(result["pass"])
        self.assertIn("never showed", result["error"])


class KeychainRowTests(unittest.TestCase):
    URL = "http://127.0.0.1:1/tcc.html"

    def run_rows(self, keychain, bundle=BUNDLE, plan=REAL, seed=SEED, authority=lambda path: "Apple Development: t89",
                 host=None):
        clock = Clock()
        host = host or StandInHost(clock, cmux_evidence, keychain=keychain, seed_cookie="seed-cookie")
        host.clock = clock
        result = rows_with(host, clock, bundle=bundle, plan=plan, seed=seed, authority=authority).run(self.URL)
        return result, host

    def test_the_host_reads_cmuxs_item_makes_a_new_one_and_reads_its_own(self):
        keychain = seeded()
        result, host = self.run_rows(keychain)
        row = result["rows"]["keychain"]
        steps = row["steps"]
        self.assertTrue(row["pass"], json.dumps(row, indent=1)[:3000])
        self.assertEqual(steps["cross_identity"]["prior_cookie"], "seed-cookie")
        self.assertEqual(steps["cross_identity"]["created_after"], SEED_CREATED)
        self.assertTrue(steps["create"]["deleted_before"])
        self.assertNotEqual(steps["create"]["created"], SEED_CREATED)
        self.assertEqual(steps["read"]["created"], steps["create"]["created"])
        self.assertEqual(steps["read"]["load"]["prior"], steps["create"]["load"]["t"])
        self.assertEqual(host.restarts, 2, "create and read each start a new host")
        self.assertTrue(row["deleted_after"])
        self.assertFalse(keychain.exists, "this run's item does not outlive it")
        lines = []
        tcc.print_rows(result, lines.append)
        for step in ("cross_identity", "create", "read"):
            self.assertIn(f"TCC-ROW keychain.{step} PASS", lines)

    def test_the_read_restarts_the_host_after_chromiums_cookie_commit(self):
        # The create step's cookie is on disk, encrypted with the new item's key, only after the store committed it.
        clock = Clock()
        host = StandInHost(clock, cmux_evidence, keychain=seeded(), seed_cookie="seed-cookie")
        restarts, original = [], host.restart_host
        host.restart_host = lambda: restarts.append(clock()) or original()
        result = rows_with(host, clock, plan=REAL, seed=SEED).run(self.URL)
        create = result["rows"]["keychain"]["steps"]["create"]
        self.assertEqual(len(restarts), 2)
        self.assertGreaterEqual(restarts[1], create["loaded_at"] + tcc.COOKIE_COMMIT_S)

    def test_a_host_that_cannot_read_an_existing_item_fails_cross_identity_and_read(self):
        result, _ = self.run_rows(seeded(host_reads=False))
        steps = result["rows"]["keychain"]["steps"]
        self.assertIs(steps["cross_identity"]["pass"], False)
        self.assertIn("replaced the item cmux's in-process engine made", steps["cross_identity"]["reason"])
        self.assertTrue(steps["create"]["pass"])
        self.assertIs(steps["read"]["pass"], False)
        self.assertIn("replaced", steps["read"]["reason"])
        self.assertIs(result["rows"]["keychain"]["pass"], False)

    def test_a_keychain_prompt_at_the_first_host_start_fails_cross_identity(self):
        keychain = seeded()
        clock = Clock()
        host = StandInHost(clock, cmux_evidence, keychain=keychain, seed_cookie="seed-cookie")
        denied = []
        host.on_start = lambda: host.restarts == 0 and host.window_list.append(
            {"id": 40, "owner": "SecurityAgent", "pid": 50, "layer": 1500})

        def prompt(owner):
            denied.append(owner)
            return {"text": ["cmux DEV t89 wants to use your confidential information stored in “Chromium Safe "
                             "Storage” in your keychain."], "clicked": "Deny"}
        result = rows_with(host, clock, plan=REAL, seed=SEED, prompt=prompt).run(self.URL)
        steps = result["rows"]["keychain"]["steps"]
        self.assertIs(steps["cross_identity"]["pass"], False)
        self.assertIn("SecurityAgent", steps["cross_identity"]["reason"])
        self.assertEqual(denied, ["SecurityAgent"], "read and denied once")
        self.assertTrue(steps["create"]["pass"], steps["create"])
        self.assertTrue(steps["read"]["pass"], steps["read"])

    def test_a_keychain_prompt_at_the_second_host_start_fails_read(self):
        keychain = seeded()
        clock = Clock()
        host = StandInHost(clock, cmux_evidence, keychain=keychain, seed_cookie="seed-cookie")
        host.on_start = lambda: host.restarts == 2 and host.window_list.append(
            {"id": 41, "owner": "SecurityAgent", "pid": 50, "layer": 1500})
        result = rows_with(host, clock, plan=REAL, seed=SEED).run(self.URL)
        steps = result["rows"]["keychain"]["steps"]
        self.assertTrue(steps["cross_identity"]["pass"])
        self.assertTrue(steps["create"]["pass"])
        self.assertIs(steps["read"]["pass"], False)
        self.assertEqual([p["owner"] for p in steps["read"]["prompts"]], ["SecurityAgent"])

    def test_a_host_that_makes_no_item_fails_create(self):
        result, _ = self.run_rows(seeded(host_creates=False))
        steps = result["rows"]["keychain"]["steps"]
        self.assertIs(steps["create"]["pass"], False)
        self.assertIn("never read its key", steps["create"]["reason"])
        self.assertIsNone(steps["read"]["pass"])

    def test_no_seed_item_leaves_cross_identity_not_measured(self):
        result, _ = self.run_rows(Keychain(), seed={"error": "seed launch: no GUI session"})
        steps = result["rows"]["keychain"]["steps"]
        self.assertIsNone(steps["cross_identity"]["pass"])
        self.assertIn("no GUI session", steps["cross_identity"]["reason"])
        self.assertTrue(steps["create"]["pass"])
        self.assertTrue(steps["read"]["pass"])
        self.assertIsNone(result["rows"]["keychain"]["pass"])
        self.assertIn("keychain", result["not_measurable"])

    def test_a_mock_keychain_launch_is_not_measurable(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence)
        result = rows_with(host, clock).run(self.URL)
        self.assertIsNone(result["rows"]["keychain"]["pass"])
        self.assertIn("mock keychain", result["rows"]["keychain"]["reason"])
        self.assertEqual(host.restarts, 0)

    def test_a_keychain_prompt_on_screen_before_the_mode_is_not_proof_either_way(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence, keychain=seeded(), seed_cookie="seed-cookie",
                           windows=[{"id": 3, "owner": "SecurityAgent", "pid": 50, "layer": 1500}])
        result = rows_with(host, clock, plan=REAL, seed=SEED).run(self.URL)
        steps = result["rows"]["keychain"]["steps"]
        self.assertIsNone(steps["cross_identity"]["pass"])
        self.assertIn("before the mode started", steps["cross_identity"]["reason"])
        self.assertTrue(steps["create"]["pass"])

    def test_a_host_restart_that_fails_is_a_mode_error(self):
        clock = Clock()
        host = StandInHost(clock, cmux_evidence, keychain=seeded(), seed_cookie="seed-cookie")
        host.restart_host = lambda: {"old_pid": host.pid, "new_pid": None, "error": "no new Chromium host"}
        result = rows_with(host, clock, plan=REAL, seed=SEED).run(self.URL)
        row = result["rows"]["keychain"]
        self.assertTrue(row["steps"]["create"].get("mode_error"))
        self.assertTrue(row.get("mode_error"))
        self.assertIn("keychain", result["mode_errors"])

    def test_release_identity_is_not_measured_without_a_developer_id(self):
        result, _ = self.run_rows(seeded())
        row = result["rows"]["keychain_release_identity"]
        self.assertIsNone(row["pass"])
        self.assertIn("task 088", row["reason"])
        self.assertIn("keychain_release_identity", result["not_measurable"])

    def test_release_identity_follows_the_keychain_row_once_signed(self):
        result, _ = self.run_rows(seeded(), bundle=RELEASE, authority=lambda path: DEVELOPER_ID)
        self.assertTrue(result["rows"]["keychain"]["pass"], result["rows"]["keychain"])
        self.assertTrue(result["rows"]["keychain_release_identity"]["pass"])

    def test_everything_passes_on_a_release_signed_build(self):
        clock = Clock()

        def evidence(row, pid):
            return cmux_evidence(row, pid, bundle=RELEASE,
                                 accessing="/Applications/cmux.app/Contents/MacOS/cmux Chromium Host")
        host = StandInHost(clock, evidence, keychain=seeded(), seed_cookie="seed-cookie")
        original = host.press

        def press(key):
            original(key)
            if key in "sb":  # the stand-in answers the picker and the chooser
                row = next(r for r in tcc.ROWS if r.key == key)
                host.pending = None
                host._reach(row)
        host.press = press
        result = rows_with(host, clock, bundle=RELEASE, plan=REAL, seed=SEED,
                           authority=lambda path: DEVELOPER_ID).run(self.URL)
        self.assertTrue(result["pass"], json.dumps({k: result[k] for k in ("failing", "not_measurable", "mode_errors")}))


class KeychainInfoTests(unittest.TestCase):
    def test_reads_the_creation_date(self):
        out = ('keychain: "/Users/x/Library/Keychains/login.keychain-db"\nattributes:\n'
               '    "cdat"<timedate>=0x32303236313032373131303030305A00  "20261027110000Z\\000"\n'
               '    "svce"<blob>="Chromium Safe Storage"\n')
        self.assertEqual(tcc.CREATED.search(out).group(1), "20261027110000Z")

    def test_keychain_item_is_its_existence(self):
        self.assertIs(tcc.keychain_item("S", info=lambda s: {"exists": True, "created": "x"}), True)
        self.assertIs(tcc.keychain_item("S", info=lambda s: {"exists": False, "created": None}), False)
        self.assertIsNone(tcc.keychain_item("S", info=lambda s: None))

class KeychainPlanTests(unittest.TestCase):
    def test_absent_item_turns_the_real_keychain_on(self):
        plan = tcc.keychain_plan("S", reset=False, keychain=lambda s: False, delete=self.fail)
        self.assertEqual((plan["real_keychain"], plan["may_delete"]), (True, True))

    def test_another_apps_item_keeps_the_mock_keychain_without_reset(self):
        plan = tcc.keychain_plan("S", reset=False, keychain=lambda s: True, delete=self.fail)
        self.assertEqual((plan["real_keychain"], plan["may_delete"]), (False, False))
        self.assertIn("--keychain-reset", plan["reason"])

    def test_reset_deletes_it_first(self):
        deleted = []
        plan = tcc.keychain_plan("S", reset=True, keychain=lambda s: True, delete=lambda s: deleted.append(s) or True)
        self.assertEqual((plan["real_keychain"], deleted), (True, ["S"]))
        failed = tcc.keychain_plan("S", reset=True, keychain=lambda s: True, delete=lambda s: False)
        self.assertFalse(failed["real_keychain"])

    def test_unreadable_keychain_keeps_the_mock(self):
        self.assertFalse(tcc.keychain_plan("S", reset=True, keychain=lambda s: None, delete=self.fail)["real_keychain"])

    def test_responsible_pid_is_none_without_libsystem(self):
        self.assertIsNone(tcc.responsible_pid(1, library="/nonexistent/libSystem.B.dylib"))


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
    """run_tcc and the seed launch, read from chromium-host-bench.py's source."""

    def setUp(self):
        self.source = BENCH.read_text()
        self.tree = ast.parse(self.source)
        self.functions = {n.name: n for n in self.tree.body if isinstance(n, ast.FunctionDef)}

    def strings(self, name):
        return {n.value for n in ast.walk(self.functions[name]) if isinstance(n, ast.Constant) and isinstance(n.value, str)}

    def test_the_rows_run_in_a_chromium_tab_not_the_prototype_overlay(self):
        # The debug.chromium_host overlay forwards no permission prompt: browser.prompt.allow could never answer it.
        for name in ("run_tcc", "tcc_open_page", "tcc_allow", "tcc_restart_host"):
            self.assertNotIn("debug.chromium_host", self.strings(name), name)
        self.assertIn("openBrowser.chromium", self.strings("tcc_open_page"))

    def test_allow_answers_the_tcc_tabs_prompt_bar_and_says_whether_it_had_one(self):
        strings = self.strings("tcc_allow")
        self.assertIn("browser.prompt.allow", strings)
        self.assertIn("error", strings)
        tab_target = [n for n in ast.walk(self.functions["tcc_allow"]) if isinstance(n, ast.JoinedStr)]
        self.assertTrue(tab_target, "the answer targets the probe's tab")

    def test_the_mode_checks_the_host_backend_and_restarts_the_host_for_the_keychain_steps(self):
        self.assertIn("backend", self.strings("run_tcc"))
        self.assertIn("browserReload", self.strings("tcc_restart_host"))

    def test_the_seed_launch_runs_chromium_in_process_with_the_real_keychain(self):
        seed = self.functions["seed_tcc_keychain"]
        strings = self.strings("seed_tcc_keychain")
        self.assertIn("browserHost.helper", strings)
        self.assertIn("CMUX_NEXT_BENCH_REAL_KEYCHAIN", strings)
        self.assertIn("inProcess", strings)
        self.assertTrue(any(isinstance(n, ast.Constant) and n.value is False for n in ast.walk(seed)))

    def test_the_tcc_launch_makes_cmux_its_own_responsible_process(self):
        main = self.functions["main"]
        launches = [n for n in ast.walk(main) if isinstance(n, ast.Call) and getattr(n.func, "id", "") == "BenchApp"]
        self.assertEqual(len(launches), 1)
        self.assertIn("own_responsibility", [k.arg for k in launches[0].keywords])
        lines = {n.func.id: n.lineno for n in ast.walk(main) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
        self.assertLess(lines["seed_tcc_keychain"], lines["BenchApp"], "the seed launch comes first")
        self.assertIn("CMUX_NEXT_BENCH_REAL_KEYCHAIN", self.source)

    def test_a_mode_error_fails_the_mode(self):
        returns = [n for n in ast.walk(self.functions["run_tcc"]) if isinstance(n, ast.Return)]
        self.assertIn("mode_errors", ast.unparse(returns[-1]))


if __name__ == "__main__":
    unittest.main()
