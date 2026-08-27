#!/usr/bin/env python3
"""Behavior checks for automatic Hermes Agent hook installation."""

from __future__ import annotations

import base64
import json
import os
import signal
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-hermes-agent-wrapper"
SOURCE_TUI_PYTHON_WRAPPER = ROOT / "Resources" / "bin" / "cmux-hermes-python-wrapper"
SOURCE_TUI_SITECUSTOMIZE = ROOT / "Resources" / "bin" / "cmux-hermes-sitecustomize.py"
SESSION_ID = "01JZ123456789ABCDEFGHJKMNP"


@dataclass
class WrapperResult:
    returncode: int
    real_argv: list[str]
    real_environment: dict[str, str]
    cmux_calls: list[list[str]]
    cmux_payloads: list[str]
    cmux_environment: dict[str, str]
    stderr: str
    real_path: str
    shim_directory: str
    working_directory: str
    socket_path: str
    installer_started: bool
    launch_observed: bool
    hermes_home: str
    original_tmpdir: str
    tui_tmpdir_cleaned_before_teardown: bool | None
    tui_watcher_cpu_seconds: float | None
    tui_gateway_events: list[str]
    profile_homes: dict[str, str]


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


def read_payloads(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [
        base64.b64decode(line).decode("utf-8") if line else ""
        for line in path.read_text(encoding="utf-8").splitlines()
    ]


def read_cpu_seconds(path: Path) -> float | None:
    if not path.exists():
        return None
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        return None
    try:
        return sum(
            float(part) * (60**index)
            for index, part in enumerate(reversed(value.split(":")))
        )
    except ValueError:
        return None


def run_wrapper(
    argv: list[str],
    *,
    in_cmux: bool = True,
    hooks_disabled: bool = False,
    installer_exit_code: int = 0,
    installer_blocks: bool = False,
    installer_timeout_seconds: float = 1,
    cli_available: bool = True,
    active_profile: str | None = None,
    profile_names: tuple[str, ...] = (),
    tui_session_ids: tuple[str, ...] = (),
    tui_multiple_active_files: bool = False,
    sample_tui_watcher_cpu: bool = False,
    tui_gateway_turns: int = 0,
    tui_gateway_compute_host: bool = False,
    stale_tui_python_wrapper: bool = False,
    shadow_path_bash: bool = False,
    expected_cmux_call_count: int | None = None,
) -> WrapperResult:
    with tempfile.TemporaryDirectory(prefix="cmux-hermes-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        shim_dir = tmp / "cmux-cli-shims" / "surface-test"
        real_dir = tmp / "real-bin"
        shadow_dir = tmp / "shadow-bin"
        bundled_dir = tmp / "bundled cli"
        user_home = tmp / "user home"
        hermes_home = tmp / "hermes home"
        original_tmpdir = tmp / "original tmp"
        for directory in (
            wrapper_dir,
            shim_dir,
            real_dir,
            shadow_dir,
            bundled_dir,
            user_home,
            hermes_home,
            original_tmpdir,
        ):
            directory.mkdir(parents=True)

        if shadow_path_bash:
            make_executable(shadow_dir / "bash", "#!/bin/sh\nexit 97\n")

        profile_homes = {
            name: hermes_home / "profiles" / name
            for name in profile_names
        }
        for profile_home in profile_homes.values():
            profile_home.mkdir(parents=True)
        if active_profile is not None:
            (hermes_home / "active_profile").write_text(
                f"{active_profile}\n",
                encoding="utf-8",
            )

        wrapper = wrapper_dir / "cmux-hermes-agent-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)
        if SOURCE_TUI_PYTHON_WRAPPER.is_file():
            python_wrapper = wrapper_dir / SOURCE_TUI_PYTHON_WRAPPER.name
            shutil.copy2(SOURCE_TUI_PYTHON_WRAPPER, python_wrapper)
            python_wrapper.chmod(0o755)
        if SOURCE_TUI_SITECUSTOMIZE.is_file():
            shutil.copy2(
                SOURCE_TUI_SITECUSTOMIZE,
                wrapper_dir / SOURCE_TUI_SITECUSTOMIZE.name,
            )

        # Match the real per-surface topology. The PATH candidate named
        # `hermes` points back to the wrapper, so resolution must skip it and
        # continue to the actual executable.
        shim = shim_dir / "hermes"
        shim.symlink_to(wrapper)

        real_args_log = tmp / "real-args.log"
        real_env_log = tmp / "real-env.log"
        cmux_calls_log = tmp / "cmux-calls.log"
        cmux_payloads_log = tmp / "cmux-payloads.log"
        cmux_env_log = tmp / "cmux-env.log"
        installer_started_log = tmp / "installer-started.log"
        installer_gate = tmp / "installer-gate"
        tui_watcher_cpu_log = tmp / "tui-watcher-cpu.log"
        tui_gateway_events_log = tmp / "tui-gateway-events.log"
        stale_tui_python_log = tmp / "stale-tui-python.log"
        if installer_blocks:
            os.mkfifo(installer_gate)

        stale_tui_python = tmp / "retired-build" / "cmux-hermes-python-wrapper"
        if stale_tui_python_wrapper:
            stale_tui_python.parent.mkdir(parents=True)
            make_executable(
                stale_tui_python,
                "#!/bin/sh\n"
                f"printf 'invoked\\n' > {str(stale_tui_python_log)!r}\n"
                "exit 91\n",
            )

        fake_tui_gateway_root = tmp / "fake-hermes-python"
        if tui_gateway_turns:
            for package in ("agent", "hermes_cli", "tui_gateway"):
                package_dir = fake_tui_gateway_root / package
                package_dir.mkdir(parents=True)
                (package_dir / "__init__.py").write_text("", encoding="utf-8")
            (fake_tui_gateway_root / "hermes_cli" / "config.py").write_text(
                "def load_config():\n"
                "    return {'hooks': {}}\n",
                encoding="utf-8",
            )
            (fake_tui_gateway_root / "agent" / "shell_hooks.py").write_text(
                "import os\n"
                "\n"
                "_registered = False\n"
                "\n"
                "def register_from_config(_config, *, accept_hooks=False):\n"
                "    global _registered\n"
                "    target = os.environ.get('CMUX_HERMES_TUI_TARGET_MODULE')\n"
                "    if target not in {'tui_gateway.entry', 'tui_gateway.compute_host'}:\n"
                "        raise RuntimeError(f'missing gateway target marker: {target!r}')\n"
                "    _registered = True\n"
                "\n"
                "def emit_turn(runtime, turn):\n"
                "    if not _registered:\n"
                "        return\n"
                "    with open(os.environ['FAKE_TUI_GATEWAY_EVENTS_LOG'], 'a', encoding='utf-8') as log:\n"
                "        for event in ('prompt-submit', 'agent-response', 'session-end'):\n"
                "            log.write(f'{runtime}:{event}:{turn}\\n')\n",
                encoding="utf-8",
            )
            runtime_module = (
                "import os\n"
                "from agent.shell_hooks import emit_turn\n"
                "\n"
                "for turn in range(1, int(os.environ['FAKE_TUI_GATEWAY_TURNS']) + 1):\n"
                "    emit_turn(RUNTIME_NAME, turn)\n"
            )
            (fake_tui_gateway_root / "tui_gateway" / "entry.py").write_text(
                "RUNTIME_NAME = 'gateway'\n" + runtime_module,
                encoding="utf-8",
            )
            (fake_tui_gateway_root / "tui_gateway" / "compute_host.py").write_text(
                "RUNTIME_NAME = 'compute-host'\n" + runtime_module,
                encoding="utf-8",
            )

        real_hermes = real_dir / "hermes"
        real_hermes_shebang = "#!/bin/bash" if shadow_path_bash else "#!/usr/bin/env bash"
        make_executable(
            real_hermes,
            real_hermes_shebang
            + """
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
  printf 'TMPDIR=%s\\n' "${TMPDIR-__UNSET__}"
  printf 'HERMES_PYTHON=%s\\n' "${HERMES_PYTHON-__UNSET__}"
  printf 'CMUX_HERMES_TUI_REAL_PYTHON=%s\\n' "${CMUX_HERMES_TUI_REAL_PYTHON-__UNSET__}"
  printf 'PATH=%s\\n' "$PATH"
  printf 'REAL_PID=%s\\n' "$$"
} > "$FAKE_REAL_ENV_LOG"
if [[ -n "${FAKE_TUI_SESSION_IDS:-}" ]]; then
  # Collapse Hermes's Python launcher and its TUI child into this fake: the
  # launcher creates the tempfile, then passes its exact path to the child.
  active_session_file="$TMPDIR/hermes-tui-active-session-$$.json"
  export HERMES_TUI_ACTIVE_SESSION_FILE="$active_session_file"
  printf 'HERMES_TUI_ACTIVE_SESSION_FILE=%s\n' "$HERMES_TUI_ACTIVE_SESSION_FILE" >> "$FAKE_REAL_ENV_LOG"
  : > "$active_session_file"
  if [[ "${FAKE_TUI_MULTIPLE_ACTIVE_FILES:-0}" == "1" ]]; then
    : > "$TMPDIR/hermes-tui-active-session-extra.json"
  fi
  IFS=',' read -r -a fake_tui_session_ids <<< "$FAKE_TUI_SESSION_IDS"
  for fake_tui_session_id in "${fake_tui_session_ids[@]}"; do
    printf '{"session_id":"%s"}\\n' "$fake_tui_session_id" > "$active_session_file"
    sleep 0.25
  done
fi
if [[ "${FAKE_SAMPLE_TUI_WATCHER_CPU:-0}" == "1" ]]; then
  watcher_pid=""
  for _ in {1..100}; do
    watcher_pid="$(/usr/bin/pgrep -P "$$" -f 'cmux-hermes-agent-wrapper' | /usr/bin/head -n 1 || true)"
    [[ -n "$watcher_pid" ]] && break
    sleep 0.01
  done
  if [[ -n "$watcher_pid" ]]; then
    # This is the controlled workload window for the CPU regression check.
    sleep 0.5
    /bin/ps -o time= -p "$watcher_pid" | /usr/bin/tr -d ' ' > "$FAKE_TUI_WATCHER_CPU_LOG" || true
  fi
fi
if (( ${FAKE_TUI_GATEWAY_TURNS:-0} > 0 )); then
  fake_tui_python="${HERMES_PYTHON:-$FAKE_HERMES_PYTHON}"
  export PYTHONPATH="$FAKE_TUI_GATEWAY_ROOT${PYTHONPATH:+:$PYTHONPATH}"
  "$fake_tui_python" -m tui_gateway.entry
  if [[ "${FAKE_TUI_GATEWAY_COMPUTE_HOST:-0}" == "1" ]]; then
    "$fake_tui_python" -m tui_gateway.compute_host
  fi
fi
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
fake_cmux_payload_b64="$(/usr/bin/base64 | tr -d '\\n')"
printf '%s\\n' "$fake_cmux_payload_b64" >> "$FAKE_CMUX_PAYLOADS_LOG"
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
        else:
            # A configured-but-missing bundled CLI must fail closed. Put a
            # tempting fallback on PATH so the test does not depend on the
            # developer or CI machine having another cmux installation.
            make_executable(
                real_dir / "cmux",
                """#!/usr/bin/env bash
set -euo pipefail
printf '\\036' >> "$FAKE_CMUX_CALLS_LOG"
printf '%s\\0' "$@" >> "$FAKE_CMUX_CALLS_LOG"
exit 0
""",
            )

        socket_path = str(tmp / "cmux.sock")
        env = os.environ.copy()
        env["PATH"] = (
            f"{shadow_dir}:{shim_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
        )
        env["HOME"] = str(user_home)
        env["HERMES_HOME"] = str(hermes_home)
        env["TMPDIR"] = str(original_tmpdir)
        env["CMUX_BUNDLED_CLI_PATH"] = str(bundled_cli)
        env["CMUX_HERMES_AGENT_WRAPPER_SHIM"] = str(shim)
        env["CMUX_HERMES_AGENT_WRAPPER_SHIM_ROOT"] = str(shim_dir)
        env["CMUX_AGENT_RESTORE_LAUNCH"] = f"hermes-agent:{SESSION_ID}"
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_REAL_ENV_LOG"] = str(real_env_log)
        env["FAKE_CMUX_CALLS_LOG"] = str(cmux_calls_log)
        env["FAKE_CMUX_PAYLOADS_LOG"] = str(cmux_payloads_log)
        env["FAKE_CMUX_ENV_LOG"] = str(cmux_env_log)
        env["FAKE_INSTALLER_EXIT_CODE"] = str(installer_exit_code)
        env["FAKE_INSTALLER_STARTED_LOG"] = str(installer_started_log)
        if installer_blocks:
            env["FAKE_INSTALLER_GATE"] = str(installer_gate)
        else:
            env.pop("FAKE_INSTALLER_GATE", None)
        env["CMUX_HERMES_AGENT_HOOK_INSTALL_TIMEOUT_SECONDS"] = str(installer_timeout_seconds)
        if tui_session_ids:
            env["FAKE_TUI_SESSION_IDS"] = ",".join(tui_session_ids)
        else:
            env.pop("FAKE_TUI_SESSION_IDS", None)
        env["FAKE_TUI_MULTIPLE_ACTIVE_FILES"] = "1" if tui_multiple_active_files else "0"
        env["FAKE_SAMPLE_TUI_WATCHER_CPU"] = "1" if sample_tui_watcher_cpu else "0"
        env["FAKE_TUI_WATCHER_CPU_LOG"] = str(tui_watcher_cpu_log)
        env["FAKE_TUI_GATEWAY_TURNS"] = str(tui_gateway_turns)
        env["FAKE_TUI_GATEWAY_COMPUTE_HOST"] = "1" if tui_gateway_compute_host else "0"
        env["FAKE_TUI_GATEWAY_ROOT"] = str(fake_tui_gateway_root)
        env["FAKE_TUI_GATEWAY_EVENTS_LOG"] = str(tui_gateway_events_log)
        env["FAKE_HERMES_PYTHON"] = sys.executable
        if stale_tui_python_wrapper:
            env["HERMES_PYTHON"] = str(stale_tui_python)
        elif tui_gateway_turns:
            env["HERMES_PYTHON"] = sys.executable
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

        tui_tmpdir_cleaned_before_teardown: bool | None = None
        if tui_session_ids:
            lifecycle_deadline = time.monotonic() + 2
            expected_call_count = expected_cmux_call_count or len(tui_session_ids) + 2
            while time.monotonic() < lifecycle_deadline:
                if len(read_calls(cmux_calls_log)) >= expected_call_count:
                    break
                time.sleep(0.01)
            if real_env_log.exists():
                hermes_tmpdir = read_environment(real_env_log).get("TMPDIR")
                while (
                    hermes_tmpdir
                    and Path(hermes_tmpdir).exists()
                    and time.monotonic() < lifecycle_deadline
                ):
                    time.sleep(0.01)
                tui_tmpdir_cleaned_before_teardown = bool(hermes_tmpdir) and not Path(
                    hermes_tmpdir
                ).exists()

        return WrapperResult(
            returncode=proc.returncode,
            real_argv=read_nul_values(real_args_log),
            real_environment=read_environment(real_env_log) if real_env_log.exists() else {},
            cmux_calls=read_calls(cmux_calls_log),
            cmux_payloads=read_payloads(cmux_payloads_log),
            cmux_environment=read_environment(cmux_env_log) if cmux_env_log.exists() else {},
            stderr=stderr.strip(),
            real_path=str(real_hermes),
            shim_directory=str(shim_dir),
            working_directory=os.path.realpath(tmp),
            socket_path=socket_path,
            installer_started=installer_started_log.exists(),
            launch_observed=launch_observed,
            hermes_home=str(hermes_home),
            original_tmpdir=str(original_tmpdir),
            tui_tmpdir_cleaned_before_teardown=tui_tmpdir_cleaned_before_teardown,
            tui_watcher_cpu_seconds=read_cpu_seconds(tui_watcher_cpu_log),
            tui_gateway_events=(
                tui_gateway_events_log.read_text(encoding="utf-8").splitlines()
                if tui_gateway_events_log.exists()
                else []
            ),
            profile_homes={name: str(path) for name, path in profile_homes.items()},
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
        ("continue-admin-name-long", ["--continue", "doctor"]),
        ("continue-admin-name-short", ["-c", "status"]),
        ("global-options", ["--provider", "openrouter", "--tui"]),
    )
    for label, argv in entrypoints:
        assert_instrumented(argv, label, failures)


def test_tui_active_session_file_bridges_lifecycle(failures: list[str]) -> None:
    first_session_id = "20260807_171025_620d3a"
    second_session_id = "20260807_171126_51fa8c"
    result = run_wrapper(
        ["--tui"],
        tui_session_ids=(first_session_id, second_session_id),
        sample_tui_watcher_cpu=True,
    )
    expected_prefix = ["--socket", result.socket_path, "hooks", "hermes-agent"]
    expected_calls = [
        [*expected_prefix, "install", "--yes"],
        [*expected_prefix, "session-start"],
        [*expected_prefix, "session-start"],
        [*expected_prefix, "session-finalize"],
    ]

    expect(result.returncode == 0, f"TUI bridge: wrapper exited {result.returncode}: {result.stderr}", failures)
    expect(result.cmux_calls == expected_calls, f"TUI bridge: unexpected cmux calls: {result.cmux_calls}", failures)
    expect(
        len(result.cmux_payloads) == len(expected_calls),
        f"TUI bridge: lifecycle payload count did not match calls: {result.cmux_payloads}",
        failures,
    )
    if len(result.cmux_payloads) == len(expected_calls):
        payloads = [json.loads(payload) if payload else {} for payload in result.cmux_payloads]
        expected_events = [
            {},
            {
                "cwd": result.working_directory,
                "hook_event_name": "on_session_start",
                "platform": "tui",
                "session_id": first_session_id,
            },
            {
                "cwd": result.working_directory,
                "hook_event_name": "on_session_reset",
                "platform": "tui",
                "session_id": second_session_id,
            },
            {
                "cwd": result.working_directory,
                "hook_event_name": "on_session_finalize",
                "platform": "tui",
                "session_id": second_session_id,
            },
        ]
        expect(payloads == expected_events, f"TUI bridge: unexpected lifecycle payloads: {payloads}", failures)

    hermes_tmpdir = result.real_environment.get("TMPDIR")
    active_session_file = result.real_environment.get("HERMES_TUI_ACTIVE_SESSION_FILE")
    expect(
        hermes_tmpdir not in (None, "__UNSET__", result.original_tmpdir),
        f"TUI bridge: Hermes did not receive an invocation-private TMPDIR: {result.real_environment}",
        failures,
    )
    expect(
        bool(active_session_file)
        and Path(active_session_file).parent == Path(hermes_tmpdir or "")
        and Path(active_session_file).name.startswith("hermes-tui-active-session-")
        and Path(active_session_file).suffix == ".json",
        f"TUI bridge: fake launcher did not pass Hermes's active-session file contract: {result.real_environment}",
        failures,
    )
    if hermes_tmpdir not in (None, "__UNSET__", result.original_tmpdir):
        expect(
            result.tui_tmpdir_cleaned_before_teardown is True,
            f"TUI bridge: invocation-private TMPDIR was not cleaned up: {hermes_tmpdir}",
            failures,
        )
    expect(
        result.tui_watcher_cpu_seconds is not None
        and result.tui_watcher_cpu_seconds < 0.2,
        f"TUI bridge: watcher consumed CPU while idle: {result.tui_watcher_cpu_seconds}",
        failures,
    )


def test_tui_bridge_fails_closed_on_untrusted_session_files(failures: list[str]) -> None:
    cases = (
        (
            "invalid session ID",
            {"tui_session_ids": ("../../not-a-hermes-session",)},
        ),
        (
            "multiple active files",
            {
                "tui_session_ids": ("20260807_171025_620d3a",),
                "tui_multiple_active_files": True,
            },
        ),
    )
    for label, kwargs in cases:
        result = run_wrapper(
            ["--tui"],
            expected_cmux_call_count=1,
            **kwargs,
        )
        expected_install = [
            "--socket",
            result.socket_path,
            "hooks",
            "hermes-agent",
            "install",
            "--yes",
        ]
        expect(
            result.cmux_calls == [expected_install],
            f"TUI bridge {label}: untrusted file emitted lifecycle calls: {result.cmux_calls}",
            failures,
        )
        expect(
            result.cmux_payloads == [""],
            f"TUI bridge {label}: untrusted file emitted lifecycle payloads: {result.cmux_payloads}",
            failures,
        )
        hermes_tmpdir = result.real_environment.get("TMPDIR")
        expect(
            bool(hermes_tmpdir) and result.tui_tmpdir_cleaned_before_teardown is True,
            f"TUI bridge {label}: invocation-private TMPDIR was not cleaned up: {hermes_tmpdir}",
            failures,
        )


def test_tui_gateway_registers_hooks_for_every_turn(failures: list[str]) -> None:
    result = run_wrapper(
        ["--tui"],
        tui_gateway_turns=2,
        tui_gateway_compute_host=True,
    )
    expected_events = [
        f"{runtime}:{event}:{turn}"
        for runtime in ("gateway", "compute-host")
        for turn in (1, 2)
        for event in ("prompt-submit", "agent-response", "session-end")
    ]

    expect(
        result.returncode == 0,
        f"TUI per-turn hooks: wrapper exited {result.returncode}: {result.stderr}",
        failures,
    )
    expect(
        result.tui_gateway_events == expected_events,
        "TUI per-turn hooks: fresh gateway processes did not retain hook callbacks "
        f"across turns: {result.tui_gateway_events}",
        failures,
    )


def test_tui_gateway_rejects_retired_cmux_python_wrapper(failures: list[str]) -> None:
    expected_events = [
        f"gateway:{event}:{turn}"
        for turn in (1, 2)
        for event in ("prompt-submit", "agent-response", "session-end")
    ]
    cases = (
        ("watcher available", {}, expected_events),
        # Without a cmux CLI there is no gateway bootstrap to register hooks,
        # but Hermes must still launch through its own interpreter.
        ("watcher unavailable", {"cli_available": False}, []),
    )
    for label, kwargs, expected_gateway_events in cases:
        result = run_wrapper(
            ["--tui"],
            tui_gateway_turns=2,
            stale_tui_python_wrapper=True,
            **kwargs,
        )

        expect(
            result.returncode == 0,
            f"TUI stale Python wrapper ({label}): retired cmux wrapper blocked "
            f"gateway startup: {result.returncode}: {result.stderr}",
            failures,
        )
        expect(
            result.tui_gateway_events == expected_gateway_events,
            f"TUI stale Python wrapper ({label}): gateway did not fall back to "
            f"Hermes's real interpreter: {result.tui_gateway_events}",
            failures,
        )


def test_bundled_wrappers_ignore_path_bash_shadow(failures: list[str]) -> None:
    result = run_wrapper(
        ["--tui"],
        tui_gateway_turns=2,
        shadow_path_bash=True,
    )
    expected_events = [
        f"gateway:{event}:{turn}"
        for turn in (1, 2)
        for event in ("prompt-submit", "agent-response", "session-end")
    ]

    expect(
        result.returncode == 0,
        "TUI PATH bash shadow: a non-native PATH bash blocked Hermes startup: "
        f"{result.returncode}: {result.stderr}",
        failures,
    )
    expect(
        result.tui_gateway_events == expected_events,
        "TUI PATH bash shadow: managed wrappers did not retain gateway hooks: "
        f"{result.tui_gateway_events}",
        failures,
    )


def test_explicit_classic_cli_skips_tui_watcher(failures: list[str]) -> None:
    result = run_wrapper(["--cli"])
    expect(
        result.real_environment.get("TMPDIR") == result.original_tmpdir,
        f"classic CLI: wrapper unexpectedly replaced TMPDIR: {result.real_environment}",
        failures,
    )


def test_profile_scoped_hook_install(failures: list[str]) -> None:
    for label, argv in (
        ("explicit-profile-long", ["--profile", "coder"]),
        ("explicit-profile-short", ["-p", "coder"]),
        ("explicit-profile-equals", ["--profile=coder"]),
        ("explicit-profile-after-continue-name", ["--continue", "doctor", "-p", "coder"]),
    ):
        result = run_wrapper(argv, profile_names=("coder",))
        expect(
            result.cmux_environment.get("HERMES_HOME") == result.profile_homes["coder"],
            f"{label}: installer targeted the wrong profile: {result.cmux_environment}",
            failures,
        )
        expect(
            result.real_environment.get("HERMES_HOME") == result.hermes_home,
            f"{label}: wrapper leaked its installer-only profile override: {result.real_environment}",
            failures,
        )

    sticky = run_wrapper([], active_profile="coder", profile_names=("coder",))
    expect(
        sticky.cmux_environment.get("HERMES_HOME") == sticky.profile_homes["coder"],
        f"sticky profile: installer targeted the wrong profile: {sticky.cmux_environment}",
        failures,
    )
    expect(
        sticky.real_environment.get("HERMES_HOME") == sticky.hermes_home,
        f"sticky profile: wrapper leaked its installer-only profile override: {sticky.real_environment}",
        failures,
    )


def test_administrative_entrypoints_bypass_install(failures: list[str]) -> None:
    entrypoints = (
        ("help", ["--help"]),
        ("version", ["--version"]),
        ("chat-help", ["chat", "--help"]),
        ("chat-help-short", ["chat", "-h"]),
        ("sessions", ["sessions", "list"]),
        ("hooks", ["hooks", "doctor"]),
        ("doctor", ["doctor"]),
        ("approvals", ["approvals", "list"]),
        ("egress", ["egress", "status"]),
        ("import-agent", ["import-agent", "--help"]),
        ("monitoring", ["monitoring", "status"]),
        ("skin", ["skin", "list"]),
        ("sync", ["sync", "status"]),
        ("future-command", ["future-administrative-command", "--help"]),
        ("profile-alias", ["profile", "alias", "coder"]),
        ("option-before-admin", ["--provider", "openrouter", "sessions", "stats"]),
    )
    for label, argv in entrypoints:
        result = run_wrapper(argv)
        expect(result.returncode == 0, f"{label}: wrapper exited {result.returncode}: {result.stderr}", failures)
        expect(result.real_argv == argv, f"{label}: original argv changed: {result.real_argv}", failures)
        expect(result.cmux_calls == [], f"{label}: administrative command installed hooks: {result.cmux_calls}", failures)


def test_administrative_passthrough_strips_shim_path(failures: list[str]) -> None:
    result = run_wrapper(["profile", "alias", "coder"])
    passthrough_path = result.real_environment.get("PATH", "").split(os.pathsep)
    expect(
        result.shim_directory not in passthrough_path
        and all("/cmux-cli-shims/" not in entry for entry in passthrough_path),
        f"profile alias: administrative command retained ephemeral shim PATH: {passthrough_path}",
        failures,
    )


def test_noninteractive_entrypoints_bypass_install(failures: list[str]) -> None:
    entrypoints = (
        ("oneshot-short", ["-z", "report status"]),
        ("oneshot-short-attached", ["-zreport status"]),
        ("oneshot-long", ["--oneshot", "report status"]),
        ("oneshot-long-equals", ["--oneshot=report status"]),
        ("chat-query-short", ["chat", "-q", "report status"]),
        ("chat-query-short-attached", ["chat", "-qreport status"]),
        ("chat-query-long", ["chat", "--query", "report status"]),
        ("chat-query-long-equals", ["chat", "--query=report status"]),
    )
    for label, argv in entrypoints:
        result = run_wrapper(argv)
        expect(result.returncode == 0, f"{label}: wrapper exited {result.returncode}: {result.stderr}", failures)
        expect(result.real_argv == argv, f"{label}: original argv changed: {result.real_argv}", failures)
        expect(result.cmux_calls == [], f"{label}: noninteractive command installed hooks: {result.cmux_calls}", failures)
        for key in (
            "CMUX_SURFACE_ID",
            "CMUX_WORKSPACE_ID",
            "CMUX_SOCKET_PATH",
            "CMUX_AGENT_LAUNCH_KIND",
            "CMUX_AGENT_RESTORE_LAUNCH",
        ):
            expect(
                result.real_environment.get(key) == "__UNSET__",
                f"{label}: noninteractive command retained {key}: {result.real_environment}",
                failures,
            )
        expect(
            result.real_environment.get("HERMES_HOME") != "__UNSET__",
            f"{label}: passthrough cleared non-cmux Hermes configuration: {result.real_environment}",
            failures,
        )


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
        if label == "installer-missing":
            expect(
                result.cmux_calls == [],
                f"{label}: wrapper fell back to another cmux executable: {result.cmux_calls}",
                failures,
            )


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
        test_tui_active_session_file_bridges_lifecycle(failures)
        test_tui_bridge_fails_closed_on_untrusted_session_files(failures)
        test_tui_gateway_registers_hooks_for_every_turn(failures)
        test_tui_gateway_rejects_retired_cmux_python_wrapper(failures)
        test_bundled_wrappers_ignore_path_bash_shadow(failures)
        test_explicit_classic_cli_skips_tui_watcher(failures)
        test_profile_scoped_hook_install(failures)
        test_administrative_entrypoints_bypass_install(failures)
        test_administrative_passthrough_strips_shim_path(failures)
        test_noninteractive_entrypoints_bypass_install(failures)
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
