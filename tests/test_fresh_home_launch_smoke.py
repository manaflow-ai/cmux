#!/usr/bin/env python3
"""scripts/ci/fresh_home_launch_smoke.py, the nightly-next fresh-home launch gate, against stub apps.

A stub that aborts at launch fails it, a healthy stub (it serves snapshot.get with Home selected
in a visible window and streams the launch marks) passes it, a stub that stays up but never shows
Home fails it, and every run leaves no process and no private root behind. The healthy stub also
checks what the gate promises the app: an empty HOME, no runner variables, and its defaults set
aside and put back.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "fresh_home_launch_smoke.py"
spec = importlib.util.spec_from_file_location("fresh_home_launch_smoke", SCRIPT)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)

BUNDLE = "com.example.fresh-smoke-stub"

# The stub app: MODE (crash | healthy | no-home) comes from the bundle's Resources/mode file.
STUB = r'''#!PYTHON
import json, os, signal, socket, subprocess, sys, time
here = os.path.dirname(os.path.abspath(__file__))
mode = open(os.path.join(here, "..", "Resources", "mode")).read().strip()
home = os.environ["HOME"]
report = {"home_entries": sorted(os.listdir(home)), "cffixed": os.environ.get("CFFIXED_USER_HOME"),
          "leaked": sorted(k for k in os.environ if k in ("GH_TOKEN", "FRESH_SMOKE_SECRET", "RUNNER_TEMP"))}
open(os.path.join(home, "stub-report.json"), "w").write(json.dumps(report))
# A detached helper, as the real app's daemons are: cleanup must stop it by the run's root.
helper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)", os.path.abspath(__file__)],
                          start_new_session=True)
open(os.path.join(home, "helper.pid"), "w").write(str(helper.pid))
if mode == "crash":
    time.sleep(0.5)
    os.abort()
marks = int(os.environ["CMUX_NEXT_LAUNCH_MARKS_FD"])
os.write(marks, b"main_start 10.0\n")
if mode == "healthy":
    os.write(marks, b"first_window_frame_committed 120.5\n")
page = "home-dock" if mode == "healthy" else "terminal"
topology = {"windows": [{"id": "win_1", "visible": True, "workspace": "ws_1"}],
            "workspaces": [{"id": "ws_1", "name": "Home", "screens": [{"panes": [
                {"id": "pane_1", "selected_tab": "tab_1", "tabs": [{"id": "tab_1", "kind": "page", "page": page}]}]}]}]}
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(os.environ["CMUX_NEXT_SOCKET_PATH"])
server.listen(8)
while True:
    conn, _ = server.accept()
    data = b""
    while b"\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            break
        data += chunk
    if data:
        request = json.loads(data.split(b"\n", 1)[0])
        conn.sendall((json.dumps({"id": request["id"], "ok": True, "result": {"topology": topology}}) + "\n").encode())
    conn.close()
'''

# A `defaults` stand-in: export writes the domain's file, delete removes it, import restores it.
DEFAULTS = r'''#!PYTHON
import os, plistlib, shutil, sys
store = os.environ["FAKE_DEFAULTS_DIR"]
verb, domain = sys.argv[1], sys.argv[2]
path = os.path.join(store, domain + ".plist")
with open(os.path.join(store, "calls.log"), "a") as log:
    log.write(" ".join(sys.argv[1:3]) + "\n")
if os.environ.get("FAKE_DEFAULTS_FAIL") == verb:
    sys.exit(1)
if verb == "export":  # as macOS does: a missing domain exports as an empty dictionary
    if os.path.exists(path):
        plistlib.dump({"stored": open(path, "rb").read()}, open(sys.argv[3], "wb"))
    else:
        plistlib.dump({}, open(sys.argv[3], "wb"))
elif verb == "delete" or verb == "read":
    if not os.path.exists(path):
        sys.exit(1)
    if verb == "delete":
        os.remove(path)
elif verb == "import":
    data = plistlib.load(open(sys.argv[3], "rb"))
    if data:
        open(path, "wb").write(data["stored"])
'''


def write_executable(path: Path, text: str) -> None:
    path.write_text(text.replace("PYTHON", sys.executable, 1))
    path.chmod(0o755)


def make_app(parent: Path, mode: str) -> Path:
    app = parent / f"Stub {mode}.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "Resources").mkdir()
    with open(app / "Contents" / "Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "stub"}, handle)
    (app / "Contents" / "Resources" / "mode").write_text(mode)
    write_executable(app / "Contents" / "MacOS" / "stub", STUB)
    return app


class FreshHomeLaunchSmokeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.defaults_dir = self.dir / "defaults-store"
        self.defaults_dir.mkdir()
        write_executable(self.dir / "defaults", DEFAULTS)
        self.env = {
            **os.environ,
            "CMUX_FRESH_SMOKE_DEFAULTS_TOOL": str(self.dir / "defaults"),
            "CMUX_FRESH_SMOKE_LOCK_DIR": str(self.dir),
            "CMUX_FRESH_SMOKE_DIAGNOSTIC_DIR": str(self.dir / "diagnostics"),
            "CMUX_FRESH_SMOKE_SKIP_SESSION_CHECK": "1",
            "CMUX_FRESH_SMOKE_CRASH_REPORT_WAIT_SECONDS": "0",
            "FAKE_DEFAULTS_DIR": str(self.defaults_dir),
            "FRESH_SMOKE_SECRET": "must-not-reach-the-app",
            "GH_TOKEN": "must-not-reach-the-app",
        }
        self.env.pop("RUNNER_TEMP", None)
        self.env.pop("CMUX_SIGNING_KEYCHAIN_STATE_DIR", None)
        self.roots_before = set(Path("/tmp").glob("cmux-fresh-*"))

    def tearDown(self):
        self.tmp.cleanup()

    def run_smoke(self, mode: str, *extra: str, env: dict | None = None) -> tuple[int, str, dict]:
        app = make_app(self.dir, mode)
        out = self.dir / f"out-{mode}"
        result = subprocess.run([sys.executable, str(SCRIPT), "--app", str(app), "--out", str(out), *extra],
                                env=env or self.env, capture_output=True, text=True, timeout=120)
        report = json.loads((out / "report.json").read_text())
        return result.returncode, result.stdout + result.stderr, report

    def assert_cleaned_up(self, report: dict) -> None:
        root = Path(report["root"])
        self.assertFalse(root.exists(), f"{root} was left behind")
        self.assertEqual(set(Path("/tmp").glob("cmux-fresh-*")) - self.roots_before, set())
        if report.get("pid"):
            self.assertFalse(smoke.alive(report["pid"]), "the app outlived the run")

    def test_a_stub_that_aborts_at_launch_fails(self):
        status, output, report = self.run_smoke("crash", "--seconds", "3", "--startup-timeout", "5")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual(report["verdict"], "fail")
        self.assertRegex(report["failures"][0], r"the app exited \(signal 6\)")
        self.assertIn("FAIL: the app exited", output)
        self.assert_cleaned_up(report)

    def test_a_healthy_stub_passes_with_a_fresh_home_and_no_runner_secrets(self):
        (self.defaults_dir / f"{BUNDLE}.plist").write_bytes(b"account defaults")
        status, output, report = self.run_smoke("healthy", "--seconds", "3", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(report["verdict"], "pass")
        self.assertEqual(report["home_tab"]["page"], "home-dock")
        self.assertIn("first_window_frame_committed", report["marks"])
        self.assertGreaterEqual(report["seconds_up"], 3)
        # The account's defaults were set aside for the run and are back, byte for byte.
        calls = (self.defaults_dir / "calls.log").read_text().split("\n")
        self.assertEqual(calls[:2], [f"export {BUNDLE}", f"delete {BUNDLE}"])
        self.assertEqual((self.defaults_dir / f"{BUNDLE}.plist").read_bytes(), b"account defaults")
        self.assert_cleaned_up(report)

    def test_defaults_a_killed_run_left_aside_are_put_back_first(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        domain.write_bytes(b"what the killed run's app wrote")
        aside = self.dir / f"cmux-fresh-smoke-{BUNDLE}.aside.plist"
        aside.write_bytes(plistlib.dumps({"stored": b"account defaults"}))
        status, output, report = self.run_smoke("healthy", "--seconds", "2", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(domain.read_bytes(), b"account defaults")
        self.assertFalse(aside.exists())

    def test_a_domain_that_did_not_exist_is_removed_again(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        status, output, report = self.run_smoke("healthy", "--seconds", "2", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        self.assertFalse(domain.exists())
        self.assertFalse((self.dir / f"cmux-fresh-smoke-{BUNDLE}.aside.plist").exists())

    def test_an_export_that_fails_is_cannot_run_and_touches_nothing(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        domain.write_bytes(b"account defaults")
        status, output, report = self.run_smoke("healthy", "--seconds", "1",
                                                env={**self.env, "FAKE_DEFAULTS_FAIL": "export"})
        self.assertEqual(status, smoke.CANNOT_RUN, output)
        self.assertNotIn("pid", report)
        self.assertEqual(domain.read_bytes(), b"account defaults")

    def test_a_delete_that_fails_keeps_the_copy_and_does_not_launch(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        domain.write_bytes(b"account defaults")
        status, output, report = self.run_smoke("healthy", "--seconds", "1",
                                                env={**self.env, "FAKE_DEFAULTS_FAIL": "delete"})
        self.assertEqual(status, smoke.CANNOT_RUN, output)
        self.assertNotIn("pid", report)
        aside = self.dir / f"cmux-fresh-smoke-{BUNDLE}.aside.plist"
        self.assertEqual(plistlib.loads(aside.read_bytes()), {"stored": b"account defaults"})

    def test_defaults_that_cannot_be_put_back_fail_closed_and_stay_aside(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        domain.write_bytes(b"account defaults")
        status, output, report = self.run_smoke("healthy", "--seconds", "2", "--startup-timeout", "10",
                                                env={**self.env, "FAKE_DEFAULTS_FAIL": "import"})
        self.assertEqual(status, smoke.CANNOT_RUN, output)
        aside = self.dir / f"cmux-fresh-smoke-{BUNDLE}.aside.plist"
        self.assertEqual(plistlib.loads(aside.read_bytes()), {"stored": b"account defaults"})
        self.assert_cleaned_up(report)

    def test_the_app_sees_an_empty_home_and_none_of_the_runner_environment(self):
        app = make_app(self.dir, "healthy")
        root = Path(tempfile.mkdtemp(prefix="cmux-fresh-", dir="/tmp"))
        try:
            fd_r, fd_w = os.pipe()
            env = smoke.fresh_env(root, root / "s.sock", fd_w)
            self.assertEqual(env["HOME"], env["CFFIXED_USER_HOME"])
            self.assertNotIn("GH_TOKEN", env)
            self.assertNotIn("FRESH_SMOKE_SECRET", env)
            entries = sorted(os.listdir(env["HOME"]))
            self.assertEqual(entries, ["Library"])
            os.close(fd_r)
            os.close(fd_w)
        finally:
            subprocess.run(["rm", "-rf", str(root)], check=False)
        self.assertTrue(app.exists())

    def test_a_stub_that_stays_up_without_home_fails(self):
        status, output, report = self.run_smoke("no-home", "--seconds", "2", "--startup-timeout", "3")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertIn("Home did not render", report["failures"][0])
        self.assert_cleaned_up(report)

    def test_the_detached_helper_is_stopped_by_the_runs_root(self):
        status, output, report = self.run_smoke("healthy", "--seconds", "2", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        time.sleep(0.2)
        self.assertEqual(smoke.pids_under(Path(report["root"])), [])

    def test_a_signing_keychain_in_the_job_means_it_cannot_run(self):
        state = self.dir / "keychain-state"
        state.mkdir()
        (state / "cmux-signing.password").write_text("x")
        status, output, report = self.run_smoke("healthy", "--seconds", "1",
                                                env={**self.env, "CMUX_SIGNING_KEYCHAIN_STATE_DIR": str(state)})
        self.assertEqual(status, smoke.CANNOT_RUN, output)
        self.assertEqual(report["verdict"], "cannot-run")
        self.assertNotIn("pid", report)
        self.assert_cleaned_up(report)

    def test_a_crash_report_written_during_the_run_fails_it(self):
        diagnostics = self.dir / "diagnostics"
        diagnostics.mkdir()
        found = smoke.crash_reports(diagnostics, "stub", time.time() - 5)
        self.assertEqual(found, [])
        (diagnostics / "stub-2026-10-28-000000.ips").write_text("{}")
        (diagnostics / "stubborn-2026-10-28-000000.ips").write_text("{}")
        self.assertEqual([p.name for p in smoke.crash_reports(diagnostics, "stub", time.time() - 5)],
                         ["stub-2026-10-28-000000.ips"])

    def test_home_must_be_selected_in_a_visible_window(self):
        tab = {"id": "tab_1", "kind": "page", "page": "home-dock"}
        snap = {"topology": {"windows": [{"visible": False, "workspace": "ws_1"}],
                             "workspaces": [{"id": "ws_1", "screens": [{"panes": [{"selected_tab": "tab_1", "tabs": [tab]}]}]}]}}
        self.assertIsNone(smoke.home_tab(snap))
        snap["topology"]["windows"][0]["visible"] = True
        self.assertEqual(smoke.home_tab(snap), tab)
        snap["topology"]["workspaces"][0]["screens"][0]["panes"][0]["selected_tab"] = "tab_2"
        self.assertIsNone(smoke.home_tab(snap))


if __name__ == "__main__":
    unittest.main()
