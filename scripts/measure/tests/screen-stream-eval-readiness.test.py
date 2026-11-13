#!/usr/bin/env python3
"""Exercise the Apple target's real dispatch with isolated platform/observer fakes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


APPLE = Path(__file__).resolve().parents[1] / "screen-stream-eval/targets/apple.sh"
NONCE = "00112233445566778899aabbccddeeff"


class AppleReadinessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="screen-readiness-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.go = self.root / "go"
        self.raw = self.root / "window.raw"
        observer = self.root / "cmux-rd"
        observer.write_text("#!/usr/bin/env python3\n"
                            "import os,sys\n"
                            "print(os.environ['READY_RECEIPT'])\n"
                            "sys.exit(int(os.environ.get('OBSERVER_STATUS','0')))\n")
        observer.chmod(0o755)
        prefix, dispatch = APPLE.read_text().split('case "$verb" in', 1)
        self.script = prefix + '''
connect() { window_id=42; viewer_pid=7; return "${PROFILE_STATUS:-0}"; }
''' + 'case "$verb" in' + dispatch
        self.env = {**os.environ, "EVAL_STATE": str(self.root), "EVAL_BIN": str(self.root),
                    "EVAL_PEER": "192.0.2.1", "EVAL_SCENE_NONCE": NONCE,
                    "EVAL_PRESENTED_OBSERVER_BIN": str(observer),
                    "EVAL_PRESENTED_OBSERVER_PID": "7", "EVAL_PRESENTED_OBSERVER_WINDOW": "42",
                    "EVAL_PRESENTED_MARKER_ORIGIN": "0,0", "EVAL_PRESENTED_CELL_SIZE": "8",
                    "READY_RECEIPT": json.dumps({"complete": True, "host_identity_verified": True,
                                                "nonce_observed": True, "expected_nonce": "f" * 32})}

    def run_window(self, **env):
        return subprocess.run(["bash", "-c", self.script, "apple.sh", "window-view", "0",
                               str(self.root / "snapshot"), str(self.go), str(self.raw)],
                              env={**self.env, **env}, text=True, capture_output=True, timeout=10)

    def assert_refused(self, result):
        self.assertFalse(self.go.exists(), "a failed readiness check must never start the source workload")
        self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_wrong_nonce_does_not_start_scene(self):
        self.assert_refused(self.run_window())

    def test_missing_expected_nonce_does_not_start_scene(self):
        self.assert_refused(self.run_window(EVAL_SCENE_NONCE=""))

    def test_observer_failure_does_not_start_scene(self):
        self.assert_refused(self.run_window(OBSERVER_STATUS="2"))

    def test_failed_quality_selection_does_not_start_scene(self):
        self.assert_refused(self.run_window(PROFILE_STATUS="1"))


if __name__ == "__main__":
    unittest.main()
