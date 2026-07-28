#!/usr/bin/env python3
"""
Regression tests for cmux-claude-wrapper installing the bundled
cmux-computer-use skill link under ~/.agents/skills.

Only the Codex wrapper used to maintain that link. When a dev-build cleanup
removed the app bundle the link targeted, every Claude session silently lost
the skill until some Codex session happened to repair it. The Claude wrapper
must install and repair the same link itself.
"""

from __future__ import annotations

import os
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"

SKILL_MD = (
    "---\n"
    "name: cmux-computer-use\n"
    "description: Test bundled cmux Computer Use skill.\n"
    "---\n"
    "\n"
    "Use the bundled Computer Use tools.\n"
)


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def run_wrapper(
    argv: list[str],
    *,
    disabled: bool = False,
    preexisting_link_target: Path | None = None,
    preexisting_directory: bool = False,
) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
    """Run the wrapper inside a sandboxed HOME and fake app bundle.

    Returns (result, skill_link_path, bundled_skill_dir).
    """
    td = tempfile.mkdtemp(prefix="cmux-claude-wrapper-skill-")
    root = Path(td)
    home = root / "home"
    bundle_bin = root / "cmux.app" / "Contents" / "Resources" / "bin"
    real_bin = root / "real-bin"
    for directory in (home, bundle_bin, real_bin):
        directory.mkdir(parents=True, exist_ok=True)

    wrapper = bundle_bin / "cmux-claude-wrapper"
    wrapper.write_bytes(WRAPPER.read_bytes())
    wrapper.chmod(0o755)

    bundled_skill = bundle_bin.parent / "cmux-computer-use"
    bundled_skill.mkdir()
    (bundled_skill / "SKILL.md").write_text(SKILL_MD, encoding="utf-8")

    write_executable(
        real_bin / "claude",
        """#!/bin/sh
echo real-claude "$@"
""",
    )

    # The wrapper only reaches computer-use setup with authoritative evidence
    # of a live cmux: a surface id plus a socket its bundled CLI can ping.
    socket_path = root / "cmux.sock"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(socket_path))
    listener.listen(1)
    write_executable(
        bundle_bin / "cmux",
        """#!/bin/sh
if [ "$1" = "--socket" ]; then
  shift 2
fi
if [ "$1" = "ping" ]; then
  exit 0
fi
exit 1
""",
    )

    destination = home / ".agents" / "skills" / "cmux-computer-use"
    if preexisting_link_target is not None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.symlink_to(preexisting_link_target)
    if preexisting_directory:
        destination.mkdir(parents=True, exist_ok=True)
        (destination / "SKILL.md").write_text("user-owned\n", encoding="utf-8")

    env = {
        "HOME": str(home),
        "PATH": f"{real_bin}:/usr/bin:/bin",
        "TMPDIR": str(root),
        "CMUX_SURFACE_ID": "surface:test",
        "CMUX_SOCKET_PATH": str(socket_path),
    }
    if disabled:
        env["CMUX_COMPUTER_USE_MCP_DISABLED"] = "1"

    try:
        result = subprocess.run(
            [str(wrapper), *argv],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    finally:
        listener.close()
    return result, destination, bundled_skill


def test_claude_installs_bundled_computer_use_skill(failures: list[str]) -> None:
    result, link, bundled_skill = run_wrapper(["hello"])
    expect(
        result.returncode == 0,
        f"wrapper exited {result.returncode}: {result.stdout} {result.stderr}",
        failures,
    )
    expect(link.is_symlink(), f"expected a skill symlink at {link}", failures)
    expect(
        os.path.realpath(link) == os.path.realpath(bundled_skill),
        f"expected link -> {bundled_skill}, got {os.readlink(link) if link.is_symlink() else 'missing'}",
        failures,
    )
    content = (link / "SKILL.md").read_text(encoding="utf-8") if link.exists() else ""
    expect(
        "name: cmux-computer-use" in content,
        f"expected Claude-readable SKILL.md through the link, got {content!r}",
        failures,
    )


def test_claude_repairs_dangling_skill_link(failures: list[str]) -> None:
    # A removed dev build leaves the link targeting
    # .../<gone>.app/Contents/Resources/cmux-computer-use. Repair it.
    dangling = Path(
        "/nonexistent/cmux DEV old.app/Contents/Resources/cmux-computer-use"
    )
    result, link, bundled_skill = run_wrapper(
        ["hello"], preexisting_link_target=dangling
    )
    expect(
        result.returncode == 0,
        f"wrapper exited {result.returncode}: {result.stdout} {result.stderr}",
        failures,
    )
    expect(
        link.is_symlink()
        and os.path.realpath(link) == os.path.realpath(bundled_skill),
        f"expected dangling app-bundle link repaired to {bundled_skill}, got "
        f"{os.readlink(link) if link.is_symlink() else 'missing'}",
        failures,
    )


def test_claude_leaves_user_owned_skill_links_alone(failures: list[str]) -> None:
    foreign = Path("/nonexistent/user-owned-skill")
    result, link, _ = run_wrapper(["hello"], preexisting_link_target=foreign)
    expect(
        result.returncode == 0,
        f"wrapper exited {result.returncode}: {result.stdout} {result.stderr}",
        failures,
    )
    expect(
        link.is_symlink() and os.readlink(link) == str(foreign),
        f"expected user-owned link untouched, got "
        f"{os.readlink(link) if link.is_symlink() else 'replaced'}",
        failures,
    )


def test_claude_leaves_user_owned_skill_directories_alone(failures: list[str]) -> None:
    result, link, _ = run_wrapper(["hello"], preexisting_directory=True)
    expect(
        result.returncode == 0,
        f"wrapper exited {result.returncode}: {result.stdout} {result.stderr}",
        failures,
    )
    expect(
        link.is_dir() and not link.is_symlink(),
        "expected user-owned skill directory untouched",
        failures,
    )
    content = (link / "SKILL.md").read_text(encoding="utf-8")
    expect(
        content == "user-owned\n",
        f"expected user-owned SKILL.md preserved, got {content!r}",
        failures,
    )


def test_disabled_computer_use_skips_skill_install(failures: list[str]) -> None:
    result, link, _ = run_wrapper(["hello"], disabled=True)
    expect(
        result.returncode == 0,
        f"wrapper exited {result.returncode}: {result.stdout} {result.stderr}",
        failures,
    )
    expect(
        not link.exists() and not link.is_symlink(),
        f"expected no skill install when computer use is disabled, found {link}",
        failures,
    )


def main() -> int:
    failures: list[str] = []
    test_claude_installs_bundled_computer_use_skill(failures)
    test_claude_repairs_dangling_skill_link(failures)
    test_claude_leaves_user_owned_skill_links_alone(failures)
    test_claude_leaves_user_owned_skill_directories_alone(failures)
    test_disabled_computer_use_skips_skill_install(failures)
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: claude wrapper installs and repairs the Computer Use skill link")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
