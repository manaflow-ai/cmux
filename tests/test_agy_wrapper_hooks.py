#!/usr/bin/env python3
"""Behavior checks for automatic Antigravity hook installation and launch capture."""

from __future__ import annotations

import base64
import json
import os
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "agy"


def executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def run_case(
    root: Path,
    args: tuple[str, ...],
    *,
    in_cmux: bool = True,
    custom_real_path: bool = False,
) -> dict[str, object]:
    bin_dir = root / "bin"
    bin_dir.mkdir()
    real_agy = (root / "custom" / "agy") if custom_real_path else (bin_dir / "agy")
    real_agy.parent.mkdir(parents=True, exist_ok=True)
    real_result = root / "agy-result.json"
    executable(
        real_agy,
        "#!/bin/sh\n"
        "python3 -c 'import json,os,sys; json.dump({\"argv\":sys.argv[1:],\"env\":dict(os.environ)}, open(os.environ[\"AGY_RESULT\"], \"w\"))' \"$@\"\n",
    )
    cmux_log = root / "cmux-calls.json"
    fake_cmux = root / "cmux"
    executable(
        fake_cmux,
        "#!/bin/sh\n"
        "python3 -c 'import json,os,sys; open(os.environ[\"CMUX_LOG\"], \"a\").write(json.dumps({\"argv\":sys.argv[1:],\"env\":dict(os.environ)})+\"\\n\")' \"$@\"\n"
        "exit 0\n",
    )

    socket_path = root / "cmux.sock"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(socket_path))
    listener.listen(1)
    try:
        environment = {
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "HOME": str(root / "home"),
            "CMUX_BUNDLED_CLI_PATH": str(fake_cmux),
            "CMUX_SOCKET_PATH": str(socket_path),
            "AGY_RESULT": str(real_result),
            "CMUX_LOG": str(cmux_log),
        }
        if custom_real_path:
            environment["CMUX_CUSTOM_ANTIGRAVITY_PATH"] = str(real_agy)
        if in_cmux:
            environment["CMUX_SURFACE_ID"] = "surface-agy"
        subprocess.run([str(WRAPPER), *args], env=environment, check=True, timeout=5)
    finally:
        listener.close()

    real = json.loads(real_result.read_text(encoding="utf-8"))
    calls = []
    if cmux_log.exists():
        calls = [json.loads(line) for line in cmux_log.read_text(encoding="utf-8").splitlines()]
    return {"real": real, "calls": calls, "socket": str(socket_path)}


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-") as directory:
        root = Path(directory)
        result = run_case(root, ("--prompt-interactive", "hello"))
        real = result["real"]
        if real["argv"] != ["--prompt-interactive", "hello"]:
            raise AssertionError(f"agy arguments changed: {real}")
        if result["calls"][0]["argv"] != ["--socket", result["socket"], "ping"]:
            raise AssertionError(f"wrapper did not probe the cmux socket: {result}")
        if result["calls"][1]["argv"] != ["--socket", result["socket"], "hooks", "agy", "install", "--yes"]:
            raise AssertionError(f"wrapper did not install agy hooks: {result}")
        if real["env"].get("CMUX_AGENT_LAUNCH_KIND") != "antigravity":
            raise AssertionError(f"missing agy launch kind: {real}")
        if real["env"].get("CMUX_AGENT_LAUNCH_CWD") != str(Path.cwd()):
            raise AssertionError(f"missing agy launch cwd: {real}")
        decoded = base64.b64decode(real["env"]["CMUX_AGENT_LAUNCH_ARGV_B64"]).split(b"\0")
        if not decoded[0].endswith(b"/bin/agy") or decoded[1:-1] != [b"--prompt-interactive", b"hello"]:
            raise AssertionError(f"launch argv was not captured: {decoded!r}")

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-management-") as directory:
        result = run_case(Path(directory), ("models",))
        if result["calls"]:
            raise AssertionError(f"management command unexpectedly installed hooks: {result}")
        if "CMUX_AGENT_LAUNCH_KIND" in result["real"]["env"]:
            raise AssertionError(f"management command unexpectedly captured launch metadata: {result}")

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-mic-serve-") as directory:
        result = run_case(Path(directory), ("mic-serve",))
        if result["calls"]:
            raise AssertionError(f"mic-serve unexpectedly installed hooks: {result}")
        if "CMUX_AGENT_LAUNCH_KIND" in result["real"]["env"]:
            raise AssertionError(f"mic-serve unexpectedly captured launch metadata: {result}")

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-prompt-") as directory:
        result = run_case(Path(directory), ("-i", "models"))
        if len(result["calls"]) != 2 or "CMUX_AGENT_LAUNCH_KIND" not in result["real"]["env"]:
            raise AssertionError(f"initial prompt was mistaken for a management command: {result}")

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-outside-") as directory:
        result = run_case(Path(directory), ("--prompt-interactive", "hello"), in_cmux=False)
        if result["calls"]:
            raise AssertionError(f"outside-cmux agy unexpectedly called cmux: {result}")
        if "CMUX_AGENT_LAUNCH_KIND" in result["real"]["env"]:
            raise AssertionError(f"outside-cmux agy unexpectedly captured metadata: {result}")

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-custom-") as directory:
        result = run_case(
            Path(directory),
            ("--prompt-interactive", "hello"),
            custom_real_path=True,
        )
        if result["real"]["argv"] != ["--prompt-interactive", "hello"]:
            raise AssertionError(f"custom agy executable did not run: {result}")
        if "CMUX_AGENT_LAUNCH_KIND" not in result["real"]["env"]:
            raise AssertionError(f"custom agy executable lost launch metadata: {result}")

    print("PASS: agy wrapper installs hooks, captures metadata, and preserves custom executables")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
