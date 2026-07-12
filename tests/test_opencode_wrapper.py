#!/usr/bin/env python3
"""
Regression tests for Resources/bin/cmux-opencode-wrapper.
"""

from __future__ import annotations

import os
import socket
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-opencode-wrapper"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def run_wrapper(*, inside_cmux: bool, hooks_disabled: bool = False, args: list[str] | None = None) -> tuple[int, str, str, str]:
    with tempfile.TemporaryDirectory(prefix="cmux-opencode-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "cmux-opencode-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_log = tmp / "real.log"
        cmux_log = tmp / "cmux.log"
        env_log = tmp / "env.log"
        socket_path = tmp / "cmux.sock"

        make_executable(
            real_dir / "opencode",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$REAL_LOG"
printf 'cmux_bin=%s\\n' "${CMUX_OPENCODE_CMUX_BIN-}" >> "$ENV_LOG"
""",
        )
        make_executable(
            wrapper_dir / "cmux",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$CMUX_LOG"
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  exit 0
fi
exit 0
""",
        )

        unix_socket: socket.socket | None = None
        if inside_cmux:
            unix_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            unix_socket.bind(str(socket_path))

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
        env["REAL_LOG"] = str(real_log)
        env["CMUX_LOG"] = str(cmux_log)
        env["ENV_LOG"] = str(env_log)
        if inside_cmux:
            env["CMUX_SURFACE_ID"] = "surface:opencode"
            env["CMUX_SOCKET_PATH"] = str(socket_path)
        else:
            env.pop("CMUX_SURFACE_ID", None)
            env.pop("CMUX_SOCKET_PATH", None)
        if hooks_disabled:
            env["CMUX_OPENCODE_HOOKS_DISABLED"] = "1"
        else:
            env.pop("CMUX_OPENCODE_HOOKS_DISABLED", None)

        try:
            result = subprocess.run(
                [str(wrapper), *(args or ["run", "task"])],
                env=env,
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
        finally:
            if unix_socket is not None:
                unix_socket.close()

        return result.returncode, read_text(cmux_log), read_text(real_log), read_text(env_log)


def main() -> int:
    if not SOURCE_WRAPPER.exists():
        print(f"FAIL: missing wrapper at {SOURCE_WRAPPER}")
        return 1

    rc, cmux_log, real_log, env_log = run_wrapper(inside_cmux=True)
    if rc != 0:
        print(f"FAIL: wrapper exited {rc}")
        return 1
    if "--socket" not in cmux_log or "ping" not in cmux_log:
        print(f"FAIL: wrapper did not ping cmux socket, got {cmux_log!r}")
        return 1
    if "hooks opencode install --yes" not in cmux_log:
        print(f"FAIL: wrapper did not install OpenCode hooks, got {cmux_log!r}")
        return 1
    if real_log.strip() != "run task":
        print(f"FAIL: wrapper did not exec real opencode, got {real_log!r}")
        return 1
    if "cmux_bin=" not in env_log:
        print(f"FAIL: wrapper did not export plugin cmux binary path, got {env_log!r}")
        return 1

    rc, cmux_log, real_log, _ = run_wrapper(inside_cmux=False)
    if rc != 0 or cmux_log:
        print(f"FAIL: wrapper should pass through outside cmux, rc={rc}, cmux_log={cmux_log!r}")
        return 1
    if real_log.strip() != "run task":
        print(f"FAIL: outside-cmux wrapper did not exec real opencode, got {real_log!r}")
        return 1

    rc, cmux_log, real_log, _ = run_wrapper(inside_cmux=True, hooks_disabled=True)
    if rc != 0 or cmux_log:
        print(f"FAIL: disabled wrapper should skip cmux calls, rc={rc}, cmux_log={cmux_log!r}")
        return 1
    if real_log.strip() != "run task":
        print(f"FAIL: disabled wrapper did not exec real opencode, got {real_log!r}")
        return 1

    # Non-session entrypoints (--help/--version/admin subcommands) must skip the
    # install AND the socket ping entirely, even inside a live cmux terminal.
    for non_session_args in (["--help"], ["--version"], ["completion"], ["models"], ["mcp", "list"]):
        rc, cmux_log, real_log, _ = run_wrapper(inside_cmux=True, args=non_session_args)
        if rc != 0 or cmux_log:
            print(f"FAIL: non-session {non_session_args} should skip cmux calls, rc={rc}, cmux_log={cmux_log!r}")
            return 1
        if real_log.strip() != " ".join(non_session_args):
            print(f"FAIL: non-session {non_session_args} did not exec real opencode, got {real_log!r}")
            return 1

    # Session entrypoints still trigger the install path inside cmux.
    for session_args in (["run", "task"], ["pr", "42"], ["serve"], ["myproject"]):
        rc, cmux_log, real_log, _ = run_wrapper(inside_cmux=True, args=session_args)
        if rc != 0:
            print(f"FAIL: session {session_args} exited {rc}")
            return 1
        if "hooks opencode install --yes" not in cmux_log:
            print(f"FAIL: session {session_args} did not install OpenCode hooks, got {cmux_log!r}")
            return 1
        if real_log.strip() != " ".join(session_args):
            print(f"FAIL: session {session_args} did not exec real opencode, got {real_log!r}")
            return 1

    print("PASS: cmux OpenCode wrapper installs hooks only inside live cmux terminals")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
