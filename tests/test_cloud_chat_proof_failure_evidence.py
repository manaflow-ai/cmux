#!/usr/bin/env python3
"""cloud-chat-proof.py says why a Cloud start failed, without the prompt.

The CLI's start-chat error names the command to run again, and that command carries the whole
prompt, the caller's context included, so #35079 left every start-chat error out of the evidence.
Then a machine that never connected (published runs 41816691332 and 41821180871) failed with
empty stdout and stderr. This runs the proof against a fake app CLI and a fake `log` tool and
checks that the evidence keeps the error's code and message and the app's link log, and never
the prompt.
"""
import json
import os
import subprocess
import sys
import tempfile
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
print("2026-11-04 11:31:02.1 Df cmux[1:2] [com.cmuxterm.app.next:cloud.link] legacy connect m-1: daemon start")
print("2026-11-04 11:31:03.1 Df cmux[1:2] [com.cmuxterm.app.next:cloud.hub] sent caller-context-7f3a token=abcdef123456")
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
            env = {**os.environ, "FAKE_STATE": str(tmp_path / "calls"), "CMUX_PROOF_LOG_TOOL": str(log_tool)}
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
            self.assertIn("legacy connect m-1: daemon start", log["lines"][0])
            self.assertIn("sent [prompt]", log["lines"][1])
            self.assertNotIn("app_link_log", done.stdout)
            self.assertEqual(steps["cloud kill-machine"]["stderr"], "cloud.machine.not_found: no machine m-1")


if __name__ == "__main__":
    unittest.main()
