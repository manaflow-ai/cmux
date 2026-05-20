#!/usr/bin/env python3
"""
Regression tests for Resources/bin/codex wrapper hook/session tracking.
"""

from __future__ import annotations

import base64
import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "codex"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def decode_nul_argv(encoded: str) -> list[str]:
    raw = base64.b64decode(encoded)
    parts = raw.split(b"\0")
    if parts and parts[-1] == b"":
        parts = parts[:-1]
    return [part.decode("utf-8") for part in parts]


def run_wrapper(
    *,
    socket_state: str,
    argv: list[str],
    hooks_disabled: bool = False,
) -> tuple[int, list[str], dict[str, str], list[str], str]:
    with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        bundled_dir = tmp / "bundled cli"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)
        bundled_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "codex"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        real_env_log = tmp / "real-env.log"
        cmux_log = tmp / "cmux.log"
        socket_path = str(tmp / "cmux.sock")

        make_executable(
            real_dir / "codex",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
: > "$FAKE_REAL_ENV_LOG"
keys=(
  CMUX_AGENT_LAUNCH_KIND
  CMUX_AGENT_LAUNCH_EXECUTABLE
  CMUX_AGENT_LAUNCH_ARGV_B64
  CMUX_AGENT_LAUNCH_CWD
  CMUX_CODEX_PID
  CMUX_SURFACE_ID
  CMUX_SOCKET_PATH
  CMUX_BUNDLED_CLI_PATH
)
for key in "${keys[@]}"; do
  if [[ ${!key+x} ]]; then
    printf '%s=%s\\n' "$key" "${!key}" >> "$FAKE_REAL_ENV_LOG"
  else
    printf '%s=__UNSET__\\n' "$key" >> "$FAKE_REAL_ENV_LOG"
  fi
done
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"
done
""",
        )

        make_executable(
            wrapper_dir / "cmux",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'self %s timeout=%s\\n' "$*" "${CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC-__UNSET__}" >> "$FAKE_CMUX_LOG"
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  if [[ "${FAKE_CMUX_PING_OK:-0}" == "1" ]]; then
    exit 0
  fi
  exit 1
fi
exit 0
""",
        )

        bundled_cli_path = bundled_dir / "cmux"
        make_executable(
            bundled_cli_path,
            """#!/usr/bin/env bash
set -euo pipefail
printf 'bundled %s timeout=%s\\n' "$*" "${CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC-__UNSET__}" >> "$FAKE_CMUX_LOG"
exit 0
""",
        )

        test_socket: socket.socket | None = None
        if socket_state in {"live", "stale"}:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(socket_path)

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
        env["CMUX_SURFACE_ID"] = "surface:test"
        env["CMUX_SOCKET_PATH"] = socket_path
        env["CMUX_BUNDLED_CLI_PATH"] = str(bundled_cli_path)
        env["FAKE_CMUX_LOG"] = str(cmux_log)
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_REAL_ENV_LOG"] = str(real_env_log)
        env["FAKE_CMUX_PING_OK"] = "1" if socket_state == "live" else "0"
        if hooks_disabled:
            env["CMUX_CODEX_HOOKS_DISABLED"] = "1"
        else:
            env.pop("CMUX_CODEX_HOOKS_DISABLED", None)

        try:
            proc = subprocess.run(
                ["codex", *argv],
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
        return proc.returncode, read_lines(real_args_log), observed_env, read_lines(cmux_log), proc.stderr.strip()


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def test_live_socket_installs_hooks_and_exports_launch_metadata(failures: list[str]) -> None:
    code, real_argv, env, cmux_log, stderr = run_wrapper(
        socket_state="live",
        argv=["--model", "gpt-5.4", "hello"],
    )
    expect(code == 0, f"live socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["--model", "gpt-5.4", "hello"], f"live socket: expected raw argv, got {real_argv}", failures)
    expect(any(" --socket " in line and " ping " in line for line in cmux_log), f"live socket: expected bounded cmux ping, got {cmux_log}", failures)
    expect(any("timeout=0.75" in line for line in cmux_log), f"live socket: expected ping timeout, got {cmux_log}", failures)
    expect(
        any(line.startswith("bundled hooks codex install --yes ") for line in cmux_log),
        f"live socket: expected bundled hook install, got {cmux_log}",
        failures,
    )
    expect(env.get("CMUX_AGENT_LAUNCH_KIND") == "codex", f"live socket: expected codex launch kind, got {env}", failures)
    expect(env.get("CMUX_AGENT_LAUNCH_EXECUTABLE", "").endswith("/real-bin/codex"), f"live socket: expected real codex executable, got {env}", failures)
    expect(env.get("CMUX_AGENT_LAUNCH_CWD", "").startswith("/"), f"live socket: expected cwd, got {env}", failures)
    expect(env.get("CMUX_CODEX_PID") not in (None, "__UNSET__", ""), f"live socket: expected CMUX_CODEX_PID, got {env}", failures)
    expect(env.get("CMUX_SURFACE_ID") == "surface:test", f"live socket: expected surface env preserved, got {env}", failures)
    encoded = env.get("CMUX_AGENT_LAUNCH_ARGV_B64", "")
    decoded = decode_nul_argv(encoded)
    expect(
        len(decoded) == 4 and decoded[0].endswith("/real-bin/codex") and decoded[1:] == ["--model", "gpt-5.4", "hello"],
        f"live socket: expected encoded launch argv to preserve executable and args, got {decoded}",
        failures,
    )


def test_plain_codex_launch_argv_has_no_empty_argument(failures: list[str]) -> None:
    code, _, env, _, stderr = run_wrapper(socket_state="live", argv=[])
    expect(code == 0, f"plain codex: wrapper exited {code}: {stderr}", failures)
    decoded = decode_nul_argv(env.get("CMUX_AGENT_LAUNCH_ARGV_B64", ""))
    expect(len(decoded) == 1, f"plain codex: expected only executable in encoded launch argv, got {decoded}", failures)
    expect(decoded[0].endswith("/real-bin/codex"), f"plain codex: expected real codex executable, got {decoded}", failures)


def test_resume_and_fork_are_tracked_interactive_entrypoints(failures: list[str]) -> None:
    for argv in (["resume", "codex-session-123"], ["fork", "--last"]):
        code, real_argv, env, cmux_log, stderr = run_wrapper(socket_state="live", argv=argv)
        label = " ".join(argv)
        expect(code == 0, f"{label}: wrapper exited {code}: {stderr}", failures)
        expect(real_argv == argv, f"{label}: expected raw argv, got {real_argv}", failures)
        expect(env.get("CMUX_AGENT_LAUNCH_KIND") == "codex", f"{label}: expected launch metadata, got {env}", failures)
        expect(any(line.startswith("bundled hooks codex install --yes ") for line in cmux_log), f"{label}: expected hook install, got {cmux_log}", failures)


def test_command_like_invocations_bypass_hook_tracking_and_scrub_cmux_env(failures: list[str]) -> None:
    subcommands = [
        "exec",
        "e",
        "review",
        "login",
        "logout",
        "mcp",
        "plugin",
        "mcp-server",
        "app-server",
        "remote-control",
        "app",
        "completion",
        "update",
        "doctor",
        "sandbox",
        "debug",
        "apply",
        "a",
        "cloud",
        "exec-server",
        "features",
        "help",
    ]
    for subcommand in subcommands:
        code, real_argv, env, cmux_log, stderr = run_wrapper(socket_state="live", argv=[subcommand, "arg"])
        expect(code == 0, f"{subcommand}: wrapper exited {code}: {stderr}", failures)
        expect(real_argv == [subcommand, "arg"], f"{subcommand}: expected raw argv, got {real_argv}", failures)
        expect(env.get("CMUX_AGENT_LAUNCH_KIND") == "__UNSET__", f"{subcommand}: expected no launch metadata, got {env}", failures)
        expect(env.get("CMUX_SURFACE_ID") == "__UNSET__", f"{subcommand}: expected CMUX env scrubbed, got {env}", failures)
        expect(not any("hooks codex install" in line for line in cmux_log), f"{subcommand}: expected no hook install, got {cmux_log}", failures)


def test_passthrough_flags_and_disabled_hooks_do_not_track(failures: list[str]) -> None:
    scenarios = [
        ("--help", {"argv": ["--help"], "hooks_disabled": False, "socket_state": "live"}),
        ("--version", {"argv": ["--version"], "hooks_disabled": False, "socket_state": "live"}),
        ("disabled", {"argv": ["hello"], "hooks_disabled": True, "socket_state": "live"}),
        ("stale socket", {"argv": ["hello"], "hooks_disabled": False, "socket_state": "stale"}),
        ("missing socket", {"argv": ["hello"], "hooks_disabled": False, "socket_state": "missing"}),
    ]
    for label, kwargs in scenarios:
        code, real_argv, env, cmux_log, stderr = run_wrapper(**kwargs)
        expect(code == 0, f"{label}: wrapper exited {code}: {stderr}", failures)
        expect(real_argv == kwargs["argv"], f"{label}: expected raw argv, got {real_argv}", failures)
        expect(env.get("CMUX_AGENT_LAUNCH_KIND") == "__UNSET__", f"{label}: expected no launch metadata, got {env}", failures)
        expect(env.get("CMUX_SURFACE_ID") == "__UNSET__", f"{label}: expected CMUX env scrubbed, got {env}", failures)
        expect(not any("hooks codex install" in line for line in cmux_log), f"{label}: expected no hook install, got {cmux_log}", failures)


def main() -> int:
    failures: list[str] = []
    test_live_socket_installs_hooks_and_exports_launch_metadata(failures)
    test_plain_codex_launch_argv_has_no_empty_argument(failures)
    test_resume_and_fork_are_tracked_interactive_entrypoints(failures)
    test_command_like_invocations_bypass_hook_tracking_and_scrub_cmux_env(failures)
    test_passthrough_flags_and_disabled_hooks_do_not_track(failures)

    if failures:
        print("FAIL: codex wrapper hook/session tracking regressions")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: codex wrapper installs hooks and exports restorable launch metadata")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
