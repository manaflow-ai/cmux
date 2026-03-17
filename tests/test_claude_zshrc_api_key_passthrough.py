#!/usr/bin/env python3
"""
Regression: a Claude auth env var exported from the user's .zshrc should still
reach the real Claude binary when cmux's zsh wrapper and Claude wrapper are both
active.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHELL_WRAPPER_DIR = ROOT / "Resources" / "shell-integration"
SOURCE_CLAUDE_WRAPPER = ROOT / "Resources" / "bin" / "claude"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8").strip()


def main() -> int:
    zsh_bin = shutil.which("zsh")
    if not (SHELL_WRAPPER_DIR / ".zshenv").exists():
        print(f"SKIP: missing zsh wrapper at {SHELL_WRAPPER_DIR}")
        return 0
    if zsh_bin is None:
        print("SKIP: zsh is not available on PATH")
        return 0
    if not SOURCE_CLAUDE_WRAPPER.exists():
        print(f"SKIP: missing Claude wrapper at {SOURCE_CLAUDE_WRAPPER}")
        return 0

    base = Path(tempfile.gettempdir()) / f"cmux_claude_zshrc_auth_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)

        home = base / "home"
        orig_zdotdir = base / "zdotdir"
        wrapper_bin = base / "wrapper-bin"
        real_bin = base / "real-bin"
        for path in (home, orig_zdotdir, wrapper_bin, real_bin):
            path.mkdir(parents=True, exist_ok=True)

        seen_key_path = base / "seen-api-key.txt"
        seen_args_path = base / "seen-args.txt"
        cmux_log_path = base / "cmux.log"
        socket_path = base / "cmux.sock"

        (orig_zdotdir / ".zshrc").write_text(
            'export ANTHROPIC_API_KEY="from-zshrc"\n',
            encoding="utf-8",
        )

        shutil.copy2(SOURCE_CLAUDE_WRAPPER, wrapper_bin / "claude")
        (wrapper_bin / "claude").chmod(0o755)

        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "${ANTHROPIC_API_KEY-__UNSET__}" > "$FAKE_SEEN_KEY_PATH"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_SEEN_ARGS_PATH"
done
""",
        )

        make_executable(
            wrapper_bin / "cmux",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_CMUX_LOG"
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  exit 0
fi
exit 0
""",
        )

        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        test_socket.bind(str(socket_path))

        env = dict(os.environ)
        env["HOME"] = str(home)
        env["USER"] = env.get("USER", "cmux-test")
        env["SHELL"] = "/bin/zsh"
        env["ZDOTDIR"] = str(SHELL_WRAPPER_DIR)
        env["CMUX_ZSH_ZDOTDIR"] = str(orig_zdotdir)
        env["CMUX_SHELL_INTEGRATION"] = "0"
        env["PATH"] = f"{wrapper_bin}:{real_bin}:/usr/bin:/bin"
        env["CMUX_SURFACE_ID"] = "surface:test"
        env["CMUX_SOCKET_PATH"] = str(socket_path)
        env["FAKE_SEEN_KEY_PATH"] = str(seen_key_path)
        env["FAKE_SEEN_ARGS_PATH"] = str(seen_args_path)
        env["FAKE_CMUX_LOG"] = str(cmux_log_path)

        try:
            result = subprocess.run(
                [zsh_bin, "-d", "-i", "-c", "claude hello"],
                env=env,
                capture_output=True,
                text=True,
                timeout=8,
                check=False,
            )
        finally:
            test_socket.close()

        if result.returncode != 0:
            print(f"FAIL: zsh exited non-zero rc={result.returncode}")
            if result.stderr.strip():
                print(result.stderr.strip())
            return 1

        seen_key = read_text(seen_key_path)
        if seen_key != "from-zshrc":
            print(f"FAIL: expected ANTHROPIC_API_KEY from .zshrc, got {seen_key!r}")
            return 1

        seen_args = [line for line in read_text(seen_args_path).splitlines() if line]
        if "--settings" not in seen_args or "--session-id" not in seen_args or "hello" not in seen_args:
            print(f"FAIL: expected wrapped Claude args, got {seen_args!r}")
            return 1

        cmux_log = read_text(cmux_log_path)
        if "ping" not in cmux_log:
            print(f"FAIL: expected wrapper to probe cmux socket, got {cmux_log!r}")
            return 1

        print("PASS: .zshrc-exported Claude auth env reaches wrapped claude")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
