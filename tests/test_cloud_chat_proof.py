#!/usr/bin/env python3
"""Exercise the real DEV proof without launching an app or creating a Cloud machine."""

import contextlib
import io
import json
import os
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
                  signed_in=True, reply="CLOUD_BROWSER_PROOF_OK title=Example Domain h1=Example Domain", cleanup_exit=0, app_exits=True,
                  from_folder=False, folder_reply=True, grant=False, login="", agent="claude"):
        calls = []
        folders = []
        configs = []
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
                config = env.get("CMUX_NEXT_CONFIG_FILE")
                if grant:
                    # The app's own scratch cmux.json, private to this run, holding only the consent.
                    path = Path(config)
                    self.assertEqual(path.name, "cmux-next.json")
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(json.loads(path.read_text()), {"cloud": {"useMyClaudeLoginOnMyCloudMachines": True}})
                    if path not in configs:
                        configs.append(path)
                else:
                    self.assertEqual(config, os.environ.get("CMUX_NEXT_CONFIG_FILE"))
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
                    rest = words[4:]
                    answer = reply
                    if from_folder:
                        # A plain folder outside home, holding only the one file whose word the prompt never names.
                        self.assertEqual(rest[2], "--from-folder")
                        folder = Path(rest[3])
                        folders.append(folder)
                        self.assertEqual([path.name for path in folder.iterdir()], ["cmux-folder-proof.txt"])
                        self.assertFalse(str(folder).startswith(str(Path.home()) + "/"))
                        word = (folder / "cmux-folder-proof.txt").read_text().strip()
                        self.assertNotIn(word, words[3])
                        self.assertIn("cmux-folder-proof.txt", words[3])
                        if reply and folder_reply:
                            answer = f"{reply} folder={word}"
                        rest = rest[:2] + rest[4:]
                    # `--login` goes to a Claude chat only, after any --from-folder.
                    chosen = ["--login", login] if login and agent == "claude" else []
                    self.assertEqual(rest, ["--agent", agent, *chosen, "--name", "proof-test", "--wait",
                                            "--timeout", "600", "--json"])
                    value = {"machine_id": "machine-proof", "session_id": "session-proof",
                             "host": "guest.example.test", "reply": answer,
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
                    "--prompt", "Return the marker.", "--agent", agent,
                    "--cloud-backend", backend_name, "--expected-api-origin", expected_api,
                    "--evidence", str(evidence_path)] + (["--from-folder"] if from_folder else []) \
                + (["--grant-claude-login"] if grant else []) + (["--login", login] if login else [])
            with patch.object(sys, "argv", argv), patch("subprocess.run", side_effect=run), \
                    patch("subprocess.Popen", return_value=launcher) as launch, \
                    patch("time.monotonic", side_effect=lambda: clock), \
                    patch("time.sleep", side_effect=sleep), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as stopped:
                    runpy.run_path(str(SCRIPT), run_name="__main__")
            expected_launch = ["/usr/bin/open", "-W", "-g", "-n", "--env", "CMUX_NEXT_SOCKET_PATH=/tmp/cmux-debug-proof-test.sock"]
            if grant:
                self.assertEqual(len(configs), 1, "The CLI and the launch read one scratch cmux.json")
                expected_launch += ["--env", f"CMUX_NEXT_CONFIG_FILE={configs[0]}"]
                self.assertFalse(configs[0].parent.exists(), "The proof removes its scratch cmux.json")
            launch.assert_called_once_with(
                expected_launch + [str(app), "--args", "--cloud-backend", backend_name],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            launcher.wait.assert_called_once_with(timeout=60)
            self.assertTrue(evidence_path.is_file(), "Every terminal outcome must write its evidence")
            for folder in folders:
                self.assertFalse(folder.exists(), "The proof removes the folder it made")
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
                self.assertEqual(evidence["claude_login"], {"consent_granted": False, "login": None})

    def test_grant_claude_login_gives_the_launch_its_consent_and_the_chat_its_login(self):
        # CI's unattended Claude chat on either backend: the consent a Release build's headless start waits for,
        # in the launched app's own cmux.json, and `--login none` (the machine's team gateway), which a DEV
        # build's headless start takes where it would refuse with needs-login-choice.
        for backend_name in ("staging", "prod"):
            with self.subTest(backend=backend_name):
                code, evidence, calls = self.run_proof(backend_name=backend_name, grant=True, login="none")
                self.assertEqual(code, 0, evidence)
                self.assertEqual(evidence["claude_login"], {"consent_granted": True, "login": "none"})
                start = next(words for words in calls if words[:2] == ["cloud", "start-chat"])
                self.assertEqual(start[start.index("--login") + 1], "none")

    def test_login_follows_the_folder_and_goes_to_a_claude_chat_only(self):
        code, evidence, _ = self.run_proof(from_folder=True, grant=True, login="none")
        self.assertEqual(code, 0, evidence)
        code, evidence, calls = self.run_proof(agent="codex", grant=True, login="none")
        self.assertEqual(code, 0, evidence)
        self.assertEqual(evidence["claude_login"], {"consent_granted": True, "login": None})
        start = next(words for words in calls if words[:2] == ["cloud", "start-chat"])
        self.assertNotIn("--login", start)

    def test_from_folder_reply_must_hold_the_word_only_the_folder_has(self):
        code, evidence, _ = self.run_proof(from_folder=True)
        self.assertEqual(code, 0, evidence)
        self.assertEqual(evidence["result"], "pass")
        self.assertTrue(evidence["from_folder"])
        chat = next(step for step in evidence["steps"] if step["step"] == "cloud start-chat")
        self.assertTrue(chat["folder_proof"]["word_in_reply"])
        self.assertTrue(chat["reply"].startswith("CLOUD_BROWSER_PROOF_OK title=Example Domain h1=Example Domain folder=folder"))

    def test_from_folder_fails_when_the_reply_lacks_the_folder_word(self):
        code, evidence, calls = self.run_proof(from_folder=True, folder_reply=False)
        self.assertEqual(code, 1)
        self.assertEqual(evidence["result"], "fail: the reply does not hold the word from the chat's folder (not copied, or not read)")
        self.assertIn(["cloud", "kill-machine", "--target", "machine:machine-proof", "--confirm", "--json"], calls)

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


class CloudPausedCaptureTests(unittest.TestCase):
    """--paused-capture: one machine paused, the Cloud page's paused price read and captured, the machine killed."""

    def run_capture(self, *, subtitle="Paused · $0.26/h when running · About $1.00 a month while paused",
                    existing=False, pause_exit=0, cleanup_exit=0, write_images=True):
        calls = []
        clock = 0.0
        state = {"status": "paused" if existing else "starting", "created": existing}
        launcher = Mock()
        launcher.wait.return_value = 0

        def sleep(seconds):
            nonlocal clock
            clock += seconds

        with tempfile.TemporaryDirectory(prefix="cloud-paused-capture-test-") as temporary:
            app = Path("/Applications/Cloud Proof.app")
            evidence_path = Path(temporary) / "evidence.json"
            shots = Path(temporary) / "shots"

            def run(command, *, env, capture_output, text, timeout):
                nonlocal clock
                clock += 0.25
                self.assertEqual(command[0], str(app / "Contents/Resources/bin/cmux"))
                words = command[1:]
                calls.append(words)
                code = 0
                if words == ["app", "identify", "--json"]:
                    value = {"pid": 200, "app_bundle_path": str(app)}
                elif words == ["app", "call", "auth.status", "--json"]:
                    value = {"signed_in": True, "backend": STAGING_API, "cloud_environment": "staging"}
                elif words == ["cloud", "list-machines", "--json"]:
                    value = {"machines": [{"machine_id": "vm_abc", "title": "proof-test", "status": state["status"]}]
                             if state["created"] else []}
                elif words == ["cloud", "new-machine", "--name", "proof-test", "--json"]:
                    state["created"] = True
                    value = {"machine_id": "vm_abc", "title": "proof-test", "status": "starting"}
                elif words == ["cloud", "machine-status", "--target", "machine:vm_abc", "--json"]:
                    # Starting at first, then running: the capture waits on the server, not a sleep.
                    if state["status"] == "starting" and clock > 5:
                        state["status"] = "running"
                    value = {"status": state["status"], "hourly_rate_usd": 0.26}
                elif words == ["cloud", "pause-machine", "--target", "machine:vm_abc", "--json"]:
                    self.assertEqual(state["status"], "running")
                    code = pause_exit
                    if code == 0:
                        state["status"] = "paused"
                    value = {}
                elif words[:3] == ["app", "call", "action.run"]:
                    self.assertEqual(json.loads(words[3]), {"id": "palette.openCloudPane", "focus": True})
                    value = {"ok": True}
                elif words[:3] == ["app", "call", "debug.page"]:
                    params = json.loads(words[3])
                    self.assertEqual(params["page"], "cmux.cloud")
                    action = params["action"]
                    if action == "wait" and params["selector"] == ".cloud-machine":
                        value = {"matched": True, "text": "proof-test"}
                    elif action == "query" and params["selector"] == ".cloud-machine-title":
                        value = {"elements": [{"text": "other"}, {"text": "proof-test"}]}
                    elif action == "query" and params["selector"] == ".cloud-machine-subtitle":
                        value = {"elements": [{"text": "Running 2h"}, {"text": subtitle}]}
                    elif action in ("scroll", "click"):
                        self.assertEqual(params["selector"], ".cloud-machine-list > .cloud-machine:nth-child(2)")
                        value = {"scrolled": True} if action == "scroll" else {"clicked": True}
                    elif action == "wait" and params["selector"] == ".cloud-machine-cost":
                        value = {"matched": True, "text": subtitle.split("Paused · ", 1)[-1]}
                    elif action == "snapshot":
                        if write_images:
                            Path(params["path"]).write_bytes(b"png")
                        value = {"path": params["path"]} if write_images else {"error": "snapshot failed"}
                    else:
                        self.fail(f"Unexpected debug.page call: {params!r}")
                elif words[:3] == ["app", "call", "debug.window_snapshot"]:
                    params = json.loads(words[3])
                    self.assertEqual(params["kind"], "main")
                    if write_images:
                        Path(params["path"]).write_bytes(b"png")
                    value = {"path": params["path"]} if write_images else {"error": "no such window"}
                elif words == ["cloud", "kill-machine", "--target", "machine:vm_abc", "--confirm", "--json"]:
                    code = cleanup_exit
                    value = {"deleted": code == 0}
                elif words == ["app", "quit", "--json"]:
                    value = {"quitting": True}
                else:
                    self.fail(f"Unexpected CLI invocation: {words!r}")
                return subprocess.CompletedProcess(command, code, json.dumps({"result": value}), "")

            argv = [str(SCRIPT), "--app", str(app), "--tag", "proof-test", "--cloud-backend", "staging",
                    "--expected-api-origin", STAGING_API, "--evidence", str(evidence_path),
                    "--paused-capture", str(shots)]
            with patch.object(sys, "argv", argv), patch("subprocess.run", side_effect=run), \
                    patch("subprocess.Popen", return_value=launcher), \
                    patch("time.monotonic", side_effect=lambda: clock), \
                    patch("time.sleep", side_effect=sleep), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as stopped:
                    runpy.run_path(str(SCRIPT), run_name="__main__")
            images = sorted(path.name for path in shots.glob("*.png")) if shots.is_dir() else []
            return stopped.exception.code, json.loads(evidence_path.read_text()), calls, images

    def test_pauses_reads_the_paused_price_captures_and_kills(self):
        code, evidence, calls, images = self.run_capture()
        self.assertEqual(code, 0, evidence)
        self.assertEqual(evidence["result"], "pass")
        self.assertEqual(images, ["cloud-paused-page.png", "cloud-paused-window.png"])
        self.assertIn("About $1.00 a month while paused", evidence["paused_capture"]["row_text"])
        self.assertIn("a month while paused", evidence["paused_capture"]["detail_text"])
        order = [words[:2] for words in calls if words[0] == "cloud"]
        self.assertLess(order.index(["cloud", "new-machine"]), order.index(["cloud", "pause-machine"]))
        self.assertEqual(calls[-2], ["cloud", "kill-machine", "--target", "machine:vm_abc", "--confirm", "--json"])
        self.assertFalse(any(words[:2] in (["vm", "token"], ["cloud", "start-chat"]) for words in calls))

    def test_reuses_the_machine_its_name_already_has(self):
        code, evidence, calls, _ = self.run_capture(existing=True)
        self.assertEqual(code, 0, evidence)
        self.assertNotIn(["cloud", "new-machine", "--name", "proof-test", "--json"], calls)
        self.assertFalse(any(words[:2] == ["cloud", "pause-machine"] for words in calls))

    def test_fails_without_the_paused_line_but_still_captures_and_kills(self):
        code, evidence, calls, images = self.run_capture(subtitle="Paused · $0.26/h when running")
        self.assertEqual(code, 1)
        self.assertEqual(evidence["result"], "fail: the Cloud page does not say 'a month while paused' for the paused machine")
        self.assertEqual(images, ["cloud-paused-page.png", "cloud-paused-window.png"])
        self.assertIn(["cloud", "kill-machine", "--target", "machine:vm_abc", "--confirm", "--json"], calls)

    def test_failed_pause_fails_and_kills(self):
        code, evidence, calls, _ = self.run_capture(pause_exit=1)
        self.assertEqual(code, 1)
        self.assertEqual(evidence["result"], "fail: cloud pause-machine")
        self.assertIn(["cloud", "kill-machine", "--target", "machine:vm_abc", "--confirm", "--json"], calls)

    def test_no_image_fails(self):
        code, evidence, _, images = self.run_capture(write_images=False)
        self.assertEqual(code, 1)
        self.assertEqual(images, [])
        self.assertEqual(evidence["result"], "fail: no image of the Cloud page was written")

    def test_capture_does_not_pass_if_its_machine_is_not_killed(self):
        code, evidence, _, _ = self.run_capture(cleanup_exit=1)
        self.assertEqual(code, 1)
        self.assertEqual(evidence["result"], "fail: the capture passed but its machine was not killed")


if __name__ == "__main__":
    unittest.main()
