#!/usr/bin/env python3
"""Regression test for resume-scoped Codex trust override placement."""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-codex-wrapper"
SESSION_ID = "019f914e-44e3-75b2-9305-09f0818b32f0"
TRUST_OVERRIDE = (
    'projects={"/private/tmp/project.with.dot"={trust_level="untrusted"}}'
)


def make_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


class CodexWrapperResumeTrustTests(unittest.TestCase):
    def run_wrapper(
        self,
        arguments: list[str],
        *,
        resume_helper_mode: str = "override",
    ) -> tuple[list[str], str, subprocess.CompletedProcess[str]]:
        with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as raw:
            root = Path(raw)
            wrapper = root / "cmux-codex-wrapper"
            real_codex = root / "codex-real"
            fake_cmux = root / "cmux"
            args_log = root / "args.bin"
            cmux_log = root / "cmux.log"
            socket_path = root / "cmux.sock"

            shutil.copy2(SOURCE_WRAPPER, wrapper)
            wrapper.chmod(0o755)
            make_executable(
                real_codex,
                """#!/usr/bin/env bash
printf '%s\\0' "$@" > "$FAKE_CODEX_ARGS_LOG"
sleep 0.2
""",
            )
            make_executable(
                fake_cmux,
                f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_CMUX_LOG"
if [[ "${{1:-}}" == "--socket" ]]; then
  shift 2
fi
if [[ "${{1:-}}" == "ping" ]]; then
  exit 0
fi
if [[ "${{@: -1}}" == "session-start" ]]; then
  printf 'payload=%s\\n' "$(cat)" >> "$FAKE_CMUX_LOG"
  exit 0
fi
case "${{@: -1}}" in
  inject-args)
    printf '%s\\0' --enable hooks
    ;;
  inject-resume-args)
    case "${{FAKE_RESUME_HELPER_MODE:-override}}" in
      empty)
        ;;
      partial)
        printf '%s\\0' -c
        exit 17
        ;;
      override)
        printf '%s\\0' -c '{TRUST_OVERRIDE}'
        ;;
    esac
    ;;
esac
""",
            )

            live_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            live_socket.bind(str(socket_path))
            env = os.environ.copy()
            env.update(
                {
                    "CMUX_BUNDLED_CLI_PATH": str(fake_cmux),
                    "CMUX_CUSTOM_CODEX_PATH": str(real_codex),
                    "CMUX_SOCKET_PATH": str(socket_path),
                    "CMUX_SURFACE_ID": "surface:test",
                    "FAKE_CODEX_ARGS_LOG": str(args_log),
                    "FAKE_CMUX_LOG": str(cmux_log),
                    "FAKE_RESUME_HELPER_MODE": resume_helper_mode,
                }
            )
            try:
                result = subprocess.run(
                    [str(wrapper), *arguments],
                    cwd=root,
                    env=env,
                    capture_output=True,
                    text=True,
                    check=False,
                )
            finally:
                live_socket.close()

            args = args_log.read_bytes().rstrip(b"\0").decode().split("\0")
            return args, cmux_log.read_text(), result

    def test_resume_trust_override_is_appended_after_resume_arguments(self) -> None:
        args, logged_cmux_calls, result = self.run_wrapper(
            ["resume", SESSION_ID, "--yolo"]
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            args,
            [
                "--enable",
                "hooks",
                "resume",
                SESSION_ID,
                "--yolo",
                "-c",
                TRUST_OVERRIDE,
            ],
        )
        self.assertIn("hooks codex inject-resume-args", logged_cmux_calls)
        self.assertIn('"cmux_resume_rebind":true', logged_cmux_calls)

    def test_last_and_named_resume_receive_trust_override(self) -> None:
        for arguments in (["resume", "--last"], ["resume", "session-name"]):
            with self.subTest(arguments=arguments):
                args, logged_cmux_calls, result = self.run_wrapper(arguments)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    args,
                    [
                        "--enable",
                        "hooks",
                        *arguments,
                        "-c",
                        TRUST_OVERRIDE,
                    ],
                )
                self.assertIn("hooks codex inject-resume-args", logged_cmux_calls)

    def test_resume_trust_override_precedes_end_of_options(self) -> None:
        args, logged_cmux_calls, result = self.run_wrapper(
            ["resume", SESSION_ID, "--", "-fix"]
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            args,
            [
                "--enable",
                "hooks",
                "resume",
                SESSION_ID,
                "-c",
                TRUST_OVERRIDE,
                "--",
                "-fix",
            ],
        )
        self.assertIn("hooks codex inject-resume-args", logged_cmux_calls)
        self.assertIn('"cmux_resume_rebind":true', logged_cmux_calls)

    def test_profile_value_named_resume_does_not_emit_rebind(self) -> None:
        _, logged_cmux_calls, result = self.run_wrapper(
            ["--profile", "resume", SESSION_ID]
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('"cmux_resume_rebind":true', logged_cmux_calls)

    def test_fresh_launch_does_not_query_resume_trust(self) -> None:
        args, logged_cmux_calls, result = self.run_wrapper(["--yolo"])

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args, ["--enable", "hooks", "--yolo"])
        self.assertNotIn("hooks codex inject-resume-args", logged_cmux_calls)

    def test_resume_helper_empty_or_failed_partial_output_is_discarded(self) -> None:
        for mode in ("empty", "partial"):
            with self.subTest(mode=mode):
                args, _, result = self.run_wrapper(
                    ["resume", SESSION_ID],
                    resume_helper_mode=mode,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    args,
                    [
                        "--enable",
                        "hooks",
                        "resume",
                        SESSION_ID,
                    ],
                )


if __name__ == "__main__":
    unittest.main()
