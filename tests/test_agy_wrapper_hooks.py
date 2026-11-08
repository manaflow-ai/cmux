#!/usr/bin/env python3
"""Behavior checks for automatic Antigravity hook installation and launch capture."""

from __future__ import annotations

import base64
import json
import os
import signal
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
    custom_dir: str = "custom",
) -> dict[str, object]:
    bin_dir = root / "bin"
    bin_dir.mkdir()
    real_agy = (root / custom_dir / "agy") if custom_real_path else (bin_dir / "agy")
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


def shim(path: Path, root: Path) -> None:
    """A per-surface agy shim as cmux writes it: publish its own location, then run the wrapper."""
    path.parent.mkdir(parents=True, exist_ok=True)
    executable(
        path,
        "#!/bin/bash\n"
        f"export CMUX_AGY_WRAPPER_SHIM='{path}'\n"
        f"export CMUX_AGY_WRAPPER_SHIM_ROOT='{root}'\n"
        f"exec '{WRAPPER}' \"$@\"\n",
    )


def run_shim_case(root: Path, *, custom_points_at_shim: bool = False) -> dict[str, object]:
    """Launch agy through the surface shim with the shim, a stale shim, another cmux bundle's
    wrapper and the real agy on PATH, in that order."""
    shim_root = root / "home" / ".cmuxterm" / "cmux-cli-shims" / "surface-agy"
    stale_root = root / "home" / ".cmuxterm" / "cmux-cli-shims" / "surface-earlier"
    current_shim = shim_root / "agy"
    shim(current_shim, shim_root)
    shim(stale_root / "agy", stale_root)
    other_bundle_bin = root / "cmux NIGHTLY.app" / "Contents" / "Resources" / "bin"
    other_bundle_bin.mkdir(parents=True)
    executable(other_bundle_bin / "agy", "#!/bin/sh\nexit 97\n")
    # A cmux bundle ships its CLI beside its agent wrappers; that is how the wrapper recognizes one.
    executable(other_bundle_bin / "cmux", "#!/bin/sh\nexit 0\n")
    real_bin = root / "real-bin"
    real_bin.mkdir()
    real_result = root / "agy-result.json"
    executable(
        real_bin / "agy",
        "#!/bin/sh\n"
        "python3 -c 'import json,os,sys; json.dump({\"argv\":sys.argv[1:]}, open(os.environ[\"AGY_RESULT\"], \"w\"))' \"$@\"\n",
    )
    environment = {
        "PATH": f"{shim_root}:{stale_root}:{other_bundle_bin}:{real_bin}:/usr/bin:/bin",
        "HOME": str(root / "home"),
        "AGY_RESULT": str(real_result),
        "CMUX_SURFACE_ID": "surface-agy",
    }
    if custom_points_at_shim:
        environment["CMUX_CUSTOM_ANTIGRAVITY_PATH"] = str(current_shim)
    process = subprocess.Popen([str(current_shim), "--version"], env=environment, start_new_session=True)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise AssertionError(
            "agy through the surface shim did not exit within 5s: the wrapper re-entered a cmux agy "
            f"shim instead of the real agy (custom_points_at_shim={custom_points_at_shim})"
        ) from None
    if process.returncode != 0:
        raise AssertionError(
            f"agy through the surface shim exited {process.returncode}; 97 means it ran another cmux bundle's agy wrapper"
        )
    return json.loads(real_result.read_text(encoding="utf-8"))


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

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-app-bundle-") as directory:
        result = run_case(
            Path(directory),
            ("--prompt-interactive", "hello"),
            custom_real_path=True,
            custom_dir="Antigravity.app/Contents/Resources/bin",
        )
        if result["real"]["argv"] != ["--prompt-interactive", "hello"]:
            raise AssertionError(f"an agy shipped in another app's Resources/bin did not run: {result}")

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-shim-") as directory:
        real = run_shim_case(Path(directory))
        if real["argv"] != ["--version"]:
            raise AssertionError(f"real agy did not receive the shim's arguments: {real}")

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-custom-shim-") as directory:
        real = run_shim_case(Path(directory), custom_points_at_shim=True)
        if real["argv"] != ["--version"]:
            raise AssertionError(f"a custom path naming the shim did not fall back to the real agy: {real}")

    print("PASS: agy wrapper installs hooks, captures metadata, preserves custom executables, and skips cmux shims")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
