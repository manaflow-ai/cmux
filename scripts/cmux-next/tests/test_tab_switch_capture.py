"""tab_switch_capture.py's preflight against fake cua-drivers, and tab-switch.sh's order: the check runs before the build.

2026-11-16: of 57 finished pull request steps of the tab switch check, the ones on three display Macs
built the app for most of an hour, then died with "cua-driver mcp closed during initialize" and no reason; the ones on
two others never built, because fetching the head also fetched ghostty ("upload-pack: not our ref")."""
import io
import os
import re
import shutil
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import tab_switch_capture as cap  # noqa: E402

FOLDERS = []  # every fake driver's folder, removed when the module's tests end


def tearDownModule():
    for folder in FOLDERS:
        shutil.rmtree(folder, ignore_errors=True)


ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

# A fake `cua-driver mcp`: answers initialize and check_permissions with GRANT, or dies at once with WORDS on stderr.
FAKE = """#!/usr/bin/env python3
import json, sys
if MODE == "die":
    sys.stderr.write("dyld: Library not loaded: @rpath/CuaDriverCore.framework\\n")
    sys.exit(6)
for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message:
        continue
    if message["method"] == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {}}
    else:
        result = {"structuredContent": {"screen_recording": GRANT, "accessibility": True}}
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
"""


def fake_driver(mode, grant=True):
    folder = tempfile.mkdtemp(prefix="tsw-cua-")
    FOLDERS.append(folder)
    path = os.path.join(folder, "cua-driver")
    with open(path, "w") as f:
        f.write(FAKE.replace("MODE", repr(mode)).replace("GRANT", repr(grant)))
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path


class Preflight(unittest.TestCase):
    def test_a_driver_that_dies_says_why(self):
        with self.assertRaises(cap.CaptureError) as caught:
            cap.preflight(fake_driver("die"))
        words = str(caught.exception)
        self.assertIn("closed during initialize", words)
        self.assertIn("Library not loaded", words)
        self.assertIn("exit 6", words)

    def test_no_screen_recording_grant(self):
        with self.assertRaisesRegex(cap.CaptureError, "no Screen Recording grant"):
            cap.preflight(fake_driver("answer", grant=False))

    def test_a_granted_driver_is_ready(self):
        self.assertEqual(cap.preflight(fake_driver("answer"))["screen_recording"], True)

    def test_main_exits_3_when_it_cannot_record(self):
        driver = fake_driver("die")
        saved = cap.CUA_DRIVER
        cap.preflight.__defaults__ = (driver,)
        try:
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(cap.main(["tab_switch_capture.py", "preflight"]), 3)
            self.assertTrue(out.getvalue().startswith("TSW cannot record: "))
        finally:
            cap.preflight.__defaults__ = (saved,)

    def test_the_driver_gets_the_accounts_home_not_the_steps(self):
        # A fleet step's HOME is <job>/home: cua-driver looks for its daemon's socket under HOME and exits without it.
        import pwd
        real = pwd.getpwuid(os.getuid()).pw_dir
        env = cap.driver_env({"HOME": "/tmp/job/home", "CFFIXED_USER_HOME": "/tmp/job/home", "PATH": "/usr/bin"})
        self.assertEqual(env["HOME"], real)
        self.assertNotIn("CFFIXED_USER_HOME", env)
        self.assertEqual(env["PATH"], "/usr/bin")
        driver = fake_driver("answer")
        with open(driver) as f:
            body = f.read()
        with open(driver, "w") as f:  # this fake dies the way cua-driver does under a step's HOME
            f.write(body.replace("import json, sys\n", "import json, os, pwd, sys\n"
                                 "if os.environ.get('HOME') != pwd.getpwuid(os.getuid()).pw_dir:\n"
                                 "    sys.stderr.write('daemon did not appear on cua-driver.sock within 10s\\n')\n"
                                 "    sys.exit(1)\n", 1))
        saved = os.environ.get("HOME")
        os.environ["HOME"] = tempfile.mkdtemp(prefix="tsw-step-home-")
        FOLDERS.append(os.environ["HOME"])
        try:
            self.assertEqual(cap.preflight(driver)["screen_recording"], True)
        finally:
            os.environ["HOME"] = saved if saved is not None else real

    def test_no_driver_at_all(self):
        with self.assertRaisesRegex(cap.CaptureError, "no CuaDriver"):
            cap.preflight("/nonexistent/cua-driver")


class TabSwitchScript(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(ROOT, "scripts", "measure", "tab-switch.sh")) as f:
            self.text = f.read()

    def test_the_recorder_check_runs_before_the_tools_compile_and_the_build(self):
        check = self.text.index("tab_switch_capture.py\" preflight || exit 3")
        self.assertLess(check, self.text.index("swiftc -O -o \"$tmp/tab-switch-tools\""))
        # The build is in the function app_under_test (#45101), which the script calls with the tag `tabswitch`.
        call = self.text.index('app_under_test "$build" "$config" "$dmg" "$tmp" "$root" tabswitch')
        self.assertLess(check, call)
        # app_under_test runs the build as a bounded step (#47805): tsw_build_app, which runs reload.sh with that tag.
        start = self.text.index("app_under_test() {")
        self.assertIn('tsw_build_app "$src" "$tmp" "$tag"', self.text[start:self.text.index("\n}\n", start)])
        start = self.text.index("tsw_build_app() {")
        self.assertIn('./scripts/reload.sh --tag "$tag"', self.text[start:self.text.index("\n}\n", start)])

    def test_the_head_fetch_and_worktree_never_recurse_into_submodules(self):
        fetch = re.search(r"git (.*)fetch (.*)https://github.com/manaflow-ai/cmux.git", self.text)
        self.assertIsNotNone(fetch)
        self.assertIn("-c submodule.recurse=false", fetch.group(1))
        self.assertIn("--no-recurse-submodules", fetch.group(2))
        self.assertIn("git -c submodule.recurse=false worktree add", self.text)


if __name__ == "__main__":
    unittest.main()
