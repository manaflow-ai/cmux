#!/usr/bin/env python3
"""Regression test: explicit --socket must bypass implicit socket discovery."""

from __future__ import annotations

import glob
import os
import shutil
import socket
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


def create_stale_unix_socket(path: str) -> None:
    if os.path.exists(path):
        os.remove(path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(path)
    finally:
        server.close()


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    tag = f"cli-explicit-socket-{os.getpid()}"
    tagged_socket_path = f"/tmp/cmux-debug-{tag}.sock"

    with tempfile.TemporaryDirectory(prefix="cmux-cli-explicit-home-") as home:
        explicit_socket_path = os.path.join(home, "Library", "Application Support", "cmux", "cmux.sock")
        create_stale_unix_socket(tagged_socket_path)

        env = os.environ.copy()
        env["HOME"] = home
        env["CMUX_TAG"] = tag
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        env.pop("CMUX_SOCKET", None)
        env.pop("CMUX_SOCKET_PATH", None)

        cases = [
            ("separate --socket", ["--socket", explicit_socket_path, "ping"]),
            ("attached --socket", [f"--socket={explicit_socket_path}", "ping"]),
            (
                "repeated --socket last wins",
                ["--socket", tagged_socket_path, "--socket", explicit_socket_path, "ping"],
            ),
        ]

        try:
            for name, args in cases:
                proc = subprocess.run(  # noqa: S603
                    [cli_path, *args],
                    text=True,
                    capture_output=True,
                    env=env,
                    timeout=8,
                    check=False,
                )

                if proc.returncode == 0:
                    print(f"FAIL: {name} unexpectedly succeeded")
                    print(f"stdout={proc.stdout!r}")
                    print(f"stderr={proc.stderr!r}")
                    return 1

                merged = f"{proc.stdout}\n{proc.stderr}"
                if explicit_socket_path not in merged:
                    print(f"FAIL: {name} error did not mention the requested socket")
                    print(f"expected={explicit_socket_path!r}")
                    print(f"tagged_socket={tagged_socket_path!r}")
                    print(f"stdout={proc.stdout!r}")
                    print(f"stderr={proc.stderr!r}")
                    return 1
                if tagged_socket_path in merged:
                    print(f"FAIL: {name} was replaced with a tagged discovered socket")
                    print(f"explicit_socket={explicit_socket_path!r}")
                    print(f"tagged_socket={tagged_socket_path!r}")
                    print(f"stdout={proc.stdout!r}")
                    print(f"stderr={proc.stderr!r}")
                    return 1
        finally:
            try:
                os.remove(tagged_socket_path)
            except OSError:
                pass

    print("PASS: explicit --socket forms bypass implicit socket autodiscovery")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
