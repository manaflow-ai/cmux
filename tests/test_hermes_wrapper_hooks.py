#!/usr/bin/env python3
"""Behavior checks for automatic Hermes Agent hook installation."""

from __future__ import annotations

import base64
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-hermes-agent-wrapper"
SESSION_ID = "01JZ123456789ABCDEFGHJKMNP"


@dataclass
class WrapperResult:
    returncode: int
    real_argv: list[str]
    real_environment: dict[str, str]
    cmux_calls: list[list[str]]
    cmux_environment: dict[str, str]
    stderr: str
    real_path: str
    working_directory: str
    socket_path: str


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_nul_values(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [part.decode("utf-8") for part in path.read_bytes().split(b"\0") if part]


def read_environment(path: Path) -> dict[str, str]:
    return dict(line.split("=", 1) for line in path.read_text(encoding="utf-8").splitlines())


def read_calls(path: Path) -> list[list[str]]:
    if not path.exists():
        return []
    calls: list[list[str]] = []
    for record in path.read_bytes().split(b"\x1e"):
        if not record:
            continue
        calls.append([part.decode("utf-8") for part in record.split(b"\0") if part])
    return calls


def run_wrapper(
    argv: list[str],
    *,
    in_cmux: bool = True,
    hooks_disabled: bool = False,
    installer_exit_code: int = 0,
    cli_available: bool = True,
) -> WrapperResult:
    with tempfile.TemporaryDirectory(prefix="cmux-hermes-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        shim_dir = tmp / "cmux-cli-shims" / "surface-test"
        real_dir = tmp / "real-bin"
        bundled_dir = tmp / "bundled cli"
        hermes_home = tmp / "hermes home"
        for directory in (wrapper_dir, shim_dir, real_dir, bundled_dir, hermes_home):
            directory.mkdir(parents=True)

        wrapper = wrapper_dir / "cmux-hermes-agent-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        # Match the real per-surface topology. The PATH candidate named
        # `hermes` points back to the wrapper, so resolution must skip it and
        # continue to the actual executable.
        shim = shim_dir / "hermes"
        shim.symlink_to(wrapper)

        real_args_log = tmp / "real-args.log"
        real_env_log = tmp / "real-env.log"
        cmux_calls_log = tmp / "cmux-calls.log"
        cmux_env_log = tmp / "cmux-env.log"

        real_hermes = real_dir / "hermes"
        make_executable(
            real_hermes,
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
printf '%s\\0' "$@" >> "$FAKE_REAL_ARGS_LOG"
{
  printf 'CMUX_SURFACE_ID=%s\\n' "${CMUX_SURFACE_ID-__UNSET__}"
  printf 'CMUX_WORKSPACE_ID=%s\\n' "${CMUX_WORKSPACE_ID-__UNSET__}"
  printf 'CMUX_SOCKET_PATH=%s\\n' "${CMUX_SOCKET_PATH-__UNSET__}"
  printf 'CMUX_BUNDLED_CLI_PATH=%s\\n' "${CMUX_BUNDLED_CLI_PATH-__UNSET__}"
  printf 'CMUX_HERMES_AGENT_PID=%s\\n' "${CMUX_HERMES_AGENT_PID-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_KIND=%s\\n' "${CMUX_AGENT_LAUNCH_KIND-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_EXECUTABLE=%s\\n' "${CMUX_AGENT_LAUNCH_EXECUTABLE-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_CWD=%s\\n' "${CMUX_AGENT_LAUNCH_CWD-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_ARGV_B64=%s\\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-__UNSET__}"
  printf 'CMUX_AGENT_RESTORE_LAUNCH=%s\\n' "${CMUX_AGENT_RESTORE_LAUNCH-__UNSET__}"
  printf 'HERMES_HOME=%s\\n' "${HERMES_HOME-__UNSET__}"
  printf 'REAL_PID=%s\\n' "$$"
} > "$FAKE_REAL_ENV_LOG"
""",
        )

        bundled_cli = bundled_dir / "cmux"
        if cli_available:
            make_executable(
                bundled_cli,
                """#!/usr/bin/env bash
set -euo pipefail
printf '\\036' >> "$FAKE_CMUX_CALLS_LOG"
printf '%s\\0' "$@" >> "$FAKE_CMUX_CALLS_LOG"
{
  printf 'CMUX_SURFACE_ID=%s\\n' "${CMUX_SURFACE_ID-__UNSET__}"
  printf 'CMUX_WORKSPACE_ID=%s\\n' "${CMUX_WORKSPACE_ID-__UNSET__}"
  printf 'CMUX_SOCKET_PATH=%s\\n' "${CMUX_SOCKET_PATH-__UNSET__}"
  printf 'HERMES_HOME=%s\\n' "${HERMES_HOME-__UNSET__}"
} > "$FAKE_CMUX_ENV_LOG"
exit "${FAKE_INSTALLER_EXIT_CODE:-0}"
""",
            )

        socket_path = str(tmp / "cmux.sock")
        env = os.environ.copy()
        env["PATH"] = f"{shim_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
        env["HERMES_HOME"] = str(hermes_home)
        env["CMUX_BUNDLED_CLI_PATH"] = str(bundled_cli)
        env["CMUX_HERMES_AGENT_WRAPPER_SHIM"] = str(shim)
        env["CMUX_HERMES_AGENT_WRAPPER_SHIM_ROOT"] = str(shim_dir)
        env["CMUX_AGENT_RESTORE_LAUNCH"] = f"hermes-agent:{SESSION_ID}"
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_REAL_ENV_LOG"] = str(real_env_log)
        env["FAKE_CMUX_CALLS_LOG"] = str(cmux_calls_log)
        env["FAKE_CMUX_ENV_LOG"] = str(cmux_env_log)
        env["FAKE_INSTALLER_EXIT_CODE"] = str(installer_exit_code)
        if in_cmux:
            env["CMUX_SURFACE_ID"] = "11111111-1111-1111-1111-111111111111"
            env["CMUX_WORKSPACE_ID"] = "22222222-2222-2222-2222-222222222222"
            env["CMUX_SOCKET_PATH"] = socket_path
        else:
            for key in ("CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_SOCKET_PATH"):
                env.pop(key, None)
        if hooks_disabled:
            env["CMUX_HERMES_AGENT_HOOKS_DISABLED"] = "1"
        else:
            env.pop("CMUX_HERMES_AGENT_HOOKS_DISABLED", None)

        proc = subprocess.run(
            [str(wrapper), *argv],
            cwd=tmp,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

        return WrapperResult(
            returncode=proc.returncode,
            real_argv=read_nul_values(real_args_log),
            real_environment=read_environment(real_env_log),
            cmux_calls=read_calls(cmux_calls_log),
            cmux_environment=read_environment(cmux_env_log) if cmux_env_log.exists() else {},
            stderr=proc.stderr.strip(),
            real_path=str(real_hermes),
            working_directory=str(tmp),
            socket_path=socket_path,
        )


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def decoded_launch_argv(environment: dict[str, str]) -> list[str]:
    encoded = environment.get("CMUX_AGENT_LAUNCH_ARGV_B64", "")
    if not encoded or encoded == "__UNSET__":
        return []
    raw = base64.b64decode(encoded)
    return [part.decode("utf-8") for part in raw.split(b"\0") if part]


def assert_instrumented(argv: list[str], label: str, failures: list[str]) -> None:
    result = run_wrapper(argv)
    expected_call = [
        "--socket",
        result.socket_path,
        "hooks",
        "hermes-agent",
        "install",
        "--yes",
    ]
    expect(result.returncode == 0, f"{label}: wrapper exited {result.returncode}: {result.stderr}", failures)
    expect(result.real_argv == argv, f"{label}: original argv changed: {result.real_argv}", failures)
    expect(result.cmux_calls == [expected_call], f"{label}: unexpected installer calls: {result.cmux_calls}", failures)
    expect(result.cmux_environment.get("CMUX_SURFACE_ID") == "11111111-1111-1111-1111-111111111111",
           f"{label}: installer lost surface attribution: {result.cmux_environment}", failures)
    expect(result.cmux_environment.get("CMUX_WORKSPACE_ID") == "22222222-2222-2222-2222-222222222222",
           f"{label}: installer lost workspace attribution: {result.cmux_environment}", failures)
    expect(result.real_environment.get("CMUX_SURFACE_ID") == "11111111-1111-1111-1111-111111111111",
           f"{label}: Hermes lost surface attribution: {result.real_environment}", failures)
    expect(result.real_environment.get("CMUX_WORKSPACE_ID") == "22222222-2222-2222-2222-222222222222",
           f"{label}: Hermes lost workspace attribution: {result.real_environment}", failures)
    expect(result.real_environment.get("CMUX_HERMES_AGENT_PID") == result.real_environment.get("REAL_PID"),
           f"{label}: Hermes PID identity does not match exec'd process: {result.real_environment}", failures)
    expect(result.real_environment.get("CMUX_AGENT_LAUNCH_KIND") == "hermes-agent",
           f"{label}: launch kind missing: {result.real_environment}", failures)
    expect(result.real_environment.get("CMUX_AGENT_LAUNCH_EXECUTABLE") == result.real_path,
           f"{label}: real executable was not captured: {result.real_environment}", failures)
    expect(result.real_environment.get("CMUX_AGENT_LAUNCH_CWD") == result.working_directory,
           f"{label}: launch cwd was not captured: {result.real_environment}", failures)
    expect(decoded_launch_argv(result.real_environment) == [result.real_path, *argv],
           f"{label}: launch argv was not captured: {decoded_launch_argv(result.real_environment)}", failures)
    expect(result.real_environment.get("CMUX_AGENT_RESTORE_LAUNCH") == "__UNSET__",
           f"{label}: one-shot restore authorization leaked to Hermes descendants", failures)


def test_session_entrypoints(failures: list[str]) -> None:
    entrypoints = (
        ("bare", []),
        ("chat", ["chat"]),
        ("resume", ["--resume", SESSION_ID, "--no-restore-cwd", "--pass-session-id"]),
        ("continue-latest", ["--continue"]),
        ("continue-name", ["--continue", "my project"]),
        ("oneshot", ["--oneshot", "report status"]),
        ("global-options", ["--provider", "openrouter", "--tui"]),
    )
    for label, argv in entrypoints:
        assert_instrumented(argv, label, failures)


def test_administrative_entrypoints_bypass_install(failures: list[str]) -> None:
    entrypoints = (
        ("help", ["--help"]),
        ("version", ["--version"]),
        ("sessions", ["sessions", "list"]),
        ("hooks", ["hooks", "doctor"]),
        ("doctor", ["doctor"]),
        ("option-before-admin", ["--provider", "openrouter", "sessions", "stats"]),
    )
    for label, argv in entrypoints:
        result = run_wrapper(argv)
        expect(result.returncode == 0, f"{label}: wrapper exited {result.returncode}: {result.stderr}", failures)
        expect(result.real_argv == argv, f"{label}: original argv changed: {result.real_argv}", failures)
        expect(result.cmux_calls == [], f"{label}: administrative command installed hooks: {result.cmux_calls}", failures)


def test_opt_out_and_non_cmux_launches_bypass_install(failures: list[str]) -> None:
    for label, kwargs in (
        ("disabled", {"hooks_disabled": True}),
        ("outside-cmux", {"in_cmux": False}),
    ):
        result = run_wrapper(["--resume", SESSION_ID], **kwargs)
        expect(result.returncode == 0, f"{label}: wrapper exited {result.returncode}: {result.stderr}", failures)
        expect(result.real_argv == ["--resume", SESSION_ID], f"{label}: argv changed: {result.real_argv}", failures)
        expect(result.cmux_calls == [], f"{label}: hooks were installed: {result.cmux_calls}", failures)


def test_installer_failures_never_block_hermes(failures: list[str]) -> None:
    for label, kwargs in (
        ("installer-error", {"installer_exit_code": 73}),
        ("installer-missing", {"cli_available": False}),
    ):
        result = run_wrapper(["--continue"], **kwargs)
        expect(result.returncode == 0, f"{label}: wrapper exited {result.returncode}: {result.stderr}", failures)
        expect(result.real_argv == ["--continue"], f"{label}: argv changed: {result.real_argv}", failures)


def main() -> int:
    failures: list[str] = []
    if not SOURCE_WRAPPER.is_file():
        failures.append(f"missing Hermes launch wrapper: {SOURCE_WRAPPER}")
    else:
        test_session_entrypoints(failures)
        test_administrative_entrypoints_bypass_install(failures)
        test_opt_out_and_non_cmux_launches_bypass_install(failures)
        test_installer_failures_never_block_hermes(failures)

    if failures:
        print("FAIL: Hermes session launches do not reliably activate cmux hooks")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: every interactive Hermes launch activates cmux hooks and preserves surface attribution")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
