#!/usr/bin/env python3
"""apple-high/apple-standard open Screen Sharing.app with a login (vnc_url.py), and a failed view's
reason reaches the err line (screen-stream-eval.sh view_why). Both hid the 2026-11-28 ssqc-1141
apple-high failure: no login, and a bare "window 1 failed"."""
from __future__ import annotations

import importlib.util
import os
import pwd
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
EVAL = ROOT / "scripts/measure/screen-stream-eval"
spec = importlib.util.spec_from_file_location("vnc_url", EVAL / "vnc_url.py")
vnc_url = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vnc_url)


class Proc:
    def __init__(self, rc: int, out: str = "", err: str = ""):
        self.returncode, self.stdout, self.stderr = rc, out, err


class VncUrl(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.env = os.environ.get("CMUX_CI_VNC_LOGIN_FILE")

    def tearDown(self):
        if self.env is None:
            os.environ.pop("CMUX_CI_VNC_LOGIN_FILE", None)
        else:
            os.environ["CMUX_CI_VNC_LOGIN_FILE"] = self.env
        self.tmp.cleanup()

    def write(self, name: str, text: str, mode: int = 0o600) -> str:
        path = self.dir / name
        path.write_text(text)
        path.chmod(mode)
        return str(path)

    def test_step_file_wins_and_url_is_quoted(self):
        os.environ["CMUX_CI_VNC_LOGIN_FILE"] = self.write("login", "p@ss:w/rd\n")
        found, why = vnc_url.login(run=lambda *a, **k: self.fail("keychain read with a login file"))
        self.assertEqual(found, (pwd.getpwuid(os.getuid()).pw_name, "p@ss:w/rd"))
        self.assertIn("login from", why[0])
        self.assertEqual(vnc_url.url("10.0.0.2", ("cmux", "p@ss:w/rd")), "vnc://cmux:p%40ss%3Aw%2Frd@10.0.0.2")

    def test_user_and_password_lines(self):
        self.assertEqual(vnc_url.read_file(self.write("login", "bench\nsecret\n"), "me"), ("bench", "secret"))

    def test_open_file_is_refused(self):
        why = vnc_url.read_file(self.write("login", "secret\n", 0o644), "me")
        self.assertIsInstance(why, str)
        self.assertIn("chmod 600", why)

    def test_keychain_item_then_plain_url(self):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            return Proc(0, "fleetpw\n") if len(calls) == 1 else Proc(44)
        self.assertEqual(vnc_url.keychain("cmux", str(self.dir), run), ("cmux", "fleetpw"))
        self.assertEqual(calls[0][:5], ["security", "find-generic-password", "-s", "manaflow-fleet-login", "-w"])
        why = vnc_url.keychain("cmux", str(self.dir), lambda *a, **k: Proc(44))
        self.assertIn("no manaflow-fleet-login item", why)
        self.assertEqual(vnc_url.url("10.0.0.2", None), "vnc://10.0.0.2")

    def test_cli_never_prints_the_secret_to_stderr(self):
        login = self.write("login", "topsecret\n")
        p = subprocess.run(["python3", "-I", str(EVAL / "vnc_url.py"), "10.0.0.2"], capture_output=True, text=True,
                           env={**os.environ, "CMUX_CI_VNC_LOGIN_FILE": login}, timeout=60)
        self.assertEqual(p.returncode, 0)
        self.assertTrue(p.stdout.strip().endswith(":topsecret@10.0.0.2"), p.stdout)
        self.assertNotIn("topsecret", p.stderr)
        self.assertEqual(subprocess.run(["python3", "-I", str(EVAL / "vnc_url.py"), "a@b"],
                                        capture_output=True, timeout=60).returncode, 2)

    def test_apple_connect_uses_it(self):
        text = (EVAL / "targets/apple.sh").read_text()
        self.assertIn("vnc_url.py", text)
        self.assertNotIn('open -g -n -a "$app" "vnc://$host"', text)


class ViewWhy(unittest.TestCase):
    def test_reason_reaches_err_line_without_secrets(self):
        script = (ROOT / "scripts/measure/screen-stream-eval.sh").read_text()
        body = re.search(r"^view_why\(\) \{\n.*?^\}\n", script, re.S | re.M).group(0)
        for call in ('err "window $rep failed$(view_why)"', 'err "latency $input failed$(view_why)"'):
            self.assertIn(call, script)
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "view.err").write_text("open vnc://cmux:hunter2@10.0.0.2 failed\ncmux-vnc://pair?secret\n"
                                             "apple-high: selected window is missing or ambiguous\n")
            out = subprocess.run(["bash", "-c", body + 'printf "window 1 failed%s" "$(view_why)"'],
                                 capture_output=True, text=True, env={**os.environ, "EVAL_STATE": tmp}, timeout=30).stdout
            self.assertTrue(out.startswith("window 1 failed: "), out)
            self.assertIn("selected window is missing", out)
            self.assertNotIn("hunter2", out)
            self.assertNotIn("cmux-vnc://", out)
            Path(tmp, "view.err").write_text("")
            out = subprocess.run(["bash", "-c", body + 'printf "window 1 failed%s" "$(view_why)"'],
                                 capture_output=True, text=True, env={**os.environ, "EVAL_STATE": tmp}, timeout=30).stdout
            self.assertEqual(out, "window 1 failed")


if __name__ == "__main__":
    unittest.main()
