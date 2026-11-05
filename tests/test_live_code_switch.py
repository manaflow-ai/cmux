#!/usr/bin/env python3
"""scripts/live-code/switch.sh: on runs the live code build in its own DerivedData and launches it
with Live Code on; off launches the tag's regular build with Live Code off.

A scratch repo holds switch.sh and stand-ins for build.sh, reload.sh and cmux-debug-cli.sh that
record how they were called, so this checks the script's path, not a real build.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

RECORD = '''#!/usr/bin/env bash
{ printf '%s' "$(basename "$0")"; printf ' %s' "$@"
  printf ' | DD=%s LIVE=%s LIST=%s\\n' "${CMUX_DERIVED_DATA:-}" "${CMUX_LIVE_CODE_BUILD:-}" \\
    "${CMUX_LIVE_CODE_INTERPOSABLE_LIST:-}"; } >> "$CALLS"
'''


class LiveCodeSwitchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.repo = self.tmp / "repo"
        (self.repo / "scripts/live-code").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/live-code/switch.sh", self.repo / "scripts/live-code/switch.sh")
        for name in ["scripts/live-code/build.sh", "scripts/reload.sh", "scripts/cmux-debug-cli.sh"]:
            path = self.repo / name
            path.write_text(RECORD)
            path.chmod(0o755)
        self.calls = self.tmp / "calls"
        self.builds = self.tmp / "builds"

    def run_switch(self, *args):
        env = dict(os.environ, CALLS=str(self.calls), HOME=str(self.tmp), CMUX_LIVE_CODE_BUILDS=str(self.builds),
                   CMUX_DERIVED_DATA="/caller/dd")
        return subprocess.run(["bash", str(self.repo / "scripts/live-code/switch.sh"), *args], env=env,
                              capture_output=True, text=True)

    def recorded(self):
        return self.calls.read_text().splitlines()

    def test_on_builds_live_code_apart_and_launches_it(self):
        result = self.run_switch("on", "t1")
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.builds / "t1"
        calls = self.recorded()
        self.assertEqual(calls[0].split(" | ")[0], "cmux-debug-cli.sh settings set labs.liveCode true")
        self.assertEqual(calls[1].split(" | ")[0], f"build.sh {out} t1 debug CMUX_DERIVED_DATA={out}/DerivedData")
        self.assertEqual(calls[2], f"reload.sh --tag t1 --config debug --launch | DD={out}/DerivedData LIVE=1 "
                                   f"LIST={out}/interposable.txt")
        self.assertIn(f"--log {out}/xcodebuild.log", result.stdout)

    def test_on_with_no_app_running_sets_live_code_on_the_new_one(self):
        cli = self.repo / "scripts/cmux-debug-cli.sh"
        # The first call finds no app; the launch below starts one.
        cli.write_text(RECORD + '[[ -e "$CALLS.app" ]] || { touch "$CALLS.app"; exit 1; }\n')
        result = self.run_switch("on", "t1")
        self.assertEqual(result.returncode, 0, result.stderr)
        names = [line.split(" | ")[0].split(" ")[0] for line in self.recorded()]
        self.assertEqual(names, ["cmux-debug-cli.sh", "build.sh", "reload.sh", "cmux-debug-cli.sh", "reload.sh"])

    def test_off_with_no_app_running_still_launches(self):
        cli = self.repo / "scripts/cmux-debug-cli.sh"
        cli.write_text(RECORD + "exit 1\n")
        result = self.run_switch("off", "t1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded()[-1].split(" | ")[0], "reload.sh --tag t1 --config debug --launch")

    def test_off_launches_the_regular_build(self):
        result = self.run_switch("off", "t1")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.recorded()
        self.assertEqual(calls[0].split(" | ")[0], "cmux-debug-cli.sh settings set labs.liveCode false")
        # The tag's own DerivedData, even when the caller's shell names another one.
        self.assertEqual(calls[1], "reload.sh --tag t1 --config debug --launch | DD= LIVE= LIST=")
        self.assertEqual(len(calls), 2)

    def test_status_and_usage(self):
        result = self.run_switch("status", "t1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("live code build: none yet", result.stdout)
        self.assertEqual(self.run_switch("toggle").returncode, 2)
        self.assertEqual(self.run_switch("on", "bad tag").returncode, 2)


if __name__ == "__main__":
    unittest.main()
