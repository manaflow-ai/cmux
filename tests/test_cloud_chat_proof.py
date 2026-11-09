#!/usr/bin/env python3
"""Exercise the real DEV proof without launching an app or creating a Cloud machine."""

import contextlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cmux-next/cloud-chat-proof.py"
STAGING_API = "https://cloud-api-staging.cmux.dev"


class CloudChatProofTests(unittest.TestCase):
    def run_proof(self, *, backend_name="staging", backend=None, environment=None, wrong_bundle=False,
                  signed_in=True, reply="CLOUD_BROWSER_PROOF_OK title=Example Domain h1=Example Domain", cleanup_exit=0, app_exits=True):
        calls = []
        clock = 0.0
        auth_reads = 0
        expected_api = STAGING_API if backend_name == "staging" else "https://cloud-api.cmux.dev"
        backend = expected_api if backend is None else backend
        environment = backend_name if environment is None else environment
        launcher = Mock()
        launcher.wait.return_value = 0
        if not app_exits:
            launcher.wait.side_effect = subprocess.TimeoutExpired("open", 60)

        def sleep(seconds):
            nonlocal clock
            clock += seconds

        with tempfile.TemporaryDirectory(prefix="cloud-chat-proof-test-") as temporary:
            # Both backend proofs must launch the exact same installed bundle.
            app = Path("/Applications/Cloud Proof.app")
            evidence_path = Path(temporary) / "evidence.json"

            def run(command, *, env, capture_output, text, timeout):
                nonlocal clock, auth_reads
                clock += 0.25
                self.assertEqual(command[0], str(app / "Contents/Resources/bin/cmux"))
                self.assertEqual(env["CMUX_SOCKET_PATH"], "/tmp/cmux-debug-proof-test.sock")
                self.assertTrue(capture_output)
                self.assertTrue(text)
                self.assertGreater(timeout, 0)
                words = command[1:]
                calls.append(words)
                code = 0
                if words == ["app", "identify", "--json"]:
                    value = {"pid": 200, "app_bundle_path": "/Applications/Other.app" if wrong_bundle else str(app)}
                elif words == ["app", "call", "auth.status", "--json"]:
                    auth_reads += 1
                    # The launched app can answer while its session is still restoring.
                    value = {"signed_in": signed_in and auth_reads > 1,
                             "backend": backend, "cloud_environment": environment}
                elif words == ["vm", "token", "create", "--ttl", "30m", "--json"]:
                    value = {"stored": True}
                elif words[:2] == ["cloud", "start-chat"]:
                    self.assertEqual(words[0:3], ["cloud", "start-chat", "--prompt"])
                    self.assertIn("https://example.com/?cmux_browser_proof=", words[3])
                    self.assertEqual(words[4:], ["--agent", "claude", "--name", "proof-test", "--wait",
                                                 "--timeout", "600", "--json"])
                    value = {"machine_id": "machine-proof", "session_id": "session-proof",
                             "host": "guest.example.test", "reply": reply,
                             "turn": {"toolCalls": 1}}
                elif words[:2] == ["cloud", "exec"]:
                    start_words = next(words for words in reversed(calls[:-1]) if words[:2] == ["cloud", "start-chat"])
                    prompt = start_words[start_words.index("--prompt") + 1]
                    browser_url = prompt.split("Navigate to ", 1)[1].split(" with", 1)[0]
                    event = {"sessionUpdate": "tool_call", "toolCallId": "browser-1",
                             "rawInput": {"command": f"agent-browser open {browser_url}"}}
                    update = {"sessionUpdate": "tool_call_update", "toolCallId": "browser-1",
                              "status": "completed", "content": [{"text": "Example Domain"}]}
                    value = {"exit_code": 0, "stdout": json.dumps(event) + "\n" + json.dumps(update) + "\n"}
                elif words == ["cloud", "kill-machine", "--target", "machine:machine-proof",
                               "--confirm", "--json"]:
                    code = cleanup_exit
                    value = {"deleted": code == 0}
                elif words == ["app", "quit", "--json"]:
                    value = {"quitting": True}
                else:
                    self.fail(f"Unexpected CLI invocation: {words!r}")
                return subprocess.CompletedProcess(command, code,
                                                   json.dumps({"result": value}), "")

            argv = [str(SCRIPT), "--app", str(app), "--tag", "proof-test",
                    "--prompt", "Return the marker.", "--agent", "claude",
                    "--cloud-backend", backend_name, "--expected-api-origin", expected_api,
                    "--evidence", str(evidence_path)]
            with patch.object(sys, "argv", argv), patch("subprocess.run", side_effect=run), \
                    patch("subprocess.Popen", return_value=launcher) as launch, \
                    patch("time.monotonic", side_effect=lambda: clock), \
                    patch("time.sleep", side_effect=sleep), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as stopped:
                    runpy.run_path(str(SCRIPT), run_name="__main__")
            launch.assert_called_once_with(
                ["/usr/bin/open", "-W", "-g", "-n", str(app), "--args", "--cloud-backend", backend_name],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            launcher.wait.assert_called_once_with(timeout=60)
            self.assertTrue(evidence_path.is_file(), "Every terminal outcome must write its evidence")
            return stopped.exception.code, json.loads(evidence_path.read_text()), calls

    def assert_no_cloud_work(self, calls):
        self.assertFalse(any(words[:2] == ["vm", "token"] for words in calls))
        self.assertFalse(any(words[:2] == ["cloud", "start-chat"] for words in calls))
        self.assertFalse(any(words[:2] == ["cloud", "kill-machine"] for words in calls))

    def test_same_app_launch_flag_reads_each_actual_backend_then_reply_and_cleanup(self):
        for backend_name, origin in (("staging", STAGING_API), ("prod", "https://cloud-api.cmux.dev")):
            with self.subTest(backend=backend_name):
                code, evidence, calls = self.run_proof(backend_name=backend_name)
                self.assertEqual(code, 0)
                self.assertEqual(evidence["result"], "pass")
                self.assertEqual(evidence["app"], "/Applications/Cloud Proof.app")
                self.assertEqual(evidence["cloud_environment"], backend_name)
                self.assertEqual(evidence["api_origin"], origin)
                steps = {step["step"]: step for step in evidence["steps"]}
                self.assertEqual(steps["launched app ready"]["pid"], 200)
                self.assertEqual(steps["selected backend active and signed in"]["backend"], origin)
                self.assertTrue(steps["selected backend active and signed in"]["signed_in"])
                # The step records how long the wait took, a measurement and not a budget: this mocked
                # run rounds it to 0 ms, so the proof asserts that it was recorded, never that it is
                # above a threshold.
                self.assertIsInstance(steps["selected backend active and signed in"]["elapsed_ms"], int)
                self.assertEqual(steps["cloud start-chat"]["reply"], "CLOUD_BROWSER_PROOF_OK title=Example Domain h1=Example Domain")
                self.assertEqual(steps["cloud start-chat"]["guest_host"], "guest.example.test")
                self.assertEqual(steps["cloud start-chat"]["machine_id"], "machine-proof")
                self.assertEqual(steps["cloud kill-machine"]["exit"], 0)
                auth = ["app", "call", "auth.status", "--json"]
                self.assertEqual(calls.count(auth), 2)
                chat_index = next(index for index, words in enumerate(calls)
                                  if words[:2] == ["cloud", "start-chat"])
                self.assertLess(max(index for index, words in enumerate(calls) if words == auth), chat_index)
                self.assertEqual(calls[-1], ["app", "quit", "--json"])
                self.assertEqual(steps["app exited"]["exit"], 0)
                self.assertFalse(any(words[:2] == ["cloud", "env"] for words in calls))

    def test_configured_staging_does_not_pass_with_actual_development_backend(self):
        code, evidence, calls = self.run_proof(backend="https://cmux-api-development.debussy.workers.dev")
        self.assertEqual(code, 1)
        self.assertEqual(evidence["result"], "fail: selected backend active and signed in")
        actual = next(step for step in evidence["steps"] if step["step"] == "selected backend active and signed in")
        self.assertEqual(actual["cloud_environment"], "staging")
        self.assert_no_cloud_work(calls)

    def test_another_app_on_the_socket_does_not_pass_or_get_quit(self):
        code, evidence, calls = self.run_proof(wrong_bundle=True)
        self.assertEqual(code, 1)
        self.assertEqual(evidence["result"], "fail: launched app ready")
        self.assertFalse(any(words[:3] == ["app", "call", "auth.status"] for words in calls))
        self.assertNotIn(["app", "quit", "--json"], calls)
        self.assert_no_cloud_work(calls)

    def test_matching_backend_does_not_pass_with_wrong_actual_environment(self):
        code, evidence, calls = self.run_proof(environment="dev")
        self.assertEqual(code, 1)
        self.assertEqual(evidence["result"], "fail: selected backend active and signed in")
        self.assert_no_cloud_work(calls)

    def test_selected_backend_does_not_pass_without_sign_in(self):
        code, evidence, calls = self.run_proof(signed_in=False)
        self.assertEqual(code, 1)
        self.assertEqual(evidence["result"], "fail: selected backend active and signed in")
        self.assert_no_cloud_work(calls)

    def test_missing_reply_fails_but_still_deletes_created_machine(self):
        code, evidence, calls = self.run_proof(reply="")
        self.assertEqual(code, 1)
        self.assertEqual(evidence["result"], "fail: cloud start-chat gave no reply")
        self.assertIn(["cloud", "kill-machine", "--target", "machine:machine-proof",
                       "--confirm", "--json"], calls)

    def test_reply_does_not_pass_if_machine_cleanup_fails(self):
        code, evidence, _ = self.run_proof(cleanup_exit=1)
        self.assertEqual(code, 1)
        self.assertEqual(evidence["result"], "fail: the chat replied but its machine was not killed")
        cleanup = next(step for step in evidence["steps"] if step["step"] == "cloud kill-machine")
        self.assertEqual(cleanup["exit"], 1)

    def test_reply_does_not_pass_until_own_launch_helper_confirms_app_exit(self):
        code, evidence, _ = self.run_proof(app_exits=False)
        self.assertEqual(code, 1)
        self.assertEqual(evidence["result"], "fail: the launched app did not exit")
        self.assertEqual(evidence["steps"][-1]["exit"], 124)


if __name__ == "__main__":
    unittest.main()
