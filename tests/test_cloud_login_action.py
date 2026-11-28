#!/usr/bin/env python3
"""The `cmux login` GitHub Action (.github/actions/login, RFD 0183) runs its own bash step against a local
stand-in for GitHub's OIDC endpoint and the platform's POST /v1/tokens/github/exchange.

The fake answers exactly as cmux-platform's src/server/tokens/Tokens.ts does: 200 {token, expiresAt, team, scopes},
or {error: {code, message}} with 401/403. Each case checks what the step writes to GITHUB_OUTPUT and GITHUB_ENV,
that the token is masked before anything else could print it, and that each refusal says why in plain words.
"""

from __future__ import annotations

import http.server
import json
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
ACTION = ROOT / ".github/actions/login/action.yml"
TOKEN = "cmux_pat_" + "a" * 40
OIDC = "eyJ.oidc.jwt"


class Fake(http.server.BaseHTTPRequestHandler):
    exchange_status = 200
    exchange_answer: dict = {}
    seen: list = []

    def log_message(self, *args):
        pass

    def _send(self, status: int, body: dict) -> None:
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        Fake.seen.append(("GET", self.path, self.headers.get("authorization"), None))
        if self.headers.get("authorization") != "bearer gh-request-token":
            return self._send(403, {"message": "bad request token"})
        self._send(200, {"value": OIDC})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        Fake.seen.append(("POST", self.path, self.headers.get("content-type"), body))
        self._send(Fake.exchange_status, Fake.exchange_answer)


class LoginActionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        action = yaml.safe_load(ACTION.read_text())
        cls.action = action
        (cls.step,) = action["runs"]["steps"]
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.origin = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Fake.seen = []
        Fake.exchange_status = 200
        Fake.exchange_answer = {
            "token": TOKEN,
            "expiresAt": "2026-11-26T23:00:00.000Z",
            "team": "team_abc",
            "scopes": ["machines", "chats"],
        }

    def run_step(self, *, team: str = "", api: str | None = None, oidc_env: bool = True):
        with tempfile.TemporaryDirectory() as tmp:
            out, env_file = Path(tmp, "output"), Path(tmp, "env")
            out.touch()
            env_file.touch()
            env = {
                "PATH": os.environ["PATH"],
                "GITHUB_OUTPUT": str(out),
                "GITHUB_ENV": str(env_file),
                "CMUX_LOGIN_TEAM": team,
                "CMUX_LOGIN_API": api if api is not None else self.origin + "/",
            }
            if oidc_env:
                env["ACTIONS_ID_TOKEN_REQUEST_URL"] = f"{self.origin}/oidc?api-version=2.0"
                env["ACTIONS_ID_TOKEN_REQUEST_TOKEN"] = "gh-request-token"
            self.assertEqual(self.step["shell"], "bash")
            proc = subprocess.run(
                ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", self.step["run"]],
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            return proc, out.read_text(), env_file.read_text()

    def test_inputs_are_the_ones_the_step_reads(self):
        self.assertEqual(set(self.action["inputs"]), {"team", "api"})
        self.assertEqual(self.step["env"]["CMUX_LOGIN_TEAM"], "${{ inputs.team }}")
        self.assertEqual(self.step["env"]["CMUX_LOGIN_API"], "${{ inputs.api }}")
        for name, want in {"token": "token", "team": "team", "expires-at": "expires_at"}.items():
            self.assertEqual(self.action["outputs"][name]["value"], f"${{{{ steps.login.outputs.{want} }}}}")

    def test_signs_in_and_exports_the_token(self):
        proc, out, env = self.run_step()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        oidc_get, exchange = Fake.seen
        self.assertEqual(oidc_get[:2], ("GET", "/oidc?api-version=2.0&audience=cmux"))
        self.assertEqual(exchange[:3], ("POST", "/v1/tokens/github/exchange", "application/json"))
        self.assertEqual(exchange[3], {"idToken": OIDC})
        self.assertEqual(
            out.splitlines(), [f"token={TOKEN}", "team=team_abc", "expires_at=2026-11-26T23:00:00.000Z"]
        )
        self.assertEqual(
            env.splitlines(),
            [f"CMUX_TOKEN={TOKEN}", "CMUX_CLOUD_TEAM=team_abc", f"CMUX_PLATFORM_ORIGIN={self.origin}"],
        )
        lines = proc.stdout.splitlines()
        self.assertIn(f"::add-mask::{OIDC}", lines)
        self.assertIn(f"::add-mask::{TOKEN}", lines)
        # The only place the token appears in the log is the mask command itself.
        self.assertEqual([l for l in lines if TOKEN in l], [f"::add-mask::{TOKEN}"])
        self.assertIn("Signed in to cmux team team_abc until 2026-11-26T23:00:00.000Z (machines, chats).", lines)

    def test_team_input_is_sent(self):
        proc, _, _ = self.run_step(team="team_xyz")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(Fake.seen[1][3], {"idToken": OIDC, "team": "team_xyz"})

    def test_untrusted_repository_says_why(self):
        Fake.exchange_status = 403
        Fake.exchange_answer = {
            "error": {"code": "tokens.untrusted", "message": "no team trusts o/r at refs/heads/main; a team admin allows it"}
        }
        proc, out, env = self.run_step()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(
            "::error title=cmux login::no team trusts o/r at refs/heads/main; a team admin allows it", proc.stdout
        )
        self.assertEqual((out, env), ("", ""))

    def test_non_json_answer_fails_plainly(self):
        Fake.exchange_status = 502
        Fake.exchange_answer = "bad gateway"  # type: ignore[assignment]
        proc, out, env = self.run_step()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("::error title=cmux login::cmux did not answer with a token", proc.stdout)
        self.assertEqual((out, env), ("", ""))

    def test_missing_id_token_permission_names_the_fix(self):
        proc, _, _ = self.run_step(oidc_env=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Add 'permissions: id-token: write' to the job.", proc.stdout)
        self.assertEqual(Fake.seen, [])


if __name__ == "__main__":
    unittest.main()
