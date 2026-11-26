#!/usr/bin/env python3
"""Regression coverage for https://github.com/manaflow-ai/cmux/issues/12022.

The Claude wrapper points NODE_OPTIONS at a restore preload that every Node
child loads. macOS purges $TMPDIR under long-lived sessions, so a preload kept
there makes every later Node child die with MODULE_NOT_FOUND. The preload must
live in ~/.cmuxterm instead. Ported from #12067.
"""

from __future__ import annotations

import os
import re
import shutil
import socket
import stat
import subprocess
import tempfile
import time
from pathlib import Path

from node_runtime import ensure_node_on_path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def wait_for_text(path: Path, timeout: float = 30.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            value = path.read_text(encoding="utf-8").strip()
            if value:
                return value
        time.sleep(0.02)
    raise TimeoutError(f"timed out waiting for {path}")


def main() -> int:
    node_path = ensure_node_on_path()
    if node_path is None:
        print("SKIP: node runtime not found; Claude child probe requires node")
        return 0

    with tempfile.TemporaryDirectory(prefix="cmux-claude-tmpdir-purge-") as td:
        root = Path(td)
        wrapper_dir = root / "cmux.app" / "Contents" / "Resources" / "bin"
        real_dir = root / "real-bin"
        home_dir = root / "home with spaces"
        session_tmpdir = root / "session-tmp"
        for directory in (wrapper_dir, real_dir, home_dir, session_tmpdir):
            directory.mkdir(parents=True)
        user_preload = root / "user-preload.cjs"
        user_preload.write_text("// preserved user preload\n", encoding="utf-8")

        wrapper = wrapper_dir / "cmux-claude-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        ready_path = root / "ready"
        continue_path = root / "continue"
        make_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--help" ]]; then
  # Subcommand discovery probe: report no subcommands.
  exit 0
fi
printf '%s\\n' "${NODE_OPTIONS-__UNSET__}" > "$FAKE_READY_PATH"
while [[ ! -e "$FAKE_CONTINUE_PATH" ]]; do
  sleep 0.02
done
exec node -e 'process.stdout.write(process.env.NODE_OPTIONS || "__UNSET__")'
""",
        )
        make_executable(wrapper_dir / "cmux", "#!/usr/bin/env bash\nexit 0\n")

        socket_path = root / "cmux.sock"
        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        test_socket.bind(str(socket_path))
        try:
            environment = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("CMUX_") and key != "NODE_OPTIONS"
            }
            environment.update(
                {
                    "PATH": f"{Path(node_path).parent}:{wrapper_dir}:{real_dir}:/usr/bin:/bin",
                    "HOME": str(home_dir),
                    "TMPDIR": str(session_tmpdir),
                    "CMUX_SURFACE_ID": "surface:test",
                    "CMUX_SOCKET_PATH": str(socket_path),
                    "CMUX_BUNDLED_CLI_PATH": str(wrapper_dir / "cmux"),
                    "CMUX_CUSTOM_CLAUDE_PATH": str(real_dir / "claude"),
                    "NODE_OPTIONS": f"--require={user_preload}",
                    "FAKE_READY_PATH": str(ready_path),
                    "FAKE_CONTINUE_PATH": str(continue_path),
                }
            )
            process = subprocess.Popen(
                [str(wrapper), "hello"],
                cwd=root,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                node_options = wait_for_text(ready_path)
                # Simulate the macOS temp purge while the session is alive.
                for child in session_tmpdir.iterdir():
                    if child.is_dir() and not child.is_symlink():
                        shutil.rmtree(child, ignore_errors=True)
                    else:
                        child.unlink(missing_ok=True)
                continue_path.touch()
                stdout, stderr = process.communicate(timeout=30)
            except (TimeoutError, subprocess.TimeoutExpired) as exc:
                continue_path.touch()
                process.kill()
                stdout, stderr = process.communicate()
                print(f"FAIL: wrapped Claude did not finish: {exc}")
                print(f"stdout={stdout!r}")
                print(f"stderr={stderr!r}")
                return 1
        finally:
            test_socket.close()

        if process.returncode != 0:
            print("FAIL: Node child died after TMPDIR was purged")
            print(f"exit={process.returncode}")
            print(f"stdout={stdout!r}")
            print(f"stderr={stderr!r}")
            return 1
        if stdout != f"--require={user_preload}":
            print(f"FAIL: original NODE_OPTIONS was not restored in the Node child: {stdout!r}")
            return 1

        match = re.search(r'--require="([^"]+)"|--require=(\S+)', node_options)
        if match is None:
            print(f"FAIL: wrapped Claude did not receive a restore preload: {node_options!r}")
            return 1
        restore_path = Path(match.group(1) or match.group(2))
        expected_dir = home_dir / ".cmuxterm" / "cmux-claude-node-options"
        if restore_path != expected_dir / "restore-node-options.cjs":
            print(f"FAIL: restore preload is not under ~/.cmuxterm: {restore_path}")
            return 1
        if node_options.count("restore-node-options.cjs") != 1:
            print(f"FAIL: expected one restore preload, got {node_options!r}")
            return 1
        mode = stat.S_IMODE(expected_dir.stat().st_mode)
        if mode != 0o700:
            print(f"FAIL: restore preload directory mode is {oct(mode)}, expected 0o700")
            return 1

    print("PASS: Claude Node children survive a TMPDIR purge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
