#!/usr/bin/env python3
"""Exercise the wrapper against Xcode's split outer-log/app-stdout output."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP_STDOUT = "StandardOutputAndStandardError-com.cmuxterm.app.debug.txt"
LISTENER = "SocketControlServer: Listening on /tmp/cmux-test-owned.sock\n"

# Model the two actual process boundaries: xcodebuild writes a result bundle,
# then xcresulttool exports its per-process diagnostics. Never echo diagnostic
# evidence into xcodebuild stdout, which is the bug's distinguishing condition.
TOOL = r'''import json, os, pathlib, sys, time
args = sys.argv[1:]
fixture = json.loads(os.environ["SOCKET_EVIDENCE_FIXTURE"])
if pathlib.Path(sys.argv[0]).name == "xcodebuild":
    if "-resultBundlePath" in args:
        bundle = pathlib.Path(args[args.index("-resultBundlePath") + 1])
        bundle.mkdir(parents=True, exist_ok=True)
        (bundle / "Info.plist").write_text("finalized")
        (bundle / "fixture.json").write_text(json.dumps(fixture))
    print(fixture.get("outer", "** TEST EXECUTE SUCCEEDED **"))
    sys.exit(fixture.get("status", 0))
if args[:3] == ["xcresulttool", "get", "test-results"]:
    print("{}")
    sys.exit(0)
assert args[:3] == ["xcresulttool", "export", "diagnostics"], args
bundle = pathlib.Path(args[args.index("--path") + 1])
fixture = json.loads((bundle / "fixture.json").read_text())
if fixture.get("export_hang"):
    time.sleep(30)
if fixture.get("export_failure"):
    sys.exit(1)
dest = pathlib.Path(args[args.index("--output-path") + 1])
for name, content in fixture.get("diagnostics", {}).items():
    path = dest / "0_Test_My Mac_Diagnostics" / "session" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
'''


class SocketEvidenceTests(unittest.TestCase):
    def run_wrapper(self, fixture, bundle_mode="caller", stale=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            bin_dir = root / "bin"
            bin_dir.mkdir()
            for name in ("xcodebuild", "xcrun"):
                tool = bin_dir / name
                tool.write_text(f"#!{sys.executable}\n" + TOOL)
                tool.chmod(0o755)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("CMUX_", "TEST_RUNNER_"))}
            env.update({
                "PATH": str(bin_dir) + os.pathsep + env["PATH"],
                "RUNNER_TEMP": str(root),
                "CMUX_APP_HOST_TEST_LOCK_ACTIVE": "1",
                "CMUX_APP_HOST_XCODEBUILD_ATTEMPTS": "1",
                "CMUX_APP_HOST_XCRESULTTOOL_TIMEOUT_SECONDS": "0.2",
                "SOCKET_EVIDENCE_FIXTURE": json.dumps(fixture),
            })
            args = ["bash", str(ROOT / "scripts/ci/run-app-host-xcodebuild.sh"), "test"]
            if bundle_mode == "caller":
                bundle = root / "caller.xcresult"
                args += ["-resultBundlePath", str(bundle)]
                if stale:
                    bundle.mkdir()
                    (bundle / "Info.plist").write_text("finalized")
                    (bundle / "fixture.json").write_text(json.dumps({
                        "diagnostics": {APP_STDOUT: LISTENER},
                    }))
            elif bundle_mode == "automatic":
                env["CMUX_APP_HOST_RESULT_BUNDLE_ROOT"] = str(root / "results")
            return subprocess.run(args, cwd=ROOT, env=env, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  timeout=15)

    def test_outer_listener_remains_sufficient_without_result_bundle(self):
        result = self.run_wrapper({"outer": LISTENER}, bundle_mode="none")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_xcresult_app_stdout_supplies_missing_outer_evidence(self):
        for mode in ("caller", "automatic"):
            with self.subTest(mode=mode):
                result = self.run_wrapper({"diagnostics": {APP_STDOUT: LISTENER}}, mode)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("xcresult app stdout", result.stdout)
                self.assertNotIn(LISTENER.strip(), result.stdout)

    def test_missing_evidence_fails_closed(self):
        for diagnostics in ({}, {APP_STDOUT: "Application launched\n"},
                            {"StandardOutputAndStandardError-com.cmuxterm.appuitests.xctrunner.txt": LISTENER},
                            {"unrelated.log": LISTENER}):
            with self.subTest(diagnostics=diagnostics):
                result = self.run_wrapper({"diagnostics": diagnostics})
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("socket listener evidence", result.stdout)

    def test_missing_result_bundle_fails_closed(self):
        result = self.run_wrapper({}, bundle_mode="none")
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_default_socket_in_app_stdout_is_rejected(self):
        for marker in ('SocketControlServer: Listening on /tmp/cmux-debug.sock\n',
                       'message = "socket.listener.start"; path = "/tmp/cmux-debug.sock"\n'):
            with self.subTest(marker=marker):
                result = self.run_wrapper({"diagnostics": {APP_STDOUT: LISTENER + marker}})
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("default debug socket", result.stdout)

    def test_export_errors_and_timeouts_fail_closed(self):
        for fault in ("export_failure", "export_hang"):
            with self.subTest(fault=fault):
                result = self.run_wrapper({fault: True, "diagnostics": {APP_STDOUT: LISTENER}})
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("socket listener evidence", result.stdout)

    def test_previous_bundle_cannot_supply_current_attempt_evidence(self):
        result = self.run_wrapper({}, stale=True)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Preserved caller result bundle", result.stdout)

    def test_test_failure_stays_failed_even_with_listener_evidence(self):
        result = self.run_wrapper({"status": 65, "diagnostics": {APP_STDOUT: LISTENER}})
        self.assertEqual(result.returncode, 65, result.stdout)


if __name__ == "__main__":
    unittest.main()
