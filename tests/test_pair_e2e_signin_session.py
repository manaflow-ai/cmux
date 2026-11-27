"""pair-e2e takes the step's agent session (`cmux-ci run --sign-in agent`) when no email and password are set.

The real-link run is the fleet's (cmux-next-ios-sim.sh pair-e2e); this covers the account pick, the
session file's checks and where the Mac's token store file goes.
"""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "cmux_next_pair_e2e", Path(__file__).resolve().parents[1] / "scripts/ci/cmux_next_pair_e2e.py")
pair = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pair)

SESSION = {"profile": "agent", "email": "agent@example.com", "project": "project-1", "refresh_token": "rt-secret"}


class SignInSessionTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.home = os.path.join(self.dir.name, "home")  # no ~/.secrets/cmuxterm-dev.env
        os.makedirs(self.home)

    def session_file(self, doc=SESSION, mode=0o600):
        path = os.path.join(self.dir.name, "signin.json")
        with open(path, "w") as f:
            json.dump(doc, f)
        os.chmod(path, mode)
        return path

    def account(self, **environ):
        env = {"HOME": self.home, **environ}
        with mock.patch.dict(os.environ, env, clear=True):
            return pair.dev_credential()

    def test_email_and_password_win_over_a_session(self):
        got = self.account(CMUX_UITEST_STACK_EMAIL="dev@example.com", CMUX_UITEST_STACK_PASSWORD="pw",
                           CMUX_CI_SIGNIN_FILE=self.session_file())
        self.assertEqual(got, {"email": "dev@example.com", "password": "pw"})

    def test_profile_file_still_works(self):
        os.makedirs(os.path.join(self.home, ".secrets"))
        with open(os.path.join(self.home, ".secrets/cmuxterm-dev.env"), "w") as f:
            f.write("CMUX_UITEST_STACK_EMAIL=dev@example.com\nCMUX_UITEST_STACK_PASSWORD=pw\n")
        self.assertEqual(self.account(), {"email": "dev@example.com", "password": "pw"})

    def test_session_when_no_password(self):
        got = self.account(CMUX_CI_SIGNIN_FILE=self.session_file())
        self.assertEqual(got, {"email": "agent@example.com", "project": "project-1", "refresh_token": "rt-secret"})

    def test_nothing_names_both_ways_in(self):
        with self.assertRaises(SystemExit) as stop:
            self.account()
        self.assertIn("CMUX_UITEST_STACK_EMAIL", str(stop.exception))
        self.assertIn("--sign-in agent", str(stop.exception))

    def test_bad_session_files_stop_without_the_token(self):
        cases = [(SESSION, 0o644), ({**SESSION, "profile": "personal"}, 0o600), ({**SESSION, "refresh_token": ""}, 0o600),
                 ({**SESSION, "email": "no-at"}, 0o600), ({**SESSION, "refresh_token": "rt\nx"}, 0o600)]
        for doc, mode in cases:
            with self.subTest(doc=doc, mode=oct(mode)), self.assertRaises(SystemExit) as stop:
                self.account(CMUX_CI_SIGNIN_FILE=self.session_file(doc, mode))
            self.assertNotIn("rt-secret", str(stop.exception))
        link = os.path.join(self.dir.name, "link.json")
        os.symlink(self.session_file(), link)
        with self.assertRaises(SystemExit):
            self.account(CMUX_CI_SIGNIN_FILE=link)


class MacTokenStoreTests(unittest.TestCase):
    def selection(self, **fields):
        doc = {"name": "dev", "bundle_id": "com.cmuxterm.app.debug.t", "stack_project_id": "project-1",
               "auth_namespace": "dev-1", "auth_storage_namespace": None, "legacy_storage": False, **fields}
        done = mock.Mock(returncode=0, stdout=json.dumps(doc), stderr="")
        return mock.patch.object(pair.subprocess, "run", return_value=done)

    def store(self, project="project-1"):
        return pair.mac_token_store("/A.app", "com.cmuxterm.app.debug.t", "/A.app/Contents/MacOS/x", {}, project, "/h")

    def test_namespaced_folder(self):
        with self.selection() as run:
            self.assertEqual(self.store(), "/h/Library/Application Support/cmux-next/com.cmuxterm.app.debug.t/dev-1/credentials.json")
        argv = run.call_args.args[0]
        self.assertEqual(argv[:5], ["/A.app/Contents/Resources/bin/cmux", "--json", "cloud", "env", "get"])
        self.assertEqual(run.call_args.kwargs["env"]["CMUX_BUNDLE_ID"], "com.cmuxterm.app.debug.t")

    def test_legacy_folder(self):
        with self.selection(legacy_storage=True):
            self.assertEqual(self.store(), "/h/Library/Application Support/cmux/com.cmuxterm.app.debug.t/credentials.json")

    def test_another_project_or_bundle_stops(self):
        with self.selection(), self.assertRaises(SystemExit):
            self.store(project="other")
        with self.selection(bundle_id="com.other"), self.assertRaises(SystemExit):
            self.store()

    def test_written_file_is_owner_only_and_read_back(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "a", "credentials.json")
            pair.write_mac_session(path, "rt-secret")
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(json.load(open(path)), {"refreshToken": "rt-secret"})
            self.assertFalse(pair.mac_session_refreshed(path))
            json.dump({"accessToken": "a", "refreshToken": "rt-secret"}, open(path, "w"))
            self.assertTrue(pair.mac_session_refreshed(path))


if __name__ == "__main__":
    unittest.main()
