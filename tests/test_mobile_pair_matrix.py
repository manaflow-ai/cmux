#!/usr/bin/env python3
"""Terminal receipts must identify failed and unexecuted compatibility cells."""
import importlib.util
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import socket
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mobile_pair_matrix", ROOT / "scripts/ci/mobile_pair_matrix.py")
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)
result_spec = importlib.util.spec_from_file_location("mobile_pair_result", ROOT / "scripts/ci/mobile_pair_result.py")
pair_result = importlib.util.module_from_spec(result_spec)
result_spec.loader.exec_module(pair_result)
fixture_spec = importlib.util.spec_from_file_location("git_fixture_env", ROOT / "tests/git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(fixture_spec)
fixture_spec.loader.exec_module(git_fixture_env)


class BinaryCacheProvenance(unittest.TestCase):
    def exercise(self, *, mutation="", stale=False, require_locked=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            repo.mkdir()
            git_fixture_env.init_repo(repo)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            git("config", "core.hooksPath", "/dev/null")
            rust = repo / "cmux-next-ios/rust"
            rust.mkdir(parents=True)
            (rust / "Cargo.lock").write_text("version = 3\n")
            (rust / "source.rs").write_text("// committed source\n")
            git("add", ".")
            git("commit", "-qm", "fixture")
            sha = git("rev-parse", "HEAD")
            tools = root / "tools"
            tools.mkdir()
            (tools / "rustc").write_text("#!/bin/sh\nprintf 'fixture compiler\\n'\n")
            (tools / "cargo").write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
with (root / "builds").open("a") as log: log.write(" ".join(sys.argv[1:]) + "\\n")
if os.environ["REQUIRE_LOCKED"] == "1" and "--locked" not in sys.argv: sys.exit(47)
mutation = os.environ["MUTATION"]
if mutation:
    pathlib.Path("source.rs" if mutation == "source" else "Cargo.lock").write_text("changed\\n")
    if mutation == "commit":
        subprocess.run(["git", "add", "Cargo.lock"], check=True)
        subprocess.run(["git", "commit", "-qm", "changed head"], check=True)
target = pathlib.Path(os.environ["CARGO_TARGET_DIR"]) / "release"
target.mkdir(exist_ok=True)
for name in ("cmux-mobile-host", "cmux-mobile-stub-tui", "cmux-mobile-dial", "cmux-mobile-fake-backend"):
    binary = target / name
    binary.write_text("#!/bin/sh\\nexit 0\\n")
    binary.chmod(0o755)
''')
            for tool in tools.iterdir():
                tool.chmod(0o755)
            cache = root / "cache"
            cache.mkdir()
            if stale:
                platform = subprocess.check_output(["uname", "-sm"], text=True).strip()
                key = hashlib.sha256(("\n".join(["pair-binaries-v1", sha, "host", "fixture compiler", platform]) + "\n").encode()).hexdigest()
                entry = cache / key
                entry.mkdir()
                (entry / "complete").write_text(sha + " host\n")
                for name in ("cmux-mobile-host", "cmux-mobile-stub-tui"):
                    (entry / name).write_text("#!/bin/sh\nexit 0\n")
                    (entry / name).chmod(0o755)
            work = root / "work"
            (work / "bin").mkdir(parents=True)
            function = (ROOT / "scripts/ci/mobile-pair-skew.sh").read_text().split(
                "build_role() {", 1)[1].split('\nbuild_role "$old" host', 1)[0]
            env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                   "FIXTURE_ROOT": str(root), "MUTATION": mutation,
                   "REQUIRE_LOCKED": "1" if require_locked else "0", "tree": str(repo),
                   "work": str(work), "target": str(root / "target"), "SKEW_BINARY_CACHE_DIR": str(cache)}
            result = subprocess.run(["bash", "-c", "set -euo pipefail\nbuild_role() {" + function +
                                     '\nbuild_role "$tree" host\nbuild_role "$tree" host\n'],
                                    env=env, text=True, capture_output=True, timeout=90)
            return result, list(cache.glob("*/complete")), (root / "builds").read_text().splitlines() if (root / "builds").exists() else []

    def test_locked_clean_build_publishes_once_and_reuses_cache(self):
        result, complete, builds = self.exercise(require_locked=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(complete), 1)
        self.assertEqual(len(builds), 1)
        self.assertIn("--locked", builds[0])

    def test_changed_lock_source_or_head_cannot_publish(self):
        for mutation in ("lock", "source", "commit"):
            with self.subTest(mutation=mutation):
                result, complete, builds = self.exercise(mutation=mutation)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(complete)
                self.assertEqual(len(builds), 1)

    def test_old_unlocked_cache_is_not_reused(self):
        result, complete, builds = self.exercise(stale=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(builds), 1)
        self.assertEqual(len(complete), 2)


class MatrixReceipts(unittest.TestCase):
    def test_pair_fixture_readiness_authenticates_both_ice_requests(self):
        requests = []
        class AuthenticatedIce(BaseHTTPRequestHandler):
            def do_GET(self):
                authorized = self.headers.get("Authorization") == "Bearer user:u1"
                requests.append((self.path, authorized))
                self.send_response(200 if authorized else 401)
                self.end_headers()

            def log_message(self, *_args):
                pass

        script = (ROOT / "scripts/ci/mobile-pair-skew.sh").read_text()
        readiness = script.split("for _ in $(seq 50); do\n", 1)[1].split(
            "CMUX_MOBILE_BASE_URL=$url", 1)[0]
        with tempfile.TemporaryDirectory() as directory, \
             socket.socket(socket.AF_UNIX) as daemon, \
             ThreadingHTTPServer(("127.0.0.1", 0), AuthenticatedIce) as backend:
            tui = Path(directory) / "tui"
            tui.mkdir()
            daemon.bind(str(tui / "main.sock"))
            thread = threading.Thread(target=backend.serve_forever, daemon=True)
            thread.start()
            try:
                result = subprocess.run(
                    ["bash", "-c", "set -euo pipefail\nfor _ in $(seq 50); do\n" + readiness],
                    env={**os.environ, "work": directory,
                         "url": f"http://127.0.0.1:{backend.server_port}"},
                    capture_output=True, text=True, timeout=15)
            finally:
                backend.shutdown()
                thread.join(timeout=2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(requests, [("/v1/ice", True), ("/v1/ice", True)])

    def test_assertion_verdict_requires_complete_parseable_transport_results(self):
        good = [json.dumps({"transport": t, "daemon": json.dumps({"id": 1, "ok": True})})
                for t in ("webrtc", "wireguard")]
        bad = [json.dumps({"transport": t, "error": "connect failed", "daemon": ""})
               for t in ("webrtc", "wireguard")]
        cases = [
            ("success", good, 0, "success"), ("assertion", bad, 1, "failure"),
            ("incomplete", bad[:1], 1, ""), ("malformed", ["{broken}"], 1, ""),
            ("launch", [], 127, ""), ("timeout", bad, 124, ""), ("killed", bad, 137, ""),
            ("nonzero-only", good, 1, ""), ("duplicate", [bad[0], bad[0]], 1, ""),
        ]
        for name, rows, status, expected in cases:
            with self.subTest(case=name):
                self.assertEqual(pair_result.assertion_verdict(rows, status), expected)

    def test_timeout_cannot_promote_an_assertion_marker(self):
        self.exercise(124, verdict="failure")
        self.assertEqual(self.last_verdict, "")

    def exercise(self, outcome=None, prep_failure=False, verdict=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rows = [{"role": role, "sha": char * 40, "release_ids": [release]}
                    for role, char, release in (("host", "a", "nightly-1"), ("dial", "b", "ios-1"))]
            window = root / "window.json"
            window.write_text(json.dumps({"include": rows}))
            logs = root / "logs"
            calls = []
            output = root / "github-output"
            def run(command, **kwargs):
                calls.append(command)
                if command[0] == "bash":
                    if isinstance(outcome, Exception):
                        raise outcome
                    if verdict is not None or not outcome:
                        Path(kwargs["env"]["SKEW_LOG_DIR"], "assertion-verdict").write_text(
                            verdict if verdict is not None else "success")
                    return subprocess.CompletedProcess(command, outcome or 0)
                if prep_failure and "fetch" in command:
                    raise subprocess.CalledProcessError(128, command)
                return subprocess.CompletedProcess(command, 0)
            with patch.object(sys, "argv", ["matrix", str(window), "--head", str(root)]), \
                 patch.dict(os.environ, {"SKEW_LOG_DIR": str(logs), "GITHUB_OUTPUT": str(output)}), \
                 patch.object(matrix.subprocess, "run", side_effect=run), \
                 patch.object(matrix, "run_source", side_effect=run), \
                 patch.object(matrix, "source_paths", return_value=["cmux-next-ios/rust"]), \
                 patch.object(matrix.subprocess, "check_output", return_value="c" * 40 + "\n"):
                try:
                    matrix.main()
                    code = 0
                except SystemExit as exc:
                    code = exc.code
                except subprocess.CalledProcessError as exc:
                    code = exc.returncode
            self.last_verdict = output.read_text() if output.exists() else ""
            return code, json.loads((logs / "matrix-result.json").read_text()), calls

    def test_infrastructure_failures_do_not_mint_red_verdict(self):
        for outcome in (7, 124, OSError("missing bash")):
            self.exercise(outcome)
            self.assertEqual(self.last_verdict, "")
        self.exercise(prep_failure=True)
        self.assertEqual(self.last_verdict, "")

    def test_completed_assertion_failure_is_red(self):
        code, _, _ = self.exercise(1, verdict="failure")
        self.assertEqual(code, 1)
        self.assertEqual(self.last_verdict, "verdict=failure\n")

    def test_success_without_assertion_receipt_is_no_verdict(self):
        code, receipt, _ = self.exercise(0, verdict="")
        self.assertEqual(code, 1)
        self.assertEqual(self.last_verdict, "")
        self.assertEqual(receipt["completed"][0]["failed_stage"], "missing-assertion-verdict")

    def test_timeout_has_terminal_receipt_and_retains_unrun_release(self):
        code, receipt, calls = self.exercise(124)
        self.assertEqual(code, 124)
        self.assertFalse(receipt["passed"])
        self.assertEqual(receipt["completed"][0]["failed_stage"], "pair-timeout")
        self.assertEqual(receipt["completed"][0]["release_ids"], ["nightly-1"])
        self.assertEqual(receipt["not_run"][0]["release_ids"], ["ios-1"])
        pair_call, = [call for call in calls if call[0] == "bash"]
        self.assertTrue(pair_call[1].endswith("/scripts/ci/timeout.sh"))
        self.assertEqual(pair_call[2:4], ["--kill-after=5", "1800"])

    def test_nonzero_pair_and_launch_error_never_pass(self):
        for outcome, status, stage in ((7, 7, "pair"), (OSError("missing bash"), 127, "pair-launch")):
            with self.subTest(stage=stage):
                code, receipt, _ = self.exercise(outcome)
                self.assertEqual(code, status)
                self.assertFalse(receipt["passed"])
                self.assertEqual(receipt["completed"][0]["failed_stage"], stage)

    def test_source_failure_records_entire_unrun_window(self):
        code, receipt, calls = self.exercise(prep_failure=True)
        self.assertEqual(code, 128)
        self.assertEqual(receipt["completed"], [])
        self.assertEqual(len(receipt["not_run"]), 2)
        self.assertEqual(receipt["failed_stage"], "source-preparation-incomplete")
        self.assertFalse(any(call[0] == "bash" for call in calls))

    def test_success_requires_every_cell_and_removes_worktrees(self):
        code, receipt, calls = self.exercise()
        self.assertEqual(code, 0)
        self.assertTrue(receipt["passed"])
        self.assertEqual(self.last_verdict, "verdict=success\n")
        self.assertEqual(len(receipt["completed"]), 2)
        self.assertEqual(receipt["not_run"], [])
        self.assertTrue(all(row["pr_sha"] == "c" * 40 for row in receipt["completed"]))
        self.assertEqual(len([call for call in calls if "remove" in call]), 2)


if __name__ == "__main__":
    unittest.main()
