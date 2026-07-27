#!/usr/bin/env python3
"""Behavior tests for the Codex wrapper's shared app-server fast path."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WRAPPER = REPO_ROOT / "Resources" / "bin" / "cmux-codex-wrapper"


class BoundUnixSocket:
    def __init__(self, path: Path):
        self.path = path
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    def __enter__(self) -> "BoundUnixSocket":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.socket.bind(str(self.path))
        self.socket.listen(1)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.socket.close()
        self.path.unlink(missing_ok=True)


class CodexWrapperSharedDaemonTests(unittest.TestCase):
    def setUp(self) -> None:
        # Darwin limits AF_UNIX paths to 104 bytes. Keep the fixture root under
        # the short /tmp spelling instead of the much longer per-user TMPDIR.
        self.temp_dir = tempfile.TemporaryDirectory(prefix="ct-", dir="/tmp")
        self.root = Path(self.temp_dir.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.output_path = self.root / "codex-output.json"
        self.cmux_log_path = self.root / "cmux-calls.log"
        self.codex_home = self.root / "codex-home"
        self.cmux_socket_path = self.root / "cmux.sock"
        self.daemon_socket_path = (
            self.codex_home
            / "app-server-control"
            / "app-server-control.sock"
        )

        self.real_codex = self.bin_dir / "real-codex"
        self.real_codex.write_text(
            """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

Path(os.environ["WRAPPER_TEST_OUTPUT"]).write_text(json.dumps({
    "argv": sys.argv[1:],
    "cmux_environment": sorted(
        key for key in os.environ if key.startswith("CMUX_")
    ),
}))
""",
            encoding="utf-8",
        )
        self.real_codex.chmod(0o755)

        self.fake_cmux = self.bin_dir / "cmux"
        self.fake_cmux.write_text(
            """#!/usr/bin/env python3
import os
import sys
from pathlib import Path

args = sys.argv[1:]
with Path(os.environ["WRAPPER_TEST_CMUX_LOG"]).open("a", encoding="utf-8") as log:
    log.write(" ".join(args) + "\\n")
if args[-4:] == ["hooks", "codex", "inject-args"]:
    pass
if len(args) >= 3 and args[-3:] == ["hooks", "codex", "inject-args"]:
    sys.stdout.buffer.write(b"--enable\\0hooks\\0--dangerously-bypass-hook-trust\\0")
sys.exit(0)
""",
            encoding="utf-8",
        )
        self.fake_cmux.chmod(0o755)

        self.environment = os.environ.copy()
        self.environment.update(
            {
                "CMUX_SURFACE_ID": "surface-test",
                "CMUX_WORKSPACE_ID": "workspace-test",
                "CMUX_SOCKET_PATH": str(self.cmux_socket_path),
                "CMUX_BUNDLED_CLI_PATH": str(self.fake_cmux),
                "CMUX_CUSTOM_CODEX_PATH": str(self.real_codex),
                "CODEX_HOME": str(self.codex_home),
                "WRAPPER_TEST_OUTPUT": str(self.output_path),
                "WRAPPER_TEST_CMUX_LOG": str(self.cmux_log_path),
                "PATH": f"{self.bin_dir}:{self.environment.get('PATH', '')}",
            }
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_wrapper(self, *arguments: str) -> tuple[dict, list[str]]:
        result = subprocess.run(
            [str(WRAPPER), *arguments],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(self.output_path.read_text(encoding="utf-8"))
        calls = (
            self.cmux_log_path.read_text(encoding="utf-8").splitlines()
            if self.cmux_log_path.exists()
            else []
        )
        return output, calls

    def test_live_daemon_uses_zero_subprocess_interactive_fast_path(self) -> None:
        with (
            BoundUnixSocket(self.cmux_socket_path),
            BoundUnixSocket(self.daemon_socket_path),
        ):
            output, calls = self.run_wrapper("--model", "gpt-test")

        self.assertEqual(output["argv"], ["--model", "gpt-test"])
        self.assertEqual(output["cmux_environment"], [])
        self.assertEqual(calls, [])

    def test_live_daemon_uses_zero_subprocess_resume_fast_path(self) -> None:
        with (
            BoundUnixSocket(self.cmux_socket_path),
            BoundUnixSocket(self.daemon_socket_path),
        ):
            output, calls = self.run_wrapper(
                "resume",
                "11111111-1111-1111-1111-111111111111",
            )

        self.assertEqual(
            output["argv"],
            ["resume", "11111111-1111-1111-1111-111111111111"],
        )
        self.assertEqual(calls, [])

    def test_exec_keeps_existing_hook_path_when_daemon_is_live(self) -> None:
        with (
            BoundUnixSocket(self.cmux_socket_path),
            BoundUnixSocket(self.daemon_socket_path),
        ):
            output, calls = self.run_wrapper("exec", "say hello")

        self.assertEqual(
            output["argv"][:3],
            ["--enable", "hooks", "--dangerously-bypass-hook-trust"],
        )
        self.assertEqual(output["argv"][3:], ["exec", "say hello"])
        self.assertTrue(any(call.endswith("ping") for call in calls), calls)
        self.assertTrue(
            any(call.endswith("hooks codex inject-args") for call in calls),
            calls,
        )

    def test_config_override_keeps_existing_hook_path_when_daemon_is_live(self) -> None:
        with (
            BoundUnixSocket(self.cmux_socket_path),
            BoundUnixSocket(self.daemon_socket_path),
        ):
            output, calls = self.run_wrapper("-c", "model_reasoning_effort=high")

        self.assertEqual(
            output["argv"][:3],
            ["--enable", "hooks", "--dangerously-bypass-hook-trust"],
        )
        self.assertEqual(
            output["argv"][3:],
            ["-c", "model_reasoning_effort=high"],
        )
        self.assertTrue(
            any(call.endswith("hooks codex inject-args") for call in calls),
            calls,
        )

    def test_missing_daemon_keeps_existing_hook_path(self) -> None:
        with BoundUnixSocket(self.cmux_socket_path):
            output, calls = self.run_wrapper()

        self.assertEqual(
            output["argv"],
            ["--enable", "hooks", "--dangerously-bypass-hook-trust"],
        )
        self.assertTrue(
            any(call.endswith("hooks codex inject-args") for call in calls),
            calls,
        )


if __name__ == "__main__":
    unittest.main()
