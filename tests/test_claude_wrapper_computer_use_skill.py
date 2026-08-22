#!/usr/bin/env python3
"""
Regression tests for cmux-claude-wrapper keeping the bundled cmux-cua skill
picker-visible: the durable ~/.claude/skills/cmux-cua link is the only
Claude-side delivery path (Claude shows personal skills there unqualified;
~/.agents/skills is Codex's root, which Claude does not scan), there is never
a --plugin-dir injection (plugin-delivered skills display qualified), and the
legacy ~/.agents/skills/cmux-computer-use link is migrated away. Global
discovery can be explicitly disabled.
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
    "name: cmux-cua\n"
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
    preexisting_legacy_link_target: Path | None = None,
    install_global_skill: bool = False,
    global_skill_opt_out: bool = False,
) -> tuple[subprocess.CompletedProcess[str], Path, Path, list[str]]:
    """Run the wrapper inside a sandboxed HOME and fake app bundle.

    Returns (result, skill_link_path, bundled_skill_dir, claude_args).
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

    bundled_skill = bundle_bin.parent / "cmux-cua"
    bundled_skill.mkdir()
    (bundled_skill / "SKILL.md").write_text(SKILL_MD, encoding="utf-8")

    args_log = root / "claude-args.log"
    write_executable(
        real_bin / "claude",
        """#!/bin/sh
: > "$FAKE_CLAUDE_ARGS_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_CLAUDE_ARGS_LOG"
done
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

    destination = home / ".claude" / "skills" / "cmux-cua"
    if preexisting_link_target is not None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.symlink_to(preexisting_link_target)
    if preexisting_directory:
        destination.mkdir(parents=True, exist_ok=True)
        (destination / "SKILL.md").write_text("user-owned\n", encoding="utf-8")
    if preexisting_legacy_link_target is not None:
        legacy = home / ".agents" / "skills" / "cmux-computer-use"
        legacy.parent.mkdir(parents=True, exist_ok=True)
        legacy.symlink_to(preexisting_legacy_link_target)

    env = {
        "HOME": str(home),
        "PATH": f"{real_bin}:/usr/bin:/bin",
        "TMPDIR": str(root),
        "CMUX_SURFACE_ID": "surface:test",
        "CMUX_SOCKET_PATH": str(socket_path),
        "CMUX_CLAUDE_SKIP_DEFAULTS": "1",
        "CMUX_CLAUDE_MANAGED_SETTINGS_FILE": str(root / "no-managed-settings.json"),
        "CMUX_CLAUDE_MANAGED_SETTINGS_DIR": str(root / "no-managed-settings.d"),
        "CMUX_CLAUDE_REMOTE_SETTINGS_FILE": str(root / "no-remote-settings.json"),
        "FAKE_CLAUDE_ARGS_LOG": str(args_log),
    }
    if disabled:
        env["CMUX_COMPUTER_USE_MCP_DISABLED"] = "1"
    if install_global_skill:
        env["CMUX_COMPUTER_USE_INSTALL_GLOBAL_SKILL"] = "1"
    elif global_skill_opt_out:
        env["CMUX_COMPUTER_USE_INSTALL_GLOBAL_SKILL"] = "0"

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
    args = args_log.read_text(encoding="utf-8").splitlines() if args_log.exists() else []
    return result, destination, bundled_skill, args


def plugin_dir_arg(args: list[str]) -> str | None:
    for index, arg in enumerate(args[:-1]):
        if arg == "--plugin-dir":
            return args[index + 1]
    return None


def test_claude_skill_is_global_without_plugin_duplicate_by_default(failures: list[str]) -> None:
    dangling = Path(
        "/nonexistent/cmux DEV old.app/Contents/Resources/cmux-cua"
    )
    result, link, bundled_skill, args = run_wrapper(
        ["hello"],
        preexisting_link_target=dangling,
    )
    expect(
        result.returncode == 0,
        f"wrapper exited {result.returncode}: {result.stdout} {result.stderr}",
        failures,
    )
    expect(
        link.is_symlink() and os.path.realpath(link) == os.path.realpath(bundled_skill),
        f"default launch must keep the skill discoverable in Claude's picker at {link}",
        failures,
    )
    # A --plugin-dir alongside the installed link would render the skill twice
    # and plugin-qualified (cmux-cua:cmux-cua) in the picker.
    expect(
        plugin_dir_arg(args) is None,
        f"expected no session plugin when the global link is installed, got {args}",
        failures,
    )


def test_claude_migrates_legacy_computer_use_link(failures: list[str]) -> None:
    legacy_target = Path(
        "/nonexistent/cmux DEV old.app/Contents/Resources/cmux-computer-use"
    )
    result, link, bundled_skill, args = run_wrapper(
        ["hello"],
        preexisting_legacy_link_target=legacy_target,
    )
    expect(
        result.returncode == 0,
        f"wrapper exited {result.returncode}: {result.stdout} {result.stderr}",
        failures,
    )
    legacy = link.parents[2] / ".agents" / "skills" / "cmux-computer-use"
    expect(
        not legacy.exists() and not legacy.is_symlink(),
        f"expected the cmux-owned legacy link removed, found {legacy}",
        failures,
    )
    expect(
        link.is_symlink() and os.path.realpath(link) == os.path.realpath(bundled_skill),
        f"expected the cmux-cua link installed at {link}",
        failures,
    )
    expect(
        plugin_dir_arg(args) is None,
        f"expected no session plugin after migration, got {args}",
        failures,
    )


def test_claude_leaves_user_owned_legacy_links_alone(failures: list[str]) -> None:
    foreign = Path("/nonexistent/user-owned-computer-use-skill")
    result, link, _, _ = run_wrapper(
        ["hello"],
        preexisting_legacy_link_target=foreign,
    )
    expect(
        result.returncode == 0,
        f"wrapper exited {result.returncode}: {result.stdout} {result.stderr}",
        failures,
    )
    legacy = link.parents[2] / ".agents" / "skills" / "cmux-computer-use"
    expect(
        legacy.is_symlink() and os.readlink(legacy) == str(foreign),
        "expected a user-owned cmux-computer-use link untouched by migration",
        failures,
    )


def test_claude_global_skill_can_be_disabled_explicitly(failures: list[str]) -> None:
    result, link, bundled_skill, args = run_wrapper(
        ["hello"],
        global_skill_opt_out=True,
    )
    expect(
        result.returncode == 0,
        f"wrapper exited {result.returncode}: {result.stdout} {result.stderr}",
        failures,
    )
    expect(
        not link.exists() and not link.is_symlink(),
        f"expected explicit opt-out to leave the global link absent, got "
        f"{os.readlink(link) if link.is_symlink() else 'missing'}",
        failures,
    )
    expect(
        plugin_dir_arg(args) is None,
        f"expected no plugin injection under global opt-out, got {args}",
        failures,
    )


def test_claude_leaves_user_owned_skill_links_alone(failures: list[str]) -> None:
    foreign = Path("/nonexistent/user-owned-skill")
    result, link, bundled_skill, args = run_wrapper(
        ["hello"],
        preexisting_link_target=foreign,
        install_global_skill=True,
    )
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
    expect(
        plugin_dir_arg(args) is None,
        f"expected no plugin injection even when the link is user-owned, got {args}",
        failures,
    )


def test_claude_leaves_user_owned_skill_directories_alone(failures: list[str]) -> None:
    result, link, bundled_skill, args = run_wrapper(
        ["hello"],
        preexisting_directory=True,
        install_global_skill=True,
    )
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
    expect(
        plugin_dir_arg(args) is None,
        f"expected no plugin injection even when the path is user-owned, got {args}",
        failures,
    )


def test_disabled_computer_use_skips_skill_loading(failures: list[str]) -> None:
    result, link, _, args = run_wrapper(
        ["hello"],
        disabled=True,
        install_global_skill=True,
    )
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
    expect(
        plugin_dir_arg(args) is None,
        f"expected no session plugin when computer use is disabled, got {args}",
        failures,
    )


def test_strict_mcp_config_skips_all_computer_use_sideloading(failures: list[str]) -> None:
    result, link, _, args = run_wrapper(
        ["--strict-mcp-config", "--mcp-config", "{}", "-p", "hello"],
        install_global_skill=True,
    )
    expect(
        result.returncode == 0,
        f"strict wrapper exited {result.returncode}: {result.stdout} {result.stderr}",
        failures,
    )
    expect(plugin_dir_arg(args) is None, f"strict mode loaded cmux plugin: {args}", failures)
    expect(
        not link.exists() and not link.is_symlink(),
        f"strict mode wrote global skill state at {link}",
        failures,
    )


def main() -> int:
    failures: list[str] = []
    test_claude_skill_is_global_without_plugin_duplicate_by_default(failures)
    test_claude_migrates_legacy_computer_use_link(failures)
    test_claude_leaves_user_owned_legacy_links_alone(failures)
    test_claude_global_skill_can_be_disabled_explicitly(failures)
    test_claude_leaves_user_owned_skill_links_alone(failures)
    test_claude_leaves_user_owned_skill_directories_alone(failures)
    test_disabled_computer_use_skips_skill_loading(failures)
    test_strict_mcp_config_skips_all_computer_use_sideloading(failures)
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: claude wrapper keeps the cmux-cua skill picker-visible with no plugin injection")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
