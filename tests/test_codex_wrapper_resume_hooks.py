#!/usr/bin/env python3
"""Regression checks for reliable Codex hook injection during cmux resume."""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-codex-wrapper"
SESSION_ID = "0198f073-0a5b-7000-8000-000000000059"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8").splitlines()


def run_wrapper(
    *,
    socket_state: str,
    argv: list[str],
    hooks_disabled: bool = False,
) -> tuple[int, list[str], list[str], dict[str, str], str]:
    with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        bundled_dir = tmp / "bundled cli"
        wrapper_dir.mkdir()
        real_dir.mkdir()
        bundled_dir.mkdir()

        wrapper = wrapper_dir / "cmux-codex-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        real_env_log = tmp / "real-env.log"
        cmux_log = tmp / "cmux.log"
        socket_path = tmp / "cmux.sock"

        make_executable(
            real_dir / "codex",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"
done
{
  printf 'CMUX_CODEX_PID=%s\\n' "${CMUX_CODEX_PID-__UNSET__}"
  printf 'CMUX_CODEX_HOOK_CMUX_BIN=%s\\n' "${CMUX_CODEX_HOOK_CMUX_BIN-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_KIND=%s\\n' "${CMUX_AGENT_LAUNCH_KIND-__UNSET__}"
} > "$FAKE_REAL_ENV_LOG"
""",
        )

        bundled_cli = bundled_dir / "cmux"
        make_executable(
            bundled_cli,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_CMUX_LOG"
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  exit 1
fi
if [[ "${1:-}" == "hooks" && "${2:-}" == "codex" && "${3:-}" == "inject-args" ]]; then
  printf '%s\\0' \
    '--enable' \
    'hooks' \
    '--dangerously-bypass-hook-trust' \
    '-c' \
    'hooks.SessionStart=[{hooks=[{type="command",command="fake-session-start",timeout=10000}]}]' \
    '-c' \
    'hooks.Stop=[{hooks=[{type="command",command="fake-stop",timeout=10000}]}]'
  exit 0
fi
if [[ "${1:-}" == "hooks" && "${2:-}" == "codex" && "${3:-}" == "session-start" ]]; then
  cat >/dev/null
  exit 0
fi
exit 1
""",
        )

        test_socket: socket.socket | None = None
        if socket_state == "stale":
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(str(socket_path))

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
        env["HOME"] = str(tmp / "home")
        env["CMUX_SURFACE_ID"] = "11111111-1111-1111-1111-111111111111"
        env["CMUX_WORKSPACE_ID"] = "22222222-2222-2222-2222-222222222222"
        env["CMUX_SOCKET_PATH"] = str(socket_path)
        env["CMUX_BUNDLED_CLI_PATH"] = str(bundled_cli)
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_REAL_ENV_LOG"] = str(real_env_log)
        env["FAKE_CMUX_LOG"] = str(cmux_log)
        if hooks_disabled:
            env["CMUX_CODEX_HOOKS_DISABLED"] = "1"
        else:
            env.pop("CMUX_CODEX_HOOKS_DISABLED", None)

        try:
            proc = subprocess.run(
                [str(wrapper), *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            if test_socket is not None:
                test_socket.close()

        observed_env = dict(line.split("=", 1) for line in read_lines(real_env_log))
        return proc.returncode, read_lines(real_args_log), read_lines(cmux_log), observed_env, proc.stderr.strip()


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def assert_resume_is_instrumented(socket_state: str, failures: list[str]) -> None:
    code, real_argv, cmux_log, observed_env, stderr = run_wrapper(
        socket_state=socket_state,
        argv=["resume", SESSION_ID],
    )
    label = f"resume/{socket_state}"
    expect(code == 0, f"{label}: wrapper exited {code}: {stderr}", failures)
    expect(real_argv[:3] == ["--enable", "hooks", "--dangerously-bypass-hook-trust"],
           f"{label}: missing injected hook prefix: {real_argv}", failures)
    expect(any(arg.startswith("hooks.SessionStart=") for arg in real_argv),
           f"{label}: missing SessionStart hook: {real_argv}", failures)
    expect(any(arg.startswith("hooks.Stop=") for arg in real_argv),
           f"{label}: missing Stop hook: {real_argv}", failures)
    expect(real_argv[-2:] == ["resume", SESSION_ID],
           f"{label}: resume argv was not preserved: {real_argv}", failures)
    expect(any("hooks codex inject-args" in line for line in cmux_log),
           f"{label}: wrapper never requested local hook args: {cmux_log}", failures)
    expect(not any("ping" in line for line in cmux_log),
           f"{label}: transient socket health must not decide session instrumentation: {cmux_log}", failures)
    expect(observed_env.get("CMUX_CODEX_PID") not in {None, "", "__UNSET__"},
           f"{label}: missing Codex process identity: {observed_env}", failures)
    expect(observed_env.get("CMUX_AGENT_LAUNCH_KIND") == "codex",
           f"{label}: missing launch kind: {observed_env}", failures)


def test_resume_hook_injection_survives_transient_startup_outages(failures: list[str]) -> None:
    # Repeat both startup failure shapes to guard against a statistical regression
    # where any single launch silently loses its hooks for the full agent lifetime.
    for _ in range(12):
        assert_resume_is_instrumented("missing", failures)
        assert_resume_is_instrumented("stale", failures)


def test_explicit_disable_still_bypasses_hooks(failures: list[str]) -> None:
    code, real_argv, cmux_log, _, stderr = run_wrapper(
        socket_state="stale",
        argv=["resume", SESSION_ID],
        hooks_disabled=True,
    )
    expect(code == 0, f"disabled: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["resume", SESSION_ID], f"disabled: expected passthrough, got {real_argv}", failures)
    expect(cmux_log == [], f"disabled: expected no cmux calls, got {cmux_log}", failures)


def test_non_session_command_still_bypasses_hooks(failures: list[str]) -> None:
    code, real_argv, cmux_log, _, stderr = run_wrapper(
        socket_state="stale",
        argv=["--help"],
    )
    expect(code == 0, f"help: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["--help"], f"help: expected passthrough, got {real_argv}", failures)
    expect(cmux_log == [], f"help: expected no cmux calls, got {cmux_log}", failures)


def main() -> int:
    failures: list[str] = []
    test_resume_hook_injection_survives_transient_startup_outages(failures)
    test_explicit_disable_still_bypasses_hooks(failures)
    test_non_session_command_still_bypasses_hooks(failures)
    if failures:
        print("FAIL: Codex resume wrapper reliability checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: every cmux-owned Codex resume launch retains SessionStart and Stop hooks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
