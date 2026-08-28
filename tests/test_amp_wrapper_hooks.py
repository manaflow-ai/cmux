#!/usr/bin/env python3
"""Behavior checks for automatic Amp session-extension installation."""

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
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-amp-wrapper"


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
    if not path.exists():
        return {}
    return dict(line.split("=", 1) for line in path.read_text(encoding="utf-8").splitlines())


def read_calls(path: Path) -> list[list[str]]:
    if not path.exists():
        return []
    calls: list[list[str]] = []
    for record in path.read_bytes().split(b"\x1e"):
        if record:
            calls.append([part.decode("utf-8") for part in record.split(b"\0") if part])
    return calls


def run_wrapper(
    argv: list[str],
    *,
    in_cmux: bool = True,
    hooks_disabled: bool = False,
    installer_exit_code: int = 0,
    installer_blocks: bool = False,
    installer_timeout_seconds: float = 3,
    cli_available: bool = True,
    custom_executable: bool = False,
    path_glob_decoy: bool = False,
    amp_available: bool = True,
    workspace_only: bool = False,
) -> WrapperResult:
    with tempfile.TemporaryDirectory(prefix="cmux-amp-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        shim_dir = tmp / "cmux-cli-shims" / "surface-test"
        real_dir = tmp / "real-bin"
        custom_dir = tmp / "custom-bin"
        bundled_dir = tmp / "bundled cli"
        for directory in (wrapper_dir, shim_dir, real_dir, custom_dir, bundled_dir):
            directory.mkdir(parents=True)

        wrapper = wrapper_dir / "cmux-amp-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)
        shim = shim_dir / "amp"
        shim.symlink_to(wrapper)

        real_args_log = tmp / "real-args.log"
        real_env_log = tmp / "real-env.log"
        cmux_calls_log = tmp / "cmux-calls.log"
        cmux_env_log = tmp / "cmux-env.log"
        installer_started_log = tmp / "installer-started.log"
        installer_gate = tmp / "installer-gate"
        if installer_blocks:
            os.mkfifo(installer_gate)

        real_amp = (custom_dir if custom_executable else real_dir) / "amp"
        if amp_available:
            make_executable(
                real_amp,
                """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
printf '%s\\0' "$@" >> "$FAKE_REAL_ARGS_LOG"
{
  printf 'CMUX_SURFACE_ID=%s\\n' "${CMUX_SURFACE_ID-__UNSET__}"
  printf 'CMUX_WORKSPACE_ID=%s\\n' "${CMUX_WORKSPACE_ID-__UNSET__}"
  printf 'CMUX_SOCKET_PATH=%s\\n' "${CMUX_SOCKET_PATH-__UNSET__}"
  printf 'CMUX_AMP_PID=%s\\n' "${CMUX_AMP_PID-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_KIND=%s\\n' "${CMUX_AGENT_LAUNCH_KIND-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_EXECUTABLE=%s\\n' "${CMUX_AGENT_LAUNCH_EXECUTABLE-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_CWD=%s\\n' "${CMUX_AGENT_LAUNCH_CWD-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_ARGV_B64=%s\\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-__UNSET__}"
  printf 'CMUX_AGENT_RESTORE_LAUNCH=%s\\n' "${CMUX_AGENT_RESTORE_LAUNCH-__UNSET__}"
  printf 'CMUX_AGENT_RESUME_LAUNCH=%s\\n' "${CMUX_AGENT_RESUME_LAUNCH-__UNSET__}"
  printf 'AMP_API_KEY=%s\\n' "${AMP_API_KEY-__UNSET__}"
  printf 'REAL_PID=%s\\n' "$$"
} > "$FAKE_REAL_ENV_LOG"
""",
            )
        glob_path_entry = tmp / "amp-path-*"
        if path_glob_decoy:
            decoy_directory = tmp / "amp-path-decoy"
            decoy_directory.mkdir()
            decoy_amp = decoy_directory / "amp"
            shutil.copy2(real_amp, decoy_amp)
            decoy_amp.chmod(0o755)

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
  printf 'AMP_API_KEY=%s\\n' "${AMP_API_KEY-__UNSET__}"
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
        path_entries = [str(shim_dir)]
        if path_glob_decoy:
            path_entries.append(str(glob_path_entry))
        if amp_available:
            path_entries.append(str(real_dir))
        else:
            path_entries.append(str(tmp / "empty-bin"))
        # Keep the fixture hermetic: a developer machine may have an unrelated
        # `amp` executable on PATH that would bypass the missing-agent case (or
        # block the wrapper while the test is waiting for its child).
        path_entries.append("/usr/bin:/bin")
        env["PATH"] = os.pathsep.join(path_entries)
        env["CMUX_BUNDLED_CLI_PATH"] = str(bundled_cli)
        env["CMUX_AMP_WRAPPER_SHIM"] = str(shim)
        env["CMUX_AMP_WRAPPER_SHIM_ROOT"] = str(shim_dir)
        env.pop("CMUX_CUSTOM_AMP_PATH", None)
        env["CMUX_AGENT_RESTORE_LAUNCH"] = "amp:T-old-thread"
        env["CMUX_AGENT_RESUME_LAUNCH"] = "1"
        env["AMP_API_KEY"] = "amp-secret-must-not-reach-installer"
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_REAL_ENV_LOG"] = str(real_env_log)
        env["FAKE_CMUX_CALLS_LOG"] = str(cmux_calls_log)
        env["FAKE_CMUX_ENV_LOG"] = str(cmux_env_log)
        env["FAKE_INSTALLER_EXIT_CODE"] = str(installer_exit_code)
        env["FAKE_INSTALLER_STARTED_LOG"] = str(installer_started_log)
        env["CMUX_AMP_HOOK_INSTALL_TIMEOUT_SECONDS"] = str(installer_timeout_seconds)
        if custom_executable:
            env["CMUX_CUSTOM_AMP_PATH"] = str(real_amp)
        if installer_blocks:
            env["FAKE_INSTALLER_GATE"] = str(installer_gate)
        if in_cmux:
            env["CMUX_WORKSPACE_ID"] = "22222222-2222-2222-2222-222222222222"
            env["CMUX_SOCKET_PATH"] = socket_path
            if not workspace_only:
                env["CMUX_SURFACE_ID"] = "11111111-1111-1111-1111-111111111111"
        else:
            for key in ("CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_SOCKET_PATH"):
                env.pop(key, None)
        if hooks_disabled:
            env["CMUX_AMP_HOOKS_DISABLED"] = "1"
        else:
            env.pop("CMUX_AMP_HOOKS_DISABLED", None)

        proc = subprocess.Popen(
            [str(wrapper), *argv],
            cwd=tmp,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        # Leave scheduler headroom for busy CI hosts. The wrapper's own alarm is
        # still one second in the stalled-installer case below.
        deadline = time.monotonic() + 10
        launch_observed = not installer_blocks
        if installer_blocks:
            while time.monotonic() < deadline:
                if real_args_log.exists():
                    launch_observed = True
                    break
                if proc.poll() is not None:
                    break
                time.sleep(0.01)
        try:
            _, stderr = proc.communicate(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            _, stderr = proc.communicate()
            stderr = f"{stderr.strip()}\nwrapper execution deadline exceeded".strip()

        return WrapperResult(
            returncode=proc.returncode,
            real_argv=read_nul_values(real_args_log),
            real_environment=read_environment(real_env_log),
            cmux_calls=read_calls(cmux_calls_log),
            cmux_environment=read_environment(cmux_env_log),
            stderr=stderr.strip(),
            real_path=str(real_amp),
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
    return [part.decode("utf-8") for part in base64.b64decode(encoded).split(b"\0") if part]


def test_instrumented_launch(failures: list[str]) -> None:
    argv = ["threads", "continue", "T-current", "--mode", "smart", "--effort", "high"]
    result = run_wrapper(argv, custom_executable=True)
    expected_call = ["--socket", result.socket_path, "hooks", "amp", "install", "--yes"]
    expect(result.returncode == 0, f"wrapper exited {result.returncode}: {result.stderr}", failures)
    expect(result.real_argv == argv, f"original argv changed: {result.real_argv}", failures)
    expect(result.cmux_calls == [expected_call], f"unexpected installer calls: {result.cmux_calls}", failures)
    expect(result.cmux_environment.get("CMUX_SURFACE_ID") == "11111111-1111-1111-1111-111111111111",
           f"installer lost surface attribution: {result.cmux_environment}", failures)
    expect(result.cmux_environment.get("CMUX_WORKSPACE_ID") == "22222222-2222-2222-2222-222222222222",
           f"installer lost workspace attribution: {result.cmux_environment}", failures)
    expect(result.cmux_environment.get("AMP_API_KEY") == "__UNSET__",
           f"installer inherited AMP_API_KEY: {result.cmux_environment}", failures)
    expect(result.real_environment.get("AMP_API_KEY") == "amp-secret-must-not-reach-installer",
           f"Amp lost its own credentials: {result.real_environment}", failures)
    expect(result.real_environment.get("CMUX_AMP_PID") == result.real_environment.get("REAL_PID"),
           f"Amp PID identity does not match exec'd process: {result.real_environment}", failures)
    expect(result.real_environment.get("CMUX_AGENT_LAUNCH_KIND") == "amp",
           f"launch kind missing: {result.real_environment}", failures)
    expect(result.real_environment.get("CMUX_AGENT_LAUNCH_EXECUTABLE") == result.real_path,
           f"custom executable was not captured: {result.real_environment}", failures)
    expect(result.real_environment.get("CMUX_AGENT_LAUNCH_CWD") == result.working_directory,
           f"launch cwd was not captured: {result.real_environment}", failures)
    expect(decoded_launch_argv(result.real_environment) == [result.real_path, *argv],
           f"launch argv was not captured: {decoded_launch_argv(result.real_environment)}", failures)
    expect(result.real_environment.get("CMUX_AGENT_RESTORE_LAUNCH") == "__UNSET__",
           "one-shot restore authorization leaked to Amp descendants", failures)
    expect(result.real_environment.get("CMUX_AGENT_RESUME_LAUNCH") == "__UNSET__",
           "legacy resume marker leaked to Amp descendants", failures)


def test_bypass_paths(failures: list[str]) -> None:
    for label, kwargs in (
        ("disabled", {"hooks_disabled": True}),
        ("outside-cmux", {"in_cmux": False}),
    ):
        result = run_wrapper(["--help"], **kwargs)
        expect(result.returncode == 0, f"{label}: wrapper exited {result.returncode}: {result.stderr}", failures)
        expect(result.real_argv == ["--help"], f"{label}: argv changed: {result.real_argv}", failures)
        expect(result.cmux_calls == [], f"{label}: hooks were installed: {result.cmux_calls}", failures)


def test_installer_failures_never_block_amp(failures: list[str]) -> None:
    for label, kwargs in (
        ("installer-error", {"installer_exit_code": 73}),
        ("installer-missing", {"cli_available": False}),
    ):
        result = run_wrapper(["--mode", "smart"], **kwargs)
        expect(result.returncode == 0, f"{label}: wrapper exited {result.returncode}: {result.stderr}", failures)
        expect(result.real_argv == ["--mode", "smart"], f"{label}: argv changed: {result.real_argv}", failures)


def test_stalled_installer_is_bounded(failures: list[str]) -> None:
    result = run_wrapper(
        ["threads", "continue", "T-bounded"],
        installer_blocks=True,
        installer_timeout_seconds=1,
    )
    expect(result.returncode == 0, f"stalled installer: wrapper exited {result.returncode}: {result.stderr}", failures)
    expect(result.installer_started, "stalled installer: fake installer did not start", failures)
    expect(result.launch_observed, "stalled installer: Amp launch was not observed", failures)
    expect(result.real_argv == ["threads", "continue", "T-bounded"],
           f"stalled installer: argv changed: {result.real_argv}", failures)


def test_path_globs_do_not_redirect_amp_resolution(failures: list[str]) -> None:
    result = run_wrapper(["--mode", "smart"], path_glob_decoy=True)
    expect(result.returncode == 0, f"glob PATH: wrapper exited {result.returncode}: {result.stderr}", failures)
    expect(
        result.real_environment.get("CMUX_AGENT_LAUNCH_EXECUTABLE") == result.real_path,
        f"glob PATH entry redirected Amp resolution: {result.real_environment}",
        failures,
    )


def test_missing_amp_reports_generic_recovery_error(failures: list[str]) -> None:
    result = run_wrapper(["--help"], amp_available=False)
    expect(result.returncode == 127, f"missing Amp: unexpected exit {result.returncode}", failures)
    expect(
        result.stderr == "Unable to start the configured agent. Check that it is installed and available.",
        f"missing Amp: leaked implementation detail in stderr: {result.stderr!r}",
        failures,
    )


def test_workspace_only_launch_installs_hooks(failures: list[str]) -> None:
    result = run_wrapper(["--mode", "smart"], workspace_only=True)
    expect(result.returncode == 0, f"workspace-only: wrapper exited {result.returncode}: {result.stderr}", failures)
    expect(
        result.cmux_calls == [["hooks", "amp", "install", "--yes"]]
        or result.cmux_calls == [["--socket", result.socket_path, "hooks", "amp", "install", "--yes"]],
        f"workspace-only: hooks were not installed: {result.cmux_calls}",
        failures,
    )


def main() -> int:
    failures: list[str] = []
    if not SOURCE_WRAPPER.is_file():
        failures.append(f"missing Amp launch wrapper: {SOURCE_WRAPPER}")
    else:
        test_instrumented_launch(failures)
        test_bypass_paths(failures)
        test_installer_failures_never_block_amp(failures)
        test_stalled_installer_is_bounded(failures)
        test_path_globs_do_not_redirect_amp_resolution(failures)
        test_missing_amp_reports_generic_recovery_error(failures)
        test_workspace_only_launch_installs_hooks(failures)

    if failures:
        print("FAIL: Amp launches do not reliably activate the cmux session extension")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: every Amp launch refreshes hooks and preserves launch attribution")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
