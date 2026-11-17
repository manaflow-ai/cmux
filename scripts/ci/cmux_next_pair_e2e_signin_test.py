"""cmux_next_pair_e2e.py's account: the DEBUG dev email and password when the step has them, else the
step's own agent session ($CMUX_CI_SIGNIN_FILE, `cmux-ci run --sign-in agent`), whose refresh token
reaches the phone only in its simctl launch environment and the Mac only in a 0600 credentials file,
never an argv or a log line. Linux-runnable: nothing here starts a simulator or an app.

  python3 -m unittest scripts/ci/cmux_next_pair_e2e_signin_test.py
"""
import contextlib
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmux_next_pair_e2e as e2e  # noqa: E402

TOKEN = "rt-step-session-0123456789abcdef"
SESSION = {"profile": "agent", "email": "agent@example.com", "project": "dev-project", "refresh_token": TOKEN}


class AccountTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(self._cleanup)
        # An empty HOME: no ~/.secrets/cmuxterm-dev.env on the machine running the test is read.
        self.env = {"HOME": self.dir, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}

    def _cleanup(self):
        for root, dirs, files in os.walk(self.dir, topdown=False):
            for name in files:
                os.unlink(os.path.join(root, name))
            for name in dirs:
                os.rmdir(os.path.join(root, name))
        os.rmdir(self.dir)

    def session_file(self, body=SESSION, mode=0o600):
        path = os.path.join(self.dir, "signin.json")
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            json.dump(body, f)
        os.chmod(path, mode)
        return path

    def account(self, **env):
        with mock.patch.dict(os.environ, dict(self.env, **env), clear=True):
            return e2e.launch_account()

    def refusal(self, **env):
        with mock.patch.dict(os.environ, dict(self.env, **env), clear=True):
            with self.assertRaises(SystemExit) as raised:
                e2e.launch_account()
        return str(raised.exception.code)

    def test_email_and_password_win_over_a_session(self):
        account = self.account(CMUX_UITEST_STACK_EMAIL="dev@example.com", CMUX_UITEST_STACK_PASSWORD="pw",
                               CMUX_CI_SIGNIN_FILE=self.session_file())
        self.assertEqual((account.kind, account.email, account.secret), ("password", "dev@example.com", "pw"))

    def test_the_step_session_signs_in_when_there_is_no_password(self):
        account = self.account(CMUX_CI_SIGNIN_FILE=self.session_file())
        self.assertEqual((account.kind, account.email, account.secret), ("session", "agent@example.com", TOKEN))
        self.assertNotIn(TOKEN, repr(account))  # a traceback or a stray print never shows it

    def test_neither_names_both_ways(self):
        why = self.refusal()
        self.assertIn("CMUX_UITEST_STACK_EMAIL", why)
        self.assertIn("--sign-in agent", why)

    def test_a_session_file_others_can_read_or_of_another_profile_is_refused_without_its_token(self):
        for path in (self.session_file(mode=0o644), self.session_file(dict(SESSION, profile="personal")),
                     self.session_file(dict(SESSION, refresh_token=""))):
            why = self.refusal(CMUX_CI_SIGNIN_FILE=path)
            self.assertIn("sign-in session", why)
            self.assertNotIn(TOKEN, why)
        link = os.path.join(self.dir, "link.json")
        os.symlink(self.session_file(), link)
        self.assertIn("not a regular file", self.refusal(CMUX_CI_SIGNIN_FILE=link))

    def test_the_phone_gets_the_session_in_its_launch_environment_only(self):
        session = self.account(CMUX_CI_SIGNIN_FILE=self.session_file())
        env = e2e.account_phone_env(session, {"PATH": "/bin"})
        self.assertEqual(env["SIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN"], TOKEN)
        self.assertNotIn("SIMCTL_CHILD_CMUX_MOBILE_STACK_PASSWORD", env)
        password = self.account(CMUX_UITEST_STACK_EMAIL="dev@example.com", CMUX_UITEST_STACK_PASSWORD="pw")
        env = e2e.account_phone_env(password, {"PATH": "/bin"})
        self.assertEqual((env["SIMCTL_CHILD_CMUX_MOBILE_STACK_EMAIL"], env["SIMCTL_CHILD_CMUX_MOBILE_STACK_PASSWORD"]),
                         ("dev@example.com", "pw"))
        self.assertNotIn("SIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN", env)

    def test_the_mac_gets_the_session_in_a_0600_credentials_file(self):
        session = self.account(CMUX_CI_SIGNIN_FILE=self.session_file())
        creds = os.path.join(self.dir, "dev-auth.env")
        e2e.write_credentials(creds, session)
        self.assertEqual(stat.S_IMODE(os.stat(creds).st_mode), 0o600)
        self.assertEqual(open(creds).read(), f"CMUX_UITEST_STACK_REFRESH_TOKEN={TOKEN}\n")
        password = self.account(CMUX_UITEST_STACK_EMAIL="dev@example.com", CMUX_UITEST_STACK_PASSWORD="pw")
        e2e.write_credentials(creds, password)
        self.assertEqual(open(creds).read(), "CMUX_UITEST_STACK_EMAIL=dev@example.com\nCMUX_UITEST_STACK_PASSWORD=pw\n")

    def test_the_token_never_reaches_an_argv_or_the_output(self):
        session = self.account(CMUX_CI_SIGNIN_FILE=self.session_file())
        calls = []

        def run(argv, **kwargs):
            calls.append((list(argv), kwargs))
            return mock.Mock(returncode=0, stdout="", stderr="")

        out = io.StringIO()
        with mock.patch.object(e2e.subprocess, "run", run), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(out):
            e2e.launch_phone(["xcrun", "simctl", "--set", "/sims"], "UDID-1", "dev.cmux.mobile.tag",
                             e2e.account_phone_env(session, {"PATH": "/bin"}), "-cmux-mobile-settings-page", "devices")
            e2e.launch_account_note(session, print)
        self.assertEqual(len(calls), 1)
        argv, kwargs = calls[0]
        self.assertEqual(argv, ["xcrun", "simctl", "--set", "/sims", "launch", "UDID-1", "dev.cmux.mobile.tag",
                                "-cmux-mobile-settings-page", "devices"])
        self.assertTrue(all(TOKEN not in arg for arg in argv))
        self.assertEqual(kwargs["env"]["SIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN"], TOKEN)
        self.assertTrue(kwargs.get("capture_output"))
        self.assertIn("--sign-in", out.getvalue())
        self.assertNotIn(TOKEN, out.getvalue())


if __name__ == "__main__":
    unittest.main()
