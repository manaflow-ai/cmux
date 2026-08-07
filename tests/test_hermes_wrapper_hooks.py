#!/usr/bin/env python3
"""Behavior checks for automatic Hermes Agent hook installation."""

from __future__ import annotations

import base64
import os
import signal
import shutil
import subprocess
import tempfile
import time
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
    installer_started: bool
    launch_observed: bool


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
    installer_blocks: bool = False,
    installer_timeout_seconds: float = 1,
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
        installer_started_log = tmp / "installer-started.log"
        installer_gate = tmp / "installer-gate"
        if installer_blocks:
            os.mkfifo(installer_gate)

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
if [[ -n "${FAKE_INSTALLER_GATE:-}" ]]; then
  : > "$FAKE_INSTALLER_STARTED_LOG"
  IFS= read -r _ < "$FAKE_INSTALLER_GATE"
fi
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
        env["FAKE_INSTALLER_STARTED_LOG"] = str(installer_started_log)
        if installer_blocks:
            env["FAKE_INSTALLER_GATE"] = str(installer_gate)
        else:
            env.pop("FAKE_INSTALLER_GATE", None)
        env["CMUX_HERMES_AGENT_HOOK_INSTALL_TIMEOUT_SECONDS"] = str(installer_timeout_seconds)
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

        proc = subprocess.Popen(
            [str(wrapper), *argv],
            cwd=tmp,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        deadline = time.monotonic() + 5
        launch_observed = not installer_blocks
        if installer_blocks:
            while time.monotonic() < deadline:
                if real_args_log.exists():
                    launch_observed = True
                    break
                if proc.poll() is not None:
                    break
                time.sleep(0.01)

        deadline_exceeded = False
        try:
            _, stderr = proc.communicate(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            deadline_exceeded = True
            os.killpg(proc.pid, signal.SIGKILL)
            _, stderr = proc.communicate()
        if deadline_exceeded:
            stderr = f"{stderr.strip()}\nwrapper execution deadline exceeded".strip()

        return WrapperResult(
            returncode=proc.returncode,
            real_argv=read_nul_values(real_args_log),
            real_environment=read_environment(real_env_log) if real_env_log.exists() else {},
            cmux_calls=read_calls(cmux_calls_log),
            cmux_environment=read_environment(cmux_env_log) if cmux_env_log.exists() else {},
            stderr=stderr.strip(),
            real_path=str(real_hermes),
            working_directory=os.path.realpath(tmp),
            socket_path=socket_path,
            installer_started=installer_started_log.exists(),
            launch_observed=launch_observed,
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


def test_stalled_installer_is_bounded(failures: list[str]) -> None:
    result = run_wrapper(
        ["--continue"],
        installer_blocks=True,
        installer_timeout_seconds=1,
    )
    expect(result.returncode == 0, f"stalled installer: wrapper exited {result.returncode}: {result.stderr}", failures)
    expect(result.installer_started, "stalled installer: fake installer did not start", failures)
    expect(result.launch_observed, "stalled installer: Hermes launch signal was not observed", failures)
    expect(result.real_argv == ["--continue"], f"stalled installer: argv changed: {result.real_argv}", failures)


def test_non_positive_installer_timeout_skips_setup(failures: list[str]) -> None:
    for timeout in (0, 0.0):
        result = run_wrapper(
            ["--continue"],
            installer_blocks=True,
            installer_timeout_seconds=timeout,
        )
        label = f"installer timeout {timeout!r}"
        expect(result.returncode == 0, f"{label}: wrapper exited {result.returncode}: {result.stderr}", failures)
        expect(result.launch_observed, f"{label}: Hermes launch signal was not observed", failures)
        expect(result.real_argv == ["--continue"], f"{label}: argv changed: {result.real_argv}", failures)
        expect(result.cmux_calls == [], f"{label}: installer should have been skipped: {result.cmux_calls}", failures)


def main() -> int:
    failures: list[str] = []
    if not SOURCE_WRAPPER.is_file():
        failures.append(f"missing Hermes launch wrapper: {SOURCE_WRAPPER}")
    else:
        test_session_entrypoints(failures)
        test_administrative_entrypoints_bypass_install(failures)
        test_opt_out_and_non_cmux_launches_bypass_install(failures)
        test_installer_failures_never_block_hermes(failures)
        test_stalled_installer_is_bounded(failures)
        test_non_positive_installer_timeout_skips_setup(failures)

    if failures:
        print("FAIL: Hermes session launches do not reliably activate cmux hooks")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: every interactive Hermes launch activates cmux hooks and preserves surface attribution")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
