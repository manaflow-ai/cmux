#!/usr/bin/env python3
"""`cmux coderouter claude add oauth-token` mints its token with the configured Claude.

With no token in the environment and a terminal on stdin, the command runs
`claude setup-token` itself. It used to run whichever `claude` came first on
PATH, so a user who pins Claude through `integrations.claudeCode.customClaudePath`
(exported as CMUX_CUSTOM_CLAUDE_PATH) could mint a token from a different
install, or fail when PATH had none. Each case runs the real CLI on a pty with
two fake `claude` executables that print different tokens, and checks which
token reached the fake socket.
"""

from __future__ import annotations

import json
import os
import pty
import socketserver
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from fake_socket_env import cli_environment, unwrap_capability


CUSTOM_TOKEN = "sk-ant-oat01-" + "C" * 40
PATH_TOKEN = "sk-ant-oat01-" + "P" * 40
WRAPPER_MARKER = "cmux claude wrapper - injects hooks and session tracking"


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            self.server.calls.append((request["method"], request.get("params", {})))  # type: ignore[attr-defined]
            response = {"ok": True, "result": {"ok": True}, "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class CoderouterSetupTokenCustomClaudeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-setup-token-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cli = resolve_cmux_cli()

    def fake_claude(self, directory: Path, token: str, *, wrapper: bool = False) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / "claude"
        marker = f"# {WRAPPER_MARKER}\n" if wrapper else ""
        path.write_text(
            "#!/bin/sh\n" + marker
            + f'[ "$1" = setup-token ] || exit 64\n'
            + f'echo "Your token: {token}"\n'
        )
        path.chmod(0o755)
        return path

    def add_oauth_token(
        self, *, custom: str | None, path_has_claude: bool = True
    ) -> tuple[subprocess.CompletedProcess[str], list[dict[str, object]]]:
        """Run the command on a pty and return it with the add requests it sent."""
        case_dir = Path(tempfile.mkdtemp(dir=self.root))
        socket_path = case_dir / "cmux.sock"
        home = case_dir / "home"
        home.mkdir()
        path_dir = case_dir / "path-bin"
        path_dir.mkdir()
        if path_has_claude:
            self.fake_claude(path_dir, PATH_TOKEN)

        server = Server(str(socket_path), Handler)
        server.calls = []  # type: ignore[attr-defined]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        controller, terminal = pty.openpty()
        try:
            env = cli_environment(socket_path, home=home)
            env["PATH"] = f"{path_dir}:/usr/bin:/bin"
            env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
            env.pop("CMUX_CUSTOM_CLAUDE_PATH", None)
            if custom is not None:
                env["CMUX_CUSTOM_CLAUDE_PATH"] = custom
            try:
                proc = subprocess.run(
                    [self.cli, "--socket", str(socket_path),
                     "coderouter", "claude", "add", "oauth-token", "--label", "work"],
                    stdin=terminal, capture_output=True, text=True, check=False, env=env, timeout=20,
                )
            except subprocess.TimeoutExpired as error:
                # With no token from setup-token the command asks for one on the terminal.
                self.fail(f"setup-token produced no token and the command waited for input: {error.stderr!r}")
        finally:
            os.close(controller)
            os.close(terminal)
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        added = [params for method, params in server.calls  # type: ignore[attr-defined]
                 if method == "coderouter.claude_upstream.add"]
        return proc, added

    def assert_token(self, expected: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
        proc, added = self.add_oauth_token(**kwargs)  # type: ignore[arg-type]
        self.assertEqual(proc.returncode, 0, f"{proc.stdout}\n{proc.stderr}")
        self.assertEqual([params.get("token") for params in added], [expected], proc.stderr)
        return proc

    def test_configured_claude_mints_the_token(self) -> None:
        custom = self.fake_claude(self.root / "pinned", CUSTOM_TOKEN)
        proc = self.assert_token(CUSTOM_TOKEN, custom=str(custom))
        self.assertNotIn(CUSTOM_TOKEN, proc.stdout + proc.stderr)
        self.assertIn("[REDACTED]", proc.stdout)

    def test_configured_claude_is_used_when_path_has_none(self) -> None:
        custom = self.fake_claude(self.root / "pinned", CUSTOM_TOKEN)
        self.assert_token(CUSTOM_TOKEN, custom=f"  {custom}\n", path_has_claude=False)

    def test_claude_on_path_is_used_without_a_configured_one(self) -> None:
        proc = self.assert_token(PATH_TOKEN, custom=None)
        self.assertNotIn(PATH_TOKEN, proc.stdout + proc.stderr)
        self.assert_token(PATH_TOKEN, custom="")

    def test_unusable_configured_path_falls_back_to_path(self) -> None:
        not_executable = self.root / "plain" / "claude"
        not_executable.parent.mkdir()
        not_executable.write_text("#!/bin/sh\n")
        for custom in (str(self.root / "missing" / "claude"), str(self.root), str(not_executable)):
            with self.subTest(custom=custom):
                self.assert_token(PATH_TOKEN, custom=custom)

    def test_cmux_wrapper_as_the_configured_path_is_not_run(self) -> None:
        # Pointing the setting at cmux's own wrapper would hand setup-token to the
        # hook-injecting shim; the other launch paths skip it too.
        wrapper = self.fake_claude(self.root / "wrapper", CUSTOM_TOKEN, wrapper=True)
        self.assert_token(PATH_TOKEN, custom=str(wrapper))


if __name__ == "__main__":
    unittest.main()
