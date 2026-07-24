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
        hostile_bash_on_path: bool = False,
        trusted_codex_from_home: bool = False,
        trusted_codex_from_custom_path: bool = False,
        hostile_codex_on_path: bool = False,
        effective_project_codex_on_path: bool = False,
        project_codex_passthrough: bool = False,
        custom_codex_is_symlink: bool = False,
    ) -> tuple[list[str], str, subprocess.CompletedProcess[str]]:
        with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as raw:
            root = Path(raw)
            home = root / "home"
            project = root / "project"
            working_directory = project / "nested"
            effective_project = root / "effective-project"
            wrapper = root / "cmux-codex-wrapper"
            real_codex = (
                home / ".local" / "bin" / "codex"
                if trusted_codex_from_home
                else (
                    home / "Library" / "pnpm" / "codex"
                    if trusted_codex_from_custom_path
                    else root / "codex-real"
                )
            )
            fake_cmux = root / "cmux"
            args_log = root / "args.bin"
            cmux_log = root / "cmux.log"
            socket_path = root / "cmux.sock"
            hostile_bin = project / "hostile-bin"
            project_bin = project / "bin"
            effective_project_bin = effective_project / "bin"

            shutil.copy2(SOURCE_WRAPPER, wrapper)
            wrapper.chmod(0o755)
            (project / ".git").mkdir(parents=True)
            working_directory.mkdir()
            (effective_project / ".git").mkdir(parents=True)
            real_codex.parent.mkdir(parents=True, exist_ok=True)
            real_codex_target = (
                real_codex.with_name("codex.js")
                if custom_codex_is_symlink
                else real_codex
            )
            make_executable(
                real_codex_target,
                """#!/bin/bash
printf '%s\\0' "$@" > "$FAKE_CODEX_ARGS_LOG"
printf 'codex-path=%s\\n' "$PATH" >> "$FAKE_CMUX_LOG"
printf 'launch-executable=%s\\n' "${CMUX_AGENT_LAUNCH_EXECUTABLE:-}" >> "$FAKE_CMUX_LOG"
printf 'process-lease=%s\\n' "${CMUX_CODEX_PROCESS_LEASE_ID:-}" >> "$FAKE_CMUX_LOG"
sleep 0.2
""",
            )
            if custom_codex_is_symlink:
                real_codex.symlink_to(real_codex_target.name)
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
      truncated)
        printf '%s' -c
        ;;
      wrong_arity)
        printf '%s\\0' -c
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
                    "CMUX_SOCKET_PATH": str(socket_path),
                    "CMUX_SURFACE_ID": "surface:test",
                    "FAKE_CODEX_ARGS_LOG": str(args_log),
                    "FAKE_CMUX_LOG": str(cmux_log),
                    "FAKE_RESUME_HELPER_MODE": resume_helper_mode,
                    "HOME": str(home),
                }
            )
            if (
                not trusted_codex_from_home
                and not trusted_codex_from_custom_path
                and not project_codex_passthrough
            ):
                env["CMUX_CUSTOM_CODEX_PATH"] = str(real_codex)
            if hostile_bash_on_path or hostile_codex_on_path:
                hostile_bin.mkdir(parents=True)
            if hostile_bash_on_path:
                make_executable(
                    hostile_bin / "bash",
                    """#!/bin/sh
exit 97
""",
                )
            if hostile_codex_on_path:
                make_executable(
                    hostile_bin / "codex",
                    """#!/bin/sh
printf 'hostile-codex-ran\\n' >> "$FAKE_CMUX_LOG"
exit 98
""",
                )
            if effective_project_codex_on_path:
                effective_project_bin.mkdir()
                make_executable(
                    effective_project_bin / "codex",
                    """#!/bin/sh
printf 'effective-project-codex-ran\\n' >> "$FAKE_CMUX_LOG"
exit 98
""",
                )
            if project_codex_passthrough:
                project_bin.mkdir()
                make_executable(
                    project_bin / "codex",
                    """#!/bin/bash
printf '%s\\0' "$@" > "$FAKE_CODEX_ARGS_LOG"
""",
                )
                env["CMUX_CODEX_HOOKS_DISABLED"] = "1"
            lookup_path = "/usr/bin:/bin"
            if trusted_codex_from_custom_path:
                lookup_path = f"{lookup_path}:{real_codex.parent}"
            if effective_project_codex_on_path:
                lookup_path = f"{effective_project_bin}:{lookup_path}"
            if project_codex_passthrough:
                lookup_path = f"{project_bin}:{lookup_path}"
            if hostile_bash_on_path or hostile_codex_on_path:
                lookup_path = f"{hostile_bin}:{lookup_path}"
            env["PATH"] = lookup_path
            arguments = [
                str(effective_project) if arg == "{effective-project}" else arg
                for arg in arguments
            ]
            try:
                result = subprocess.run(
                    [str(wrapper), *arguments],
                    cwd=working_directory,
                    env=env,
                    capture_output=True,
                    text=True,
                    check=False,
                )
            finally:
                live_socket.close()

            args = (
                args_log.read_bytes().rstrip(b"\0").decode().split("\0")
                if args_log.exists()
                else []
            )
            return args, cmux_log.read_text() if cmux_log.exists() else "", result

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

    def test_resume_trust_override_skips_option_value_named_end_of_options(
        self,
    ) -> None:
        args, _, result = self.run_wrapper(
            ["resume", SESSION_ID, "--add-dir", "--", "--", "-fix"]
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            args,
            [
                "--enable",
                "hooks",
                "resume",
                SESSION_ID,
                "--add-dir",
                "--",
                "-c",
                TRUST_OVERRIDE,
                "--",
                "-fix",
            ],
        )

    def test_profile_value_named_resume_does_not_emit_rebind(self) -> None:
        _, logged_cmux_calls, result = self.run_wrapper(
            ["--profile", "resume", SESSION_ID]
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('"cmux_resume_rebind":true', logged_cmux_calls)

    def test_attached_short_option_values_before_resume_receive_trust_override(
        self,
    ) -> None:
        for option in (
            "-cmodel=gpt-5.6",
            "-iimage.png",
            "-mgpt-5.6",
            "-pdogfood",
            "-sread-only",
            "-C/private/tmp/project.with.dot",
            "-anever",
        ):
            with self.subTest(option=option):
                args, logged_cmux_calls, result = self.run_wrapper(
                    [option, "resume", SESSION_ID]
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    args,
                    [
                        "--enable",
                        "hooks",
                        option,
                        "resume",
                        SESSION_ID,
                        "-c",
                        TRUST_OVERRIDE,
                    ],
                )
                self.assertIn(
                    "hooks codex inject-resume-args",
                    logged_cmux_calls,
                )
                self.assertIn(
                    '"cmux_resume_rebind":true',
                    logged_cmux_calls,
                )

    def test_fresh_launch_does_not_query_resume_trust(self) -> None:
        args, logged_cmux_calls, result = self.run_wrapper(["--yolo"])

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args, ["--enable", "hooks", "--yolo"])
        self.assertNotIn("hooks codex inject-resume-args", logged_cmux_calls)
        self.assertRegex(
            logged_cmux_calls,
            r"(?m)^process-lease=[0-9A-F-]{36}$",
        )

    def test_fork_session_receives_hooks_without_resume_trust(self) -> None:
        args, logged_cmux_calls, result = self.run_wrapper(
            ["fork", SESSION_ID, "--yolo"]
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            args,
            [
                "--enable",
                "hooks",
                "fork",
                SESSION_ID,
                "--yolo",
            ],
        )
        self.assertIn("hooks codex inject-args", logged_cmux_calls)
        self.assertNotIn("hooks codex inject-resume-args", logged_cmux_calls)
        self.assertNotIn('"cmux_resume_rebind":true', logged_cmux_calls)

    def test_project_path_cannot_replace_wrapper_interpreter(self) -> None:
        args, logged_cmux_calls, result = self.run_wrapper(
            ["--yolo"],
            hostile_bash_on_path=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args, ["--enable", "hooks", "--yolo"])
        self.assertRegex(
            logged_cmux_calls,
            r"(?m)^codex-path=.*hostile-bin",
        )

    def test_project_path_cannot_select_codex_before_trust(self) -> None:
        args, logged_cmux_calls, result = self.run_wrapper(
            ["--yolo"],
            trusted_codex_from_home=True,
            hostile_codex_on_path=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args, ["--enable", "hooks", "--yolo"])
        self.assertNotIn("hostile-codex-ran", logged_cmux_calls)

    def test_custom_install_outside_project_beats_project_path_candidate(
        self,
    ) -> None:
        args, logged_cmux_calls, result = self.run_wrapper(
            ["--yolo"],
            trusted_codex_from_custom_path=True,
            hostile_codex_on_path=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args, ["--enable", "hooks", "--yolo"])
        self.assertNotIn("hostile-codex-ran", logged_cmux_calls)

    def test_symlink_install_preserves_codex_launch_identity(self) -> None:
        _, logged_cmux_calls, result = self.run_wrapper(
            ["--yolo"],
            trusted_codex_from_custom_path=True,
            custom_codex_is_symlink=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(
            logged_cmux_calls,
            r"(?m)^launch-executable=.*/Library/pnpm/codex$",
        )

    def test_effective_cd_project_cannot_select_codex_before_trust(self) -> None:
        args, logged_cmux_calls, result = self.run_wrapper(
            ["-C", "{effective-project}", "--yolo"],
            trusted_codex_from_custom_path=True,
            effective_project_codex_on_path=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[:3], ["--enable", "hooks", "-C"])
        self.assertEqual(args[-1], "--yolo")
        self.assertNotIn("effective-project-codex-ran", logged_cmux_calls)

    def test_hooks_opt_out_preserves_project_local_codex_passthrough(self) -> None:
        args, _, result = self.run_wrapper(
            ["resume", SESSION_ID],
            project_codex_passthrough=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args, ["resume", SESSION_ID])

    def test_resume_helper_empty_or_failed_partial_output_is_discarded(self) -> None:
        for mode in ("empty", "partial", "truncated", "wrong_arity"):
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
