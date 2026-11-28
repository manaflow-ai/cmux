#!/usr/bin/env python3
"""codex_chatgpt_import.py: the import's verdict, its daemon's environment, and what it leaves behind."""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import codex_chatgpt_import as m  # noqa: E402

GOOD = {"jsonrpc": "2.0", "id": 1, "result": {"connection": {
    "id": "chatgpt", "kind": "chatgpt-plan", "plan": "plus", "serves_cloud": True, "signed_in": True,
    "email": "ci@example.com"}}}


class FakeProc:
    def __init__(self, sock: Path | None, exit_code=None):
        self.pid, self.returncode, self.sock = 0, exit_code, sock
        if sock is not None:
            sock.touch()

    def poll(self):
        return self.returncode

    def terminate(self):
        self.returncode = 0

    def kill(self):
        self.returncode = -9

    def wait(self, timeout=None):
        self.returncode = 0 if self.returncode is None else self.returncode
        return self.returncode


def bundle(root: Path) -> Path:
    exe = m.bundled_acpmux(root / "cmux.app")
    exe.parent.mkdir(parents=True, exist_ok=True)
    exe.write_text("#!/bin/sh\n")
    exe.chmod(0o755)
    return root / "cmux.app"


class JudgeTests(unittest.TestCase):
    def test_a_cloud_serving_chatgpt_plan_connection_passes_without_its_email(self):
        conn, why = m.judge(GOOD)
        self.assertEqual((conn["kind"], conn["serves_cloud"], why), ("chatgpt-plan", True, ""))
        self.assertNotIn("email", conn)

    def test_a_refusal_names_its_reason(self):
        conn, why = m.judge({"id": 1, "error": {"message": "CI-only", "data": {"reason": "chatgpt.import_disabled"}}})
        self.assertIsNone(conn)
        self.assertIn("chatgpt.import_disabled", why)

    def test_a_connection_that_serves_no_cloud_fails(self):
        bad = {"id": 1, "result": {"connection": {"kind": "codex-login", "serves_cloud": False}}}
        conn, why = m.judge(bad)
        self.assertIsNone(conn)
        self.assertIn("serves_cloud=False", why)


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        os.chmod(self.root, 0o755)
        self.user = self.root / "user"
        self.user.mkdir()
        self.calls: list = []

    def tearDown(self):
        self.tmp.cleanup()

    def make(self, answer=GOOD, exit_code=None, no_socket=False):
        seen = {}

        def popen(argv, env=None, **kw):
            seen.update(argv=argv, env=env)
            return FakeProc(None if no_socket else Path(env["ACPMUX_SOCKET"]), exit_code)

        def call(sock, method, params):
            self.calls.append((method, params, Path(params["secret_file"]).read_text()))
            return answer

        ticks = iter(range(0, 10_000))
        imp = m.Import(popen=popen, call=call, run=lambda *a, **k: None, user_home=self.user,
                       tmp_root=str(self.root), clock=lambda: next(ticks), sleep=lambda s: None)
        return imp, seen

    def test_the_import_runs_on_a_fresh_home_with_the_switch_and_leaves_no_login_file(self):
        imp, seen = self.make()
        got = imp.prepare(bundle(self.root), '{"tokens": {}}')
        self.assertEqual(got["connection"]["kind"], "chatgpt-plan", got)
        home = Path(got["home"])
        self.assertEqual(seen["argv"][1:], ["daemon", "run"])
        self.assertEqual(seen["env"][m.SWITCH], "1")
        self.assertEqual(seen["env"]["ACPMUX_HOME"], str(home))
        self.assertFalse(any(k.startswith("CMUX_") for k in seen["env"]))
        self.assertEqual(self.calls[0][0], m.METHOD)
        self.assertEqual(self.calls[0][2], '{"tokens": {}}')
        self.assertFalse((home / "codex-auth.json").exists(), "the login file is removed after the call")
        self.assertEqual(oct(home.stat().st_mode & 0o777), "0o700")
        self.assertEqual(imp.clear(), [])
        self.assertFalse(home.exists())

    def test_no_login_or_no_bundled_acpmux_fails_before_any_daemon(self):
        imp, seen = self.make()
        self.assertEqual(imp.prepare(bundle(self.root), " ")["error_code"], "codex.import_input")
        self.assertEqual(imp.prepare(self.root / "missing.app", "{}")["error_code"], "codex.import_input")
        self.assertEqual(seen, {})

    def test_a_refused_import_fails_typed(self):
        imp, _ = self.make(answer={"id": 1, "error": {"message": "no", "data": {"reason": "wrong_client"}}})
        got = imp.prepare(bundle(self.root), "{}")
        self.assertEqual(got["error_code"], "codex.import")
        self.assertIn("wrong_client", got["error"])
        imp.clear()

    def test_a_fake_pid_of_zero_is_never_signalled_as_a_group(self):
        # os.killpg(0, ...) signals the caller's own process group: the first local run of these tests ended the shell.
        proc = FakeProc(None)
        m.Import()._stop(proc)
        self.assertEqual(proc.returncode, 0, "terminate(), not killpg(0)")

    def test_a_daemon_that_exits_or_never_binds_fails_typed(self):
        for kw in ({"exit_code": 1, "no_socket": True}, {"no_socket": True}):
            imp, _ = self.make(**kw)
            got = imp.prepare(bundle(self.root), "{}")
            self.assertEqual(got["error_code"], "codex.import_daemon", (kw, got))
            imp.clear()

    def test_clear_removes_the_route_only_when_the_run_wrote_it(self):
        route = m.route_file(self.user)
        route.parent.mkdir(parents=True)
        route.write_text("mine")
        imp, _ = self.make()
        imp.prepare(bundle(self.root), "{}")
        imp.clear()
        self.assertTrue(route.exists(), "a route the person had stays")
        route.unlink()
        imp, _ = self.make()
        imp.prepare(bundle(self.root), "{}")
        route.write_text("written by the import")
        imp.clear()
        self.assertFalse(route.exists())


if __name__ == "__main__":
    unittest.main()
