#!/usr/bin/env python3
"""cloud-chat-proof.py says why a Cloud start failed, without the prompt.

The CLI's start-chat error names the command to run again, and that command carries the whole
prompt, the caller's context included, so #35079 left every start-chat error out of the evidence.
Then a machine that never connected (published runs 41816691332 and 41821180871) failed with
empty stdout and stderr. This runs the proof against a fake app CLI and a fake `log` tool and
checks that the evidence keeps the error's code and message and the app's link log, and never
the prompt.
"""
import base64
import hashlib
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / "scripts/cmux-next/cloud-chat-proof.py"
CONTEXT = "caller-context-7f3a"

FAKE_CMUX = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state = Path(os.environ["FAKE_STATE"])
words = sys.argv[1:]
verb = " ".join(words[:2])
if verb == "cloud list-machines":
    print(json.dumps({"account": {"signed_in": True}, "machines": []}))
elif verb == "vm token":
    print(json.dumps({"ok": True}))
elif verb == "cloud start-chat":
    prompt = words[words.index("--prompt") + 1]
    again = "cmux cloud start-chat --prompt '" + prompt + "' --name x --wait --json"
    calls = int(state.read_text()) if state.exists() else 0
    state.write_text(str(calls + 1))
    if calls == 0:
        sys.stderr.write(json.dumps({"code": "cloud.start_pending", "message":
            "the machine is still starting; the chat opens in its workspace when it is up. "
            "Run the same command again to keep waiting: " + again,
            "details": {"again": again, "machine_id": None}}) + "\n")
        sys.exit(75)
    sys.stderr.write(json.dumps({"code": "cloud.start_failed", "message":
        "x didn't connect (machine m-1); try again: " + again,
        "details": {"machine_id": "m-1", "app": {"message": again}}}) + "\n")
    sys.exit(1)
elif verb == "app call":
    assert words[2] == "cloud.machines", words
    print(json.dumps({"link_route": "native", "last_error": None, "machines": [
        {"id": "m-1", "title": "ccp-test", "status": "running", "stage": "failed",
         "stage_detail": "link_token refused: auth.forbidden", "link_ended_detail": "Bearer abcdef123456", "secret_field": "x"},
        {"id": "m-2", "title": "someone else", "stage_detail": "not ours"}]}))
elif verb == "cloud kill-machine":
    sys.stderr.write(json.dumps({"code": "cloud.machine.not_found", "message": "no machine m-1"}) + "\n")
    sys.exit(1)
else:
    sys.exit(2)
'''

FAKE_LOG = r'''#!/usr/bin/env python3
import sys
assert sys.argv[1] == "show", sys.argv
assert "cloud.link" in sys.argv[sys.argv.index("--predicate") + 1]
assert '"cloud.native"' in sys.argv[sys.argv.index("--predicate") + 1], sys.argv
assert "--info" in sys.argv, sys.argv
import re
assert re.fullmatch(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d", sys.argv[sys.argv.index("--start") + 1]), sys.argv
assert "--last" not in sys.argv, sys.argv
print("2026-11-04 11:31:02.1 Df cmux[1:2] [com.cmuxterm.app.next:cloud.link] legacy connect m-1: daemon start")
print("2026-11-04 11:31:03.1 Df cmux[1:2] [com.cmuxterm.app.next:cloud.hub] sent caller-context-7f3a")
print("2026-11-04 11:31:04.1 Df cmux[1:2] [com.cmuxterm.app.next:cloud.hub] token=abcdef123456")
'''


class CloudChatProofFailureEvidenceTests(unittest.TestCase):
    def test_failed_start_keeps_error_and_link_log_without_prompt(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app = tmp_path / "cmux NEXT DEV.app"
            cli = app / "Contents/Resources/bin/cmux"
            cli.parent.mkdir(parents=True)
            cli.write_text(FAKE_CMUX)
            cli.chmod(0o755)
            log_tool = tmp_path / "log"
            log_tool.write_text(FAKE_LOG)
            log_tool.chmod(0o755)
            evidence = tmp_path / "evidence.json"
            env = {**os.environ, "FAKE_STATE": str(tmp_path / "calls"), "CMUX_PROOF_LOG_TOOL": str(log_tool),
                   "CMUX_PROOF_RESERVATION": "skip"}
            done = subprocess.run(
                [sys.executable, "-I", str(PROOF), "--app", str(app), "--tag", "ccp-test", "--prompt", CONTEXT,
                 "--agent", "claude", "--evidence", str(evidence)],
                env=env, capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
            text = evidence.read_text()
            self.assertNotIn(CONTEXT, text)
            self.assertNotIn(CONTEXT, done.stdout)
            self.assertNotIn("Navigate to", text)
            self.assertNotIn("abcdef123456", text)
            self.assertNotIn("token=", text)
            steps = {step["step"]: step for step in json.loads(text)["steps"]}

            pending = steps["cloud start-chat (machine still starting)"]
            self.assertEqual(pending["stderr"], "cloud.start_pending: the machine is still starting; "
                             "the chat opens in its workspace when it is up.")
            failed = steps["cloud start-chat"]
            self.assertEqual(failed["stderr"], "cloud.start_failed: x didn't connect (machine m-1); try again:")
            self.assertIn("cloud.start_failed: x didn't connect", done.stdout)
            log = failed["app_link_log"]
            self.assertEqual(log["exit"], 0)
            self.assertEqual(log["line_count"], 2)
            self.assertEqual(log["left_out"], 1)
            self.assertIn("legacy connect m-1: daemon start", log["lines"][0])
            self.assertIn("sent [prompt]", log["lines"][1])
            self.assertNotIn("app_link_log", done.stdout)
            state = failed["app_link_state"]
            self.assertEqual(state["link_route"], "native")
            self.assertEqual([row["id"] for row in state["machines"]], ["m-1"])
            self.assertEqual(state["machines"][0]["stage_detail"], "link_token refused: auth.forbidden")
            self.assertNotIn("secret_field", state["machines"][0])
            self.assertNotIn("abcdef123456", json.dumps(state))
            self.assertEqual(steps["cloud kill-machine"]["stderr"], "cloud.machine.not_found: no machine m-1")


FAKE_CLEANUP_CMUX = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state = Path(os.environ["FAKE_STATE"])
words = sys.argv[1:]
verb = " ".join(words[:2])
assert "start-chat" not in words and "token" not in words, words
if verb == "cloud list-machines":
    print(json.dumps({"loaded": True, "account": {"signed_in": True}, "machines": [
        {"machine_id": "vm_abc123", "title": "ccp-1", "status": "running", "created_by": "a@b.c",
         "created_at": "2026-11-04T14:40:00Z"}]}))
elif verb == "cloud machine-status":
    assert words[words.index("--target") + 1] == "machine:vm_abc123", words
    print(json.dumps({"result": {"machine_id": "vm_abc123", "state": "running", "status": "running",
        "address": "10.0.0.9", "running_since": "2026-11-04T14:40:00Z", "note": "token=abcdef123456",
        "idle_pause": {"minutes": 30, "last_api_activity_at": 1793800000,
                       "last_decision": {"at": 1, "outcome": "kept", "reason": "token=abcdef123456", "run": {}}}}}))
elif verb == "cloud kill-machine":
    # --confirm last: before --json it took --json as its value and the CLI answered in human text.
    assert words == ["cloud", "kill-machine", "--target", "machine:vm_abc123", "--json", "--confirm"], words
    calls = int(state.read_text()) if state.exists() else 0
    state.write_text(str(calls + 1))
    if os.environ.get("FAKE_KILL") == "human":
        print("progress: asking the app " + "y" * 3000)
        sys.stderr.write("Couldn't delete machine vm_abc123: paused machines can't be deleted\n"
                         "token=abcdef123456\n" + "x" * 3000 + "\n")
        sys.exit(1)
    if calls == 0:
        sys.stderr.write(json.dumps({"code": "cloud.kill_failed", "message": "busy"}) + "\n")
        sys.exit(1)
    print(json.dumps({"ok": True}))
else:
    sys.exit(2)
'''


class CloudChatProofCleanupTests(unittest.TestCase):
    def run_proof(self, tmp_path: Path, *extra: str, kill: str = "") -> subprocess.CompletedProcess:
        app = tmp_path / "cmux NEXT DEV.app"
        cli = app / "Contents/Resources/bin/cmux"
        cli.parent.mkdir(parents=True, exist_ok=True)
        cli.write_text(FAKE_CLEANUP_CMUX)
        cli.chmod(0o755)
        env = {**os.environ, "FAKE_STATE": str(tmp_path / "calls"), "FAKE_KILL": kill}
        return subprocess.run(
            [sys.executable, "-I", str(PROOF), "--app", str(app), "--tag", "ccp-test",
             "--evidence", str(tmp_path / "evidence.json"), *extra],
            env=env, capture_output=True, text=True, timeout=120,
        )

    def test_cleanup_reads_status_and_retries_kill(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            done = self.run_proof(tmp_path, "--cleanup-machine", "vm_abc123")
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            text = (tmp_path / "evidence.json").read_text()
            self.assertNotIn("token=", text)
            for leaked in ("abcdef123456", "10.0.0.9", "a@b.c"):
                self.assertNotIn(leaked, text)
                self.assertNotIn(leaked, done.stdout)
            evidence = json.loads(text)
            self.assertEqual(evidence["result"], "pass")
            steps = {step["step"]: step for step in evidence["steps"]}
            self.assertTrue(steps["cloud list-machines (cleanup target)"]["listed"])
            status = steps["cloud machine-status"]["machine_status"]
            self.assertEqual(status["state"], "running")
            self.assertEqual(status["idle_pause"]["last_api_activity_at"], 1793800000)
            self.assertEqual(status["idle_pause"]["last_decision"]["outcome"], "kept")
            self.assertEqual(steps["cloud kill-machine"]["stderr"], "cloud.kill_failed: busy")
            self.assertEqual(steps["cloud kill-machine retry"]["exit"], 0)
            self.assertIn("cloud machine-status after kill", steps)

    def test_failed_kill_keeps_its_raw_output_without_secrets(self) -> None:
        # Run 41867887577: the kill exited 1 twice with no JSON error, and the evidence kept nothing.
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            done = self.run_proof(tmp_path, "--cleanup-machine", "vm_abc123", kill="human")
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
            text = (tmp_path / "evidence.json").read_text()
            self.assertNotIn("token=", text)
            self.assertNotIn("abcdef123456", text)
            self.assertNotIn("paused machines", done.stdout)
            evidence = json.loads(text)
            self.assertEqual(evidence["result"], "fail: kill-machine failed twice")
            steps = {step["step"]: step for step in evidence["steps"]}
            for name in ("cloud kill-machine", "cloud kill-machine retry"):
                step = steps[name]
                self.assertEqual(step["stderr"], "kill-machine returned no JSON error")
                raw = step["raw"]
                self.assertEqual(raw["exit"], 1)
                self.assertTrue(raw["stdout"]["text"].startswith("progress: asking the app y"))
                self.assertTrue(raw["stdout"]["truncated"])  # one long line is still marked cut
                self.assertEqual(len(raw["stdout"]["text"]), 2048)
                self.assertTrue(raw["stderr"]["text"].startswith(
                    "Couldn't delete machine vm_abc123: paused machines can't be deleted\n"))
                self.assertEqual(raw["stderr"]["left_out"], 1)
                self.assertTrue(raw["stderr"]["truncated"])
                self.assertLessEqual(len(raw["stderr"]["text"]), 2048)

    def test_cleanup_refuses_a_malformed_machine_id(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            done = self.run_proof(Path(tmp), "--cleanup-machine", "vm_x; rm -rf /")
            self.assertEqual(done.returncode, 2)
            self.assertFalse((Path(tmp) / "calls").exists())


FAKE_RESERVE_CMUX = r'''#!/usr/bin/env python3
import json, sys
verb = " ".join(sys.argv[1:3])
if verb == "cloud list-machines":
    print(json.dumps({"account": {"signed_in": True}, "owner": "personal", "machines": [
        {"title": "ccp-41820867139", "machine_id": "vm_leaked0000000000000", "status": "running", "created_at": 1},
        {"title": "ccp-test", "machine_id": "vm_mine00000000000000", "status": "running"},
        {"title": "my laptop", "machine_id": "vm_other0000000000000"}]}))
elif verb == "vm token":
    print(json.dumps({"ok": True}))
elif verb == "cloud start-chat":
    sys.stderr.write(json.dumps({"code": "cloud.start_failed", "message": "no machine"}) + "\n")
    sys.exit(1)
elif verb == "app call":
    print(json.dumps({"machines": []}))
else:
    sys.exit(2)
'''

PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
SUB = "stack-user-1"


def jwt(sub: str) -> str:
    part = lambda value: base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
    return f"{part({'alg': 'none'})}.{part({'sub': sub})}.signaturesignature"


FRESH = jwt(SUB)


class FakePlatform(http.server.BaseHTTPRequestHandler):
    """Stack's refresh and the platform's health, reservation, release, machine read and destroy."""
    calls: list = []
    destroyed = False

    def log_message(self, *args) -> None:
        pass

    def answer(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record(self) -> dict:
        length = int(self.headers.get("content-length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        call = {"method": self.command, "path": self.path, "body": body,
                "authorization": self.headers.get("authorization"), "team": self.headers.get("x-cmux-team"),
                "refresh": self.headers.get("x-stack-refresh-token")}
        FakePlatform.calls.append(call)
        return call

    def do_GET(self) -> None:
        self.record()
        if self.path == "/v1/health":
            return self.answer(200, {"status": "ok", "commit": "c0ffee"})
        if self.path == "/v1/machines/vm_reserved00000000000":
            if FakePlatform.destroyed:
                return self.answer(404, {"code": "machine.not_found", "message": "gone"})
            return self.answer(200, {"id": "vm_reserved00000000000", "status": "starting", "address": "10.0.0.9"})
        self.answer(404, {})

    def do_POST(self) -> None:
        call = self.record()
        if self.path == "/api/v1/auth/sessions/current/refresh":
            return self.answer(200, {"access_token": FRESH})
        if self.path == "/v1/machines/reservations":
            return self.answer(200, {"leaseId": "lease-1", "machine": "vm_reserved00000000000",
                                     "expiresAt": 120000, "note": "token=abcdef123456"})
        self.answer(404, {})

    def do_DELETE(self) -> None:
        self.record()
        if self.path.startswith("/v1/machines/reservations/"):
            return self.answer(200, {"released": True})
        if self.path == "/v1/machines/vm_reserved00000000000":
            FakePlatform.destroyed = True
            return self.answer(200, {"ok": True})
        self.answer(404, {})


class CloudChatProofReservationTests(unittest.TestCase):
    def test_reservation_posts_with_the_session_and_team_then_cleans_up(self) -> None:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakePlatform)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        origin = f"http://127.0.0.1:{server.server_address[1]}"
        try:
            with tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                store = (tmp_path / "Library/Application Support/cmux/com.cmuxterm.app.debug.next" / PROJECT
                         / "credentials.json")
                store.parent.mkdir(parents=True)
                store.write_text(json.dumps({"accessToken": "stale-access-0123456789", "refreshToken": "refresh-0123456789"}))
                app = tmp_path / "cmux NEXT DEV.app"
                cli = app / "Contents/Resources/bin/cmux"
                cli.parent.mkdir(parents=True)
                cli.write_text(FAKE_RESERVE_CMUX)
                cli.chmod(0o755)
                log_tool = tmp_path / "log"
                log_tool.write_text("#!/bin/sh\nexit 0\n")
                log_tool.chmod(0o755)
                evidence = tmp_path / "evidence.json"
                env = {**os.environ, "HOME": str(tmp_path), "CMUX_PROOF_LOG_TOOL": str(log_tool),
                       "CMUX_PROOF_STACK_API": origin, "CMUX_PROOF_RESERVATION_PLATFORM": origin}
                env.pop("CMUX_PROOF_RESERVATION", None)
                done = subprocess.run(
                    [sys.executable, "-I", str(PROOF), "--app", str(app), "--tag", "ccp-test", "--prompt", "x",
                     "--agent", "codex", "--evidence", str(evidence)],
                    env=env, capture_output=True, text=True, timeout=120,
                )
                self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
                text = evidence.read_text()
        finally:
            server.shutdown()
            server.server_close()
        for secret in (FRESH, "stale-access", "refresh-0123456789", "abcdef123456", "10.0.0.9"):
            self.assertNotIn(secret, text)
            self.assertNotIn(secret, done.stdout)
        result = json.loads(text)
        hex20 = lambda value: hashlib.sha256(value.encode()).hexdigest()[:20]
        team = "team_" + hex20("personal:user_" + hex20(f"stack:{PROJECT}:{SUB}"))
        reservation = result["reservation"]
        self.assertEqual(reservation["health_commit"], "c0ffee")
        self.assertEqual(reservation["session"], "seeded session, refreshed at Stack")
        self.assertEqual(reservation["x_cmux_team"], team)
        self.assertEqual(reservation["reserve"]["http_status"], 200)
        self.assertEqual(reservation["reserve"]["body"]["machine"], "vm_reserved00000000000")
        self.assertEqual(reservation["reserve"]["body"]["note"], "[left out]")
        self.assertTrue(reservation["ok"])
        self.assertEqual(reservation["release"]["http_status"], 200)
        self.assertEqual(reservation["destroy"]["http_status"], 200)
        self.assertEqual(reservation["machine_after_cleanup"]["http_status"], 404)
        self.assertTrue(reservation["cleaned"])
        self.assertNotIn("app_kill_machine", reservation)
        self.assertEqual([row["machine_id"] for row in result["leftover_proof_machines"]], ["vm_leaked0000000000000"])
        calls = FakePlatform.calls
        refresh = next(call for call in calls if call["path"].endswith("/refresh"))
        self.assertEqual(refresh["refresh"], "refresh-0123456789")
        reserve = next(call for call in calls if call["method"] == "POST" and call["path"] == "/v1/machines/reservations")
        self.assertEqual(reserve["authorization"], f"Bearer {FRESH}")
        self.assertEqual(reserve["team"], team)
        key = reserve["body"]["composeKey"]
        self.assertEqual(reservation["compose_key"], key)
        self.assertIn({"method": "DELETE", "path": f"/v1/machines/reservations/{key}", "body": None,
                       "authorization": f"Bearer {FRESH}", "team": team, "refresh": None}, calls)


if __name__ == "__main__":
    unittest.main()
