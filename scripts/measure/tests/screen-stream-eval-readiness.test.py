#!/usr/bin/env python3
"""Exercise the Apple target's real dispatch with isolated platform/observer fakes."""
import json
import base64
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
from urllib.parse import urlsplit


APPLE = Path(__file__).resolve().parents[1] / "screen-stream-eval/targets/apple.sh"
NONCE = "00112233445566778899aabbccddeeff"
VALID_RECEIPT = {"schema": "cmux.presented-marker-series/2", "complete": True,
                 "host_identity_verified": True, "nonce_observed": True,
                 "expected_nonce": NONCE, "pid": 7, "window": 42,
                 "first_changed_marker_ms": 100.0, "session_ttff_ms": None}
spec = importlib.util.spec_from_file_location("screen_eval_peer", APPLE.parent.parent / "peer.py")
peer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(peer)


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

    def test_valid_fresh_nonce_starts_scene_and_preserves_receipt(self):
        result = self.run_window(READY_RECEIPT=json.dumps(VALID_RECEIPT))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.go.exists())
        report = json.loads(self.raw.read_text())
        self.assertIsNone(report["extra"]["first_frame_ms"])
        self.assertEqual(report["extra"]["readiness"]["requested_host"], "192.0.2.1")
        self.assertEqual(report["extra"]["readiness"]["observer"], VALID_RECEIPT)

    def test_unverified_incomplete_wrong_window_or_frozen_capture_refused(self):
        for key, value in (("complete", False), ("host_identity_verified", False),
                           ("nonce_observed", False), ("expected_nonce", "f" * 32),
                           ("schema", "cmux.presented-marker-series/1"), ("pid", 8), ("window", 43),
                           ("first_changed_marker_ms", None), ("first_changed_marker_ms", float("nan"))):
            with self.subTest(key=key, value=value):
                self.go.touch()  # A previous repeat's GO cannot survive a refusal.
                self.assert_refused(self.run_window(READY_RECEIPT=json.dumps({**VALID_RECEIPT, key: value})))


class PeerNonceTests(unittest.TestCase):
    def test_host_command_carries_fresh_nonce_and_returns_readiness_receipt(self):
        with tempfile.TemporaryDirectory(prefix="screen-peer-host-") as directory:
            root = Path(directory)
            raw = root / "window.raw"
            commands = []
            original_put = peer.put

            def answer(path, command):
                commands.append(command)
                original_put(path, command)
                (root / f"result-{command['id']}.json").write_text(json.dumps({"exit": 0, "files": {
                    "raw": base64.b64encode(b"{}").decode(),
                    "readiness": base64.b64encode(json.dumps(VALID_RECEIPT).encode()).decode()}}))

            with mock.patch.dict(os.environ, {"EVAL_SCENE_NONCE": NONCE}), mock.patch.object(peer, "put", side_effect=answer):
                self.assertEqual(peer.call(root, "apple-high", "window-view", ["1", str(root / "frame"), str(root / "go"), str(raw)]), 0)
            self.assertEqual(commands[0]["env"]["EVAL_SCENE_NONCE"], NONCE)
            self.assertEqual(json.loads(Path(f"{raw}.readiness.json").read_text()), VALID_RECEIPT)

    def test_viewer_clears_ambient_nonce_and_rejects_invalid_command_nonce(self):
        with tempfile.TemporaryDirectory(prefix="screen-peer-viewer-") as directory:
            root = Path(directory)
            target = root / "scripts/measure/screen-stream-eval/targets/apple-high.sh"
            target.parent.mkdir(parents=True)
            target.write_text('printf \'{"nonce":"%s"}\' "$EVAL_SCENE_NONCE" >"$5"\ntouch "$4"\n')
            commands = iter([
                {"id": 1, "target": "apple-high", "verb": "window-view", "args": ["0"], "env": {"EVAL_SCENE_NONCE": NONCE}},
                {"id": 2, "target": "apple-high", "verb": "window-view", "args": ["0"], "env": {}},
                {"id": 3, "target": "apple-high", "verb": "window-view", "args": ["0"], "env": {"EVAL_SCENE_NONCE": 0}},
                {"id": 4, "verb": "done"},
            ])
            results = {}

            class Response:
                status = 200
                def __init__(self, body): self.body = body
                def __enter__(self): return self
                def __exit__(self, *args): return False
                def read(self): return json.dumps(self.body).encode()

            def respond(request, **kwargs):
                path = urlsplit(request.full_url).path
                if path == "/clock": return Response(peer.clocks())
                if path == "/next": return Response(next(commands))
                if path.startswith("/result/"):
                    results[int(path.split("/")[-1])] = json.loads(request.data)
                return Response({})

            with mock.patch.dict(os.environ, {"EVAL_SCENE_NONCE": "ambient-stale-nonce"}), mock.patch.object(peer.urllib.request, "urlopen", side_effect=respond):
                self.assertEqual(peer.agent("127.0.0.1", 1, "fixture-token", root), 0)
            self.assertEqual(json.loads(base64.b64decode(results[1]["files"]["raw"])), {"nonce": NONCE})
            self.assertEqual(json.loads(base64.b64decode(results[2]["files"]["raw"])), {"nonce": ""})
            self.assertEqual(results[3]["exit"], 2)


if __name__ == "__main__":
    unittest.main()
