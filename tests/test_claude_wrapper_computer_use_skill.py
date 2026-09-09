#!/usr/bin/env python3
"""
Regression tests for cmux-claude-wrapper's explicit-install policy,
ownership-safe migration, and collision handling. Ordinary Claude launches do
not add a skill directory or plugin; legacy aliases are migrated only when
their targets prove cmux ownership.
"""

from __future__ import annotations

import os
import plistlib
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"
LINK_POLICY = ROOT / "skills" / "cmux-cua" / "link-policy.sh"

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
    preexisting_valid_cmux_link: bool = False,
    preexisting_directory: bool = False,
    preexisting_legacy_link_target: Path | None = None,
    project_skill_collision: bool = False,
    install_global_skill: bool = False,
    global_skill_opt_out: bool = False,
    cwd_under_home_no_git: bool = False,
    diagnostics: bool = False,
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
    (bundled_skill / "link-policy.sh").write_bytes(LINK_POLICY.read_bytes())
    project_skill = root / ".claude" / "skills" / "cmux-cua"
    if project_skill_collision:
        project_skill.mkdir(parents=True)
        (project_skill / "SKILL.md").write_text(
            "---\nname: cmux-cua\ndescription: Project-owned build skill.\n---\n\nProject instructions.\n",
            encoding="utf-8",
        )

    args_log = root / "claude-args.log"
    write_executable(
        real_bin / "claude",
        """#!/bin/sh
: > "$FAKE_CLAUDE_ARGS_LOG"
    mode=''
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_CLAUDE_ARGS_LOG"
  case "$arg" in
    --add-dir)
      mode='variadic'
      continue
      ;;
    --add-dir=*)
      mode=''
      continue
      ;;
    --mcp-config)
      mode='variadic'
      continue
      ;;
    --mcp-config=*)
      mode=''
      continue
      ;;
    --session-id|--settings)
      mode='single'
      continue
      ;;
    -*)
      mode=''
      continue
      ;;
  esac
  if [ "$mode" = 'variadic' ]; then
    continue
  fi
  if [ "$mode" = 'single' ]; then
    mode=''
    continue
  fi
  printf 'POSITIONAL=%s\\n' "$arg"
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
    if preexisting_valid_cmux_link:
        destination.parent.mkdir(parents=True, exist_ok=True)
        old_skill = home / "Library" / "Developer" / "Xcode" / "DerivedData" / "cmux-fixture" / "Build" / "Products" / "Debug" / "cmux DEV old.app" / "Contents" / "Resources" / "cmux-cua"
        old_skill.mkdir(parents=True)
        (old_skill / "SKILL.md").write_text(
            "---\nname: cmux-cua\ndescription: Old cmux skill.\n---\n\nOld bundle.\n",
            encoding="utf-8",
        )
        with (old_skill.parents[1] / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.cmuxterm.app.debug.fixture"}, stream)
        destination.symlink_to(old_skill)
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
    if diagnostics:
        env["CMUX_CUA_DIAGNOSTICS"] = "1"
    if install_global_skill:
        env["CMUX_COMPUTER_USE_INSTALL_GLOBAL_SKILL"] = "1"
    elif global_skill_opt_out:
        env["CMUX_COMPUTER_USE_INSTALL_GLOBAL_SKILL"] = "0"

    try:
        launch_cwd = home / "projects" / "plain" if cwd_under_home_no_git else root
        launch_cwd.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            [str(wrapper), *argv],
            cwd=launch_cwd,
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


def add_dir_arg(args: list[str]) -> str | None:
    for index, arg in enumerate(args):
        if arg.startswith("--add-dir="):
            return arg.split("=", 1)[1]
        if arg == "--add-dir" and index + 1 < len(args):
            return args[index + 1]
    return None


def test_claude_preserves_unverified_dangling_link_by_default(
    failures: list[str],
) -> None:
    dangling = Path(
        "/Applications/cmux DEV old.app/Contents/Resources/cmux-cua"
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
        link.is_symlink() and os.readlink(link) == str(dangling),
        f"unverified dangling link must be preserved at {link}",
        failures,
    )
    expect(
        plugin_dir_arg(args) is None,
        f"expected no plugin-qualified session skill, got {args}",
        failures,
    )
    expect(add_dir_arg(args) is None, f"default launch must not add an automatic skill directory, got {args}", failures)


def test_claude_default_is_session_scoped_without_global_mutation(
    failures: list[str],
) -> None:
    result, link, bundled_skill, args = run_wrapper(["hello"])
    expect(
        result.returncode == 0,
        f"default session wrapper exited {result.returncode}: {result.stderr}",
        failures,
    )
    expect(
        not link.exists() and not link.is_symlink(),
        f"default Claude launch unexpectedly wrote a global skill, got {link}",
        failures,
    )
    expect("skill-install=" not in result.stderr and "managed-link-retired" not in result.stderr,
           f"ordinary Claude launch must keep diagnostics quiet, got {result.stderr!r}", failures)
    expect(add_dir_arg(args) is None, f"default Claude launch must not add an automatic skill directory, got {args}", failures)
    expect(
        plugin_dir_arg(args) is None,
        f"ordinary launch must not use a plugin-qualified path, got {args}",
        failures,
    )


def test_claude_preserves_unverified_dangling_link_without_global_install(
    failures: list[str],
) -> None:
    dangling = Path("/Applications/cmux NIGHTLY old.app/Contents/Resources/cmux-cua")
    result, link, bundled_skill, args = run_wrapper(
        ["hello"],
        preexisting_link_target=dangling,
    )
    expect(
        result.returncode == 0,
        f"stale Claude link wrapper exited {result.returncode}: {result.stderr}",
        failures,
    )
    expect(
        link.is_symlink() and os.readlink(link) == str(dangling),
        f"unverified dangling link must be preserved under the new default, got {link}",
        failures,
    )
    expect(
        add_dir_arg(args) is None,
        f"unverified dangling link must suppress a duplicate session row, got {args}",
        failures,
    )


def test_claude_explicit_opt_in_preserves_unverified_dangling_link(
    failures: list[str],
) -> None:
    dangling = Path("/Applications/cmux NIGHTLY old.app/Contents/Resources/cmux-cua")
    result, link, bundled_skill, args = run_wrapper(
        ["hello"],
        preexisting_link_target=dangling,
        install_global_skill=True,
        diagnostics=True,
    )
    expect(
        result.returncode == 0,
        f"explicit stale Claude link wrapper exited {result.returncode}: {result.stderr}",
        failures,
    )
    expect(
        link.is_symlink() and os.readlink(link) == str(dangling),
        f"explicit opt-in must preserve an unverified dangling link, got {link}",
        failures,
    )
    expect("cmux-cua: skill-install=blocked-user-path" in result.stderr and str(link) in result.stderr,
           f"explicit blocked install must identify the preserved path, got {result.stderr!r}", failures)
    expect(
        add_dir_arg(args) is None,
        f"retargeted global link must not add a session duplicate, got {args}",
        failures,
    )


def test_claude_default_preserves_positional_prompt_without_skill_directory(
    failures: list[str],
) -> None:
    """An ordinary launch preserves the user's positional prompt."""
    result, _, _, args = run_wrapper(["fix this"])
    expect(
        result.returncode == 0,
        f"prompt-boundary wrapper exited {result.returncode}: {result.stderr}",
        failures,
    )
    expect(add_dir_arg(args) is None, f"ordinary launch must not add an automatic skill directory, got {args}", failures)
    expect(
        "POSITIONAL=fix this\n" in result.stdout,
        f"Claude's variadic parser must preserve the positional prompt, got {result.stdout!r}",
        failures,
    )


def test_claude_home_ancestor_is_not_project_collision(
    failures: list[str],
) -> None:
    for opt_in in (False, True):
        result, link, bundled_skill, args = run_wrapper(
            ["hello"], preexisting_valid_cmux_link=True,
            cwd_under_home_no_git=True, install_global_skill=opt_in,
            diagnostics=not opt_in,
        )
        expect(result.returncode == 0,
               f"home-ancestor Claude wrapper exited {result.returncode}: {result.stderr}", failures)
        expect(link.exists() is opt_in and link.is_symlink() is opt_in,
               f"per-launch opt-in={opt_in} must control the managed link at {link}", failures)
        if opt_in:
            expect(os.path.realpath(link) == os.path.realpath(bundled_skill),
                   f"HOME ancestor must permit retargeting to this exact bundle: {link}", failures)
        else:
            expect("managed-link-retired" in result.stderr and str(link) in result.stderr,
                   f"retired managed Claude link must be diagnosed, got {result.stderr!r}", failures)
        expect(add_dir_arg(args) is None,
               f"HOME ancestor must not add an automatic skill directory: {args}", failures)


def test_claude_collision_keeps_project_skill_and_avoids_second_row(
    failures: list[str],
) -> None:
    result, link, _, args = run_wrapper(
        ["hello"],
        project_skill_collision=True,
        install_global_skill=True,
        diagnostics=True,
    )
    expect(
        result.returncode == 0,
        f"Claude collision wrapper exited {result.returncode}: {result.stderr}",
        failures,
    )
    expect(
        not link.exists() and not link.is_symlink(),
        f"Claude collision must not create a global duplicate, got {link}",
        failures,
    )
    expect(
        add_dir_arg(args) is None,
        f"Claude collision must not add a second same-name session root, got {args}",
        failures,
    )
    expect("skill-install=blocked-project-collision" in result.stderr,
           f"explicit project collision must be diagnosed, got {result.stderr!r}", failures)


def test_claude_explicit_global_opt_in_remains_available(failures: list[str]) -> None:
    result, link, bundled_skill, args = run_wrapper(
        ["hello"],
        install_global_skill=True,
    )
    expect(
        result.returncode == 0,
        f"explicit Claude global wrapper exited {result.returncode}: {result.stderr}",
        failures,
    )
    expect(
        link.is_symlink() and os.path.realpath(link) == os.path.realpath(bundled_skill),
        f"explicit opt-in should install the bundled Claude link, got {link}",
        failures,
    )
    expect(
        add_dir_arg(args) is None,
        f"global Claude install must not add a duplicate session root, got {args}",
        failures,
    )


def test_claude_preserves_unverified_legacy_computer_use_link(failures: list[str]) -> None:
    legacy_target = Path(
        "/Applications/cmux DEV old.app/Contents/Resources/cmux-computer-use"
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
        legacy.is_symlink() and os.readlink(legacy) == str(legacy_target),
        f"unverified legacy link must be preserved, found {legacy}",
        failures,
    )
    expect(
        not link.exists() and not link.is_symlink(),
        f"canonical global link should remain absent after migration, got {link}",
        failures,
    )
    expect(
        plugin_dir_arg(args) is None,
        f"expected no session plugin after migration, got {args}",
        failures,
    )
    expect(
        add_dir_arg(args) is None,
        f"an unrelated-provider legacy link must not add automatic Claude discovery, got {args}",
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
    expect(
        add_dir_arg(args) is None,
        f"explicit opt-out must not add automatic Claude discovery, got {args}",
        failures,
    )


def test_claude_leaves_user_owned_skill_links_alone(failures: list[str]) -> None:
    # A user-owned link can use the same resource suffix and a misleading app
    # name; an untrusted root must not be treated as cmux ownership proof.
    foreign = Path(
        "/nonexistent/cmux NIGHTLY user-owned.app/Contents/Resources/cmux-cua"
    )
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
    test_claude_preserves_unverified_dangling_link_by_default(failures)
    test_claude_default_is_session_scoped_without_global_mutation(failures)
    test_claude_preserves_unverified_dangling_link_without_global_install(failures)
    test_claude_explicit_opt_in_preserves_unverified_dangling_link(failures)
    test_claude_default_preserves_positional_prompt_without_skill_directory(failures)
    test_claude_home_ancestor_is_not_project_collision(failures)
    test_claude_collision_keeps_project_skill_and_avoids_second_row(failures)
    test_claude_explicit_global_opt_in_remains_available(failures)
    test_claude_preserves_unverified_legacy_computer_use_link(failures)
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
    print("PASS: claude wrapper requires explicit skill installation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
