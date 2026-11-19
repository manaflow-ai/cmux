#!/usr/bin/env python3
"""scripts/ci/fresh_home_launch_smoke.py `login_keychain`: the private home a harness launches a nightly with gets
its own login keychain, so Chromium's "cmux Safe Storage" never waits on a Keychain dialog (cmuxterm-hq#11994: every
quit of post-update-hitches.py held in CefShutdown behind one).

No Mac, no `security`: `subprocess.run` is replaced by a recorder. So this proves the calls the helper makes (scoped
to the private home, create only when the keychain is missing, a failure is CannotRun), NOT what `security` does on a
Mac and NOT that Chromium then skips the dialog.
Run: python3 -I scripts/measure/tests/fresh-home-login-keychain.test.py"""
import os, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "ci"))
import fresh_home_launch_smoke as M  # noqa: E402  (by name, as the harnesses import it: one module object)


class LoginKeychain(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="login-keychain-test-"))
        self.env = M.fresh_env(self.root, self.root / "s.sock", 0)
        self.calls = []

    def run_ok(self, argv, env=None, **_):
        self.calls.append((argv, env))
        return subprocess.CompletedProcess(argv, 0, "", "")

    def test_new_home_creates_then_makes_it_the_default(self):
        with mock.patch.object(M.subprocess, "run", self.run_ok), mock.patch.object(M, "log"):
            M.login_keychain(self.env)
        keychain = str(self.root / "h/Library/Keychains/login.keychain-db")
        self.assertEqual([argv[1] for argv, _ in self.calls],
                         ["create-keychain", "list-keychains", "default-keychain", "set-keychain-settings"])
        self.assertTrue(all(argv[0] == "security" and argv[-1] == keychain for argv, _ in self.calls))
        for _, env in self.calls:  # the private home's search list, never the runner account's
            self.assertEqual(env["HOME"], self.env["HOME"])
            self.assertEqual(env["CFFIXED_USER_HOME"], self.env["HOME"])
            self.assertFalse(any(k.startswith("CMUX") for k in env))

    def test_existing_keychain_is_kept(self):
        keychain = self.root / "h/Library/Keychains/login.keychain-db"
        keychain.parent.mkdir(parents=True)
        keychain.write_bytes(b"kept")
        with mock.patch.object(M.subprocess, "run", self.run_ok), mock.patch.object(M, "log"):
            M.login_keychain(self.env)
        self.assertNotIn("create-keychain", [argv[1] for argv, _ in self.calls])
        self.assertEqual(keychain.read_bytes(), b"kept")

    def test_a_failed_step_is_cannot_run(self):
        def fail(argv, **_):
            return subprocess.CompletedProcess(argv, 1, "", "no access")
        with mock.patch.object(M.subprocess, "run", fail), mock.patch.object(M, "log"):
            with self.assertRaisesRegex(M.CannotRun, "create-keychain.*no access"):
                M.login_keychain(self.env)


if __name__ == "__main__":
    sys.exit(unittest.main())
