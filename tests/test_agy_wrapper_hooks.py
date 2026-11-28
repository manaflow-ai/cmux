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
    bin_dir_name: str = "bin",
    sibling_cmux_dir: bool = False,
) -> dict[str, object]:
    """Run the wrapper directly with a fake real agy and a fake cmux CLI behind a listening socket.

    Returns what the real agy received, the cmux calls the wrapper made, and the socket path.
    """
    bin_dir = root / bin_dir_name
    bin_dir.mkdir(parents=True)
    real_agy = (root / custom_dir / "agy") if custom_real_path else (bin_dir / "agy")
    real_agy.parent.mkdir(parents=True, exist_ok=True)
    if sibling_cmux_dir:
        # A directory named cmux beside the real agy, which is not a cmux CLI.
        (real_agy.parent / "cmux").mkdir()
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


def run_shim_case(root: Path, *, custom_target: str | None = None, real_agy: bool = True) -> dict[str, object]:
    """Launch agy through the surface shim with the shim, a stale shim, another cmux bundle's
    wrapper and, unless real_agy is False, the real agy on PATH, in that order.

    `custom_target` sets CMUX_CUSTOM_ANTIGRAVITY_PATH to the current shim ("shim") or to the other
    bundle's wrapper ("other-bundle"). Returns the exit code, stderr, and what the real agy received
    (None when it did not run).
    """
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
    if real_agy:
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
    if custom_target == "shim":
        environment["CMUX_CUSTOM_ANTIGRAVITY_PATH"] = str(current_shim)
    elif custom_target == "other-bundle":
        environment["CMUX_CUSTOM_ANTIGRAVITY_PATH"] = str(other_bundle_bin / "agy")
    process = subprocess.Popen(
        [str(current_shim), "--version"],
        env=environment,
        start_new_session=True,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        _, stderr = process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise AssertionError(
            "agy through the surface shim did not exit within 5s: the wrapper re-entered a cmux agy "
            f"shim instead of the real agy (custom_target={custom_target}, real_agy={real_agy})"
        ) from None
    real = json.loads(real_result.read_text(encoding="utf-8")) if real_result.exists() else None
    return {"returncode": process.returncode, "stderr": stderr, "real": real}


def expect_real_agy_ran(result: dict[str, object], description: str) -> None:
    """Fail unless the shim launch exited cleanly after the real agy received `--version`."""
    if result["returncode"] != 0:
        raise AssertionError(
            f"{description}: exited {result['returncode']}; 97 means it ran another cmux bundle's agy wrapper"
        )
    if result["real"] != {"argv": ["--version"]}:
        raise AssertionError(f"{description}: real agy did not receive the shim's arguments: {result}")


def main() -> int:
    """Run every agy wrapper scenario; a regression raises AssertionError."""
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

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-app-bundle-path-") as directory:
        result = run_case(
            Path(directory),
            ("--prompt-interactive", "hello"),
            bin_dir_name="Antigravity.app/Contents/Resources/bin",
        )
        if result["real"]["argv"] != ["--prompt-interactive", "hello"]:
            raise AssertionError(f"an agy found on PATH in another app's Resources/bin did not run: {result}")

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-cmux-dir-") as directory:
        result = run_case(
            Path(directory),
            ("--prompt-interactive", "hello"),
            bin_dir_name="Antigravity.app/Contents/Resources/bin",
            sibling_cmux_dir=True,
        )
        if result["real"]["argv"] != ["--prompt-interactive", "hello"]:
            raise AssertionError(f"a cmux directory beside another app's agy hid that agy: {result}")

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-shim-") as directory:
        expect_real_agy_ran(run_shim_case(Path(directory)), "agy through the surface shim")

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-custom-shim-") as directory:
        expect_real_agy_ran(
            run_shim_case(Path(directory), custom_target="shim"),
            "a custom path naming the shim",
        )

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-custom-bundle-") as directory:
        expect_real_agy_ran(
            run_shim_case(Path(directory), custom_target="other-bundle"),
            "a custom path naming another cmux bundle's wrapper",
        )

    with tempfile.TemporaryDirectory(prefix="cmux-agy-wrapper-shim-only-") as directory:
        result = run_shim_case(Path(directory), real_agy=False)
        stderr = str(result["stderr"])
        if result["returncode"] != 127 or "agy executable not found" not in stderr or "PATH" in stderr:
            raise AssertionError(
                f"with only cmux shims and wrappers on PATH, agy must exit 127 with a not-found error "
                f"that does not name PATH: {result}"
            )

    print("PASS: agy wrapper installs hooks, captures metadata, preserves custom executables, and skips cmux shims")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
