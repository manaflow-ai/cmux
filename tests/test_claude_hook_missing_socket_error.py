#!/usr/bin/env python3
"""
Regression test: claude-hook stop surfaces a clear socket-connect error when target socket is missing.
"""

from __future__ import annotations

import glob
import os
import shutil
import subprocess
import tempfile


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates = [p for p in candidates if os.path.exists(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    missing_socket = os.path.join(tempfile.gettempdir(), f"cmux-missing-{os.getpid()}.sock")
    try:
        if os.path.exists(missing_socket):
            os.remove(missing_socket)
    except OSError:
        pass

    env = os.environ.copy()
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    env.pop("CMUX_SOCKET_PATH", None)

    proc = subprocess.run(
        [cli_path, "--socket", missing_socket, "claude-hook", "stop"],
        input="{}",
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )

    if proc.returncode == 0:
        print("FAIL: expected non-zero exit when socket is missing")
        print(f"stdout={proc.stdout}")
        print(f"stderr={proc.stderr}")
        return 1

    expected_prefixes = [
        f"Error: Socket not found at {missing_socket}",
        f"Error: Failed to connect to socket at {missing_socket}",
    ]
    if not any(prefix in proc.stderr for prefix in expected_prefixes):
        print("FAIL: missing expected socket error text")
        print(f"expected one of: {expected_prefixes!r}")
        print(f"stderr: {proc.stderr!r}")
        return 1

    print("PASS: claude-hook stop missing-socket error is explicit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
