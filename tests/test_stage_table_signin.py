"""stage-table.sh signs its DEV apps in from the step's agent session (`cmux-ci run --sign-in agent`).

scripts/measure/screen-stream-eval/stage-signin.py writes the session's refresh token into the app's own token
store (the store cmux_next_pair_e2e.py writes for its Mac app) and an empty 0600 CMUX_AUTH_CREDENTIALS_FILE; the
Mac pair run itself is the fleet's (screen-stream-eval.sh pair). Runs on Linux: the app's bundled `cmux` is mocked.
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "stage_signin", ROOT / "scripts/measure/screen-stream-eval/stage-signin.py")
signin = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signin)

SESSION = {"profile": "agent", "email": "agent@example.com", "project": "project-1", "refresh_token": "rt-secret"}
BUNDLE = "com.cmuxterm.next.debug.stagetable"


class StageSignInTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.home = os.path.join(self.dir.name, "home")
        os.makedirs(self.home)
        self.app = os.path.join(self.dir.name, "cmux NEXT DEV stagetable.app")
        os.makedirs(os.path.join(self.app, "Contents/MacOS"))
        with open(os.path.join(self.app, "Contents/Info.plist"), "wb") as f:
            plistlib.dump({"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "cmux NEXT"}, f)
        self.out = os.path.join(self.dir.name, "out", ".signin-host.env")
        os.makedirs(os.path.dirname(self.out))

    def session_file(self, doc=SESSION, mode=0o600):
        path = os.path.join(self.dir.name, "signin.json")
        with open(path, "w") as f:
            json.dump(doc, f)
        os.chmod(path, mode)
        return path

    def run_helper(self, environ, project="project-1"):
        selection = {"name": "dev", "bundle_id": BUNDLE, "stack_project_id": project, "auth_namespace": "dev-1",
                     "auth_storage_namespace": None, "legacy_storage": False}
        ran = mock.Mock(returncode=0, stdout=json.dumps(selection), stderr="")
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {"HOME": self.home, **environ}, clear=True), \
                mock.patch.object(signin.e2e.subprocess, "run", return_value=ran) as run, \
                mock.patch.object(signin.pwd, "getpwuid", return_value=mock.Mock(pw_dir=self.home)), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = signin.main(["stage-signin.py", "store", self.app, self.out])
        return code, stdout.getvalue(), stderr.getvalue(), run

    def test_session_goes_to_the_apps_token_store(self):
        code, stdout, stderr, run = self.run_helper({"CMUX_CI_SIGNIN_FILE": self.session_file()})
        self.assertEqual(code, 0, stderr)
        store = os.path.join(self.home, "Library/Application Support/cmux-next", BUNDLE, "dev-1/credentials.json")
        self.assertEqual(stdout.strip(), store)
        with open(store) as f:
            self.assertEqual(json.load(f), {"refreshToken": "rt-secret"})
        self.assertEqual(stat.S_IMODE(os.stat(store).st_mode), 0o600)
        # The app signs in from the store: its CMUX_AUTH_CREDENTIALS_FILE is empty and private.
        self.assertEqual(os.path.getsize(self.out), 0)
        self.assertEqual(stat.S_IMODE(os.stat(self.out).st_mode), 0o600)
        # The app's own Cloud selection, asked with the app's executable and without the session file.
        argv, kwargs = run.call_args.args[0], run.call_args.kwargs
        self.assertEqual(argv[0], os.path.join(self.app, "Contents/Resources/bin/cmux"))
        self.assertEqual(json.loads(argv[-1]), [os.path.join(self.app, "Contents/MacOS/cmux NEXT")])
        self.assertEqual(kwargs["env"]["CMUX_BUNDLE_ID"], BUNDLE)
        self.assertNotIn("CMUX_CI_SIGNIN_FILE", kwargs["env"])
        # The token is in no argv, environment or output.
        self.assertNotIn("rt-secret", json.dumps(argv) + json.dumps(kwargs["env"]) + stdout + stderr)

    def test_no_session_says_how_to_send_one(self):
        code, stdout, stderr, _ = self.run_helper({})
        self.assertEqual(code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("cmux-ci run --sign-in agent", stderr)
        self.assertFalse(os.path.exists(self.out))

    def test_a_bad_session_file_stops_with_its_reason(self):
        code, _, stderr, _ = self.run_helper({"CMUX_CI_SIGNIN_FILE": self.session_file(mode=0o644)})
        self.assertEqual(code, 1)
        self.assertIn("mode 0600", stderr)
        doc = dict(SESSION, profile="person")
        code, _, stderr, _ = self.run_helper({"CMUX_CI_SIGNIN_FILE": self.session_file(doc=doc)})
        self.assertEqual(code, 1)
        self.assertIn("not an agent session", stderr)
        self.assertNotIn("rt-secret", stderr)

    def test_another_projects_session_is_refused(self):
        code, _, stderr, _ = self.run_helper({"CMUX_CI_SIGNIN_FILE": self.session_file()}, project="project-2")
        self.assertEqual(code, 1)
        self.assertIn("another Stack project", stderr)
        self.assertFalse(os.path.exists(os.path.join(self.home, "Library")))


if __name__ == "__main__":
    unittest.main()
