#!/usr/bin/env python3
"""Regression checks for reliable Codex session-entrypoint hook injection."""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-codex-wrapper"
SESSION_ID = "0198f073-0a5b-7000-8000-000000000059"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8").splitlines()


def run_wrapper(
    *,
    socket_state: str,
    argv: list[str],
    hooks_disabled: bool = False,
    restore_token: str | None = None,
    inject_args_available: bool = True,
    subrouter_marker: str | None = None,
    launch_command: str | None = None,
    in_cmux: bool = True,
    nested_launch: bool = False,
    launcher_preflight: bool = False,
    profile_reorders_path: bool = False,
    inherited_path_reorders_path: bool = False,
    managed_shim_available: bool = True,
    inherited_other_agent: bool = False,
    sibling_shim_available: bool = True,
) -> tuple[int, list[str], list[str], dict[str, str], str]:
    """Run the production wrapper with disposable fake Codex and cmux executables.

    Launcher, PATH and inherited-identity variants expose the actual forwarded argv,
    hook requests and process metadata. Return exit status, argv, cmux calls,
    exported metadata and stderr so assertions can distinguish passthrough from
    an instrumented session. Real socket fixtures are created only when requested.
    """
    with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / ("wrapper bin" if profile_reorders_path or inherited_path_reorders_path else "wrapper-bin")
        real_dir = tmp / "real-bin"
        bundled_dir = tmp / "bundled cli"
        wrapper_dir.mkdir()
        real_dir.mkdir()
        bundled_dir.mkdir()

        wrapper = wrapper_dir / "cmux-codex-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)
        shim = wrapper_dir / "codex"
        if not sibling_shim_available:
            # A bundled wrapper has no adjacent codex entrypoint; the managed
            # shim lives separately, as it does in a real cmux terminal.
            shim = tmp / "cmux-cli-shims" / "surface with spaces" / "codex"
            shim.parent.mkdir(parents=True)
        shim.symlink_to(wrapper)
        launcher_script = tmp / "launcher with spaces"
        make_executable(launcher_script, '#!/bin/sh\nexec codex "$@"\n')

        real_args_log = tmp / "real-args.log"
        real_env_log = tmp / "real-env.log"
        cmux_log = tmp / "cmux.log"
        socket_path = tmp / "cmux.sock"

        make_executable(
            real_dir / "codex",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
for arg in "$@"; do
  printf '%s\\0' "$arg" >> "$FAKE_REAL_ARGS_LOG"
done
{
  printf 'CMUX_CODEX_PID=%s\\n' "${CMUX_CODEX_PID-__UNSET__}"
  printf 'CMUX_CODEX_HOOK_CMUX_BIN=%s\\n' "${CMUX_CODEX_HOOK_CMUX_BIN-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_KIND=%s\\n' "${CMUX_AGENT_LAUNCH_KIND-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_EXECUTABLE=%s\\n' "${CMUX_AGENT_LAUNCH_EXECUTABLE-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_ARGV_B64=%s\\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-__UNSET__}"
  printf 'CMUX_AGENT_RESUME_LAUNCH=%s\\n' "${CMUX_AGENT_RESUME_LAUNCH-__UNSET__}"
  printf 'CMUX_AGENT_RESTORE_LAUNCH=%s\\n' "${CMUX_AGENT_RESTORE_LAUNCH-__UNSET__}"
  printf 'CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND=%s\\n' "${CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND-__UNSET__}"
  printf 'CMUX_WORKSPACE_ID=%s\\n' "${CMUX_WORKSPACE_ID-__UNSET__}"
  printf 'CMUX_SURFACE_ID=%s\\n' "${CMUX_SURFACE_ID-__UNSET__}"
  printf 'CMUX_CODEX_HEADLESS=%s\\n' "${CMUX_CODEX_HEADLESS-__UNSET__}"
  printf 'FAKE_PROVIDER=%s\\n' "${FAKE_PROVIDER-__UNSET__}"
  printf 'CMUX_CODEX_LAUNCH_COMMAND_ACTIVE=%s\\n' "${CMUX_CODEX_LAUNCH_COMMAND_ACTIVE-__UNSET__}"
  printf 'REAL_PID=%s\\n' "$$"
} > "$FAKE_REAL_ENV_LOG"
if [[ "${FAKE_NESTED_ONCE:-0}" == "1" ]]; then
  FAKE_NESTED_ONCE=0 "$FAKE_WRAPPER" exec nested-prompt
fi
""",
        )

        bundled_cli = bundled_dir / "cmux"
        make_executable(
            bundled_cli,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_CMUX_LOG"
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  [[ "${FAKE_SOCKET_STATE:-missing}" == "live" ]]
  exit
fi
if [[ "${1:-}" == "hooks" && "${2:-}" == "codex" && "${3:-}" == "inject-args" ]]; then
  [[ "${FAKE_INJECT_ARGS_AVAILABLE:-1}" == "1" ]] || exit 1
  printf '%s\\0' \
    '--enable' \
    'hooks' \
    '--dangerously-bypass-hook-trust' \
    '-c' \
    'hooks.SessionStart=[{hooks=[{type="command",command="fake-session-start",timeout=10000}]}]' \
    '-c' \
    'hooks.Stop=[{hooks=[{type="command",command="fake-stop",timeout=10000}]}]'
  exit 0
fi
if [[ "${1:-}" == "hooks" && "${2:-}" == "codex" && "${3:-}" == "session-start" ]]; then
  cat >/dev/null
  exit 0
fi
exit 1
""",
        )

        test_socket: socket.socket | None = None
        if socket_state in {"live", "stale"}:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(str(socket_path))

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:/usr/bin:/bin"
        if inherited_path_reorders_path:
            # Restore launches the managed shim by its absolute path after
            # the pane's shell has already put native Codex first in PATH.
            env["PATH"] = f"{real_dir}:{wrapper_dir}:/usr/bin:/bin"
        env["HOME"] = str(tmp / "home")
        home = Path(env["HOME"])
        home.mkdir()
        env["CFFIXED_USER_HOME"] = str(home)
        env["ZDOTDIR"] = str(home)
        env["SHELL"] = "/bin/zsh"
        env["FAKE_TEST_PATH"] = env["PATH"]
        if profile_reorders_path:
            # Homebrew shellenv and macOS path_helper can put the real binary
            # ahead of cmux's shim while an interactive login shell starts.
            env["FAKE_TEST_PATH"] = f"{real_dir}:{wrapper_dir}:/usr/bin:/bin"
        env.pop("CMUX_CODEX_WRAPPER_SHIM_ROOT", None)
        if not sibling_shim_available:
            env["CMUX_CODEX_WRAPPER_SHIM_ROOT"] = str(shim.parent)
            env["PATH"] += f":{shim.parent}"
            env["FAKE_TEST_PATH"] = env["PATH"]
        if managed_shim_available:
            env["CMUX_CODEX_WRAPPER_SHIM"] = str(shim)
        else:
            env.pop("CMUX_CODEX_WRAPPER_SHIM", None)
        if inherited_other_agent:
            env["CMUX_AGENT_LAUNCH_KIND"] = "claude"
            env["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/inherited/claude"
            env["CMUX_AGENT_LAUNCH_ARGV_B64"] = "aW5oZXJpdGVkAA=="
        env["FAKE_LAUNCHER_CALLS"] = str(tmp / "launcher-calls")
        env["FAKE_WRAPPER"] = str(wrapper)
        env["FAKE_NESTED_ONCE"] = "1" if nested_launch else "0"
        (home / ".zshrc").write_text(
            'export PATH="$FAKE_TEST_PATH"\n'
            'subcodex() {\n'
            '  printf "called\\n" >> "$FAKE_LAUNCHER_CALLS"\n'
            '  export FAKE_PROVIDER=custom\n'
            + ('  command codex --no-daemon --version >/dev/null || return\n' if launcher_preflight else '')
            +
            '  codex "$@"\n'
            '}\n', encoding="utf-8",
        )
        env.pop("CMUX_CODEX_LAUNCH_COMMAND_ACTIVE", None)
        if launch_command is None:
            env.pop("CMUX_CODEX_LAUNCH_COMMAND", None)
        else:
            env["CMUX_CODEX_LAUNCH_COMMAND"] = {
                "__script__": str(launcher_script),
                "__shim__": str(shim),
            }.get(launch_command, launch_command)
        env["CMUX_SURFACE_ID"] = "11111111-1111-1111-1111-111111111111"
        env["CMUX_WORKSPACE_ID"] = "22222222-2222-2222-2222-222222222222"
        if not in_cmux:
            env.pop("CMUX_SURFACE_ID", None)
            env.pop("CMUX_WORKSPACE_ID", None)
        env["CMUX_SOCKET_PATH"] = str(socket_path)
        env["CMUX_BUNDLED_CLI_PATH"] = str(bundled_cli)
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_REAL_ENV_LOG"] = str(real_env_log)
        env["FAKE_CMUX_LOG"] = str(cmux_log)
        env["FAKE_SOCKET_STATE"] = socket_state
        env["FAKE_INJECT_ARGS_AVAILABLE"] = "1" if inject_args_available else "0"
        # Keep this hook-only fixture independent of any ambient cmux CUA
        # installation on the developer or CI machine.
        env["CMUX_COMPUTER_USE_APP_ENABLED"] = "0"
        env["CMUX_COMPUTER_USE_MCP_DISABLED"] = "1"
        if hooks_disabled:
            env["CMUX_CODEX_HOOKS_DISABLED"] = "1"
        else:
            env.pop("CMUX_CODEX_HOOKS_DISABLED", None)
        if restore_token is not None:
            env["CMUX_AGENT_RESTORE_LAUNCH"] = restore_token
        else:
            env.pop("CMUX_AGENT_RESTORE_LAUNCH", None)
        if subrouter_marker is not None:
            env["SUBROUTER_CODEX_RESUME_COMMAND"] = subrouter_marker
            env["CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND"] = "inherited ancestor marker"
        else:
            env.pop("SUBROUTER_CODEX_RESUME_COMMAND", None)
            env.pop("CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND", None)

        try:
            proc = subprocess.run(
                [str(shim if sibling_shim_available else wrapper), *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
                timeout=15,
            )
        finally:
            if test_socket is not None:
                test_socket.close()

        observed_env = dict(line.split("=", 1) for line in read_lines(real_env_log))
        observed_env["launcher_calls"] = str(len(read_lines(tmp / "launcher-calls")))
        real_args = real_args_log.read_bytes().split(b"\0")[:-1] if real_args_log.exists() else []
        return proc.returncode, [arg.decode("utf-8") for arg in real_args], read_lines(cmux_log), observed_env, proc.stderr.strip()


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def test_custom_launch_command(failures: list[str]) -> None:
    """Check custom-launcher selection, literal argv forwarding and one inner hook owner.

    Includes executable paths, disabled hooks, nested launches, preflight commands
    and error propagation without silently substituting the ordinary launcher.
    """
    for argv in (
        ["resume", SESSION_ID, "-a", "never", "-s", "workspace-write"],
        ["resume", SESSION_ID, "literal $(printf injected); 'quoted'"],
        ["--version"], [],
    ):
        code, actual, calls, env, stderr = run_wrapper(
            socket_state="stale", argv=argv, launch_command="subcodex",
        )
        label = f"custom-command/{argv}"
        expect(code == 0, f"{label}: exit {code}: {stderr}", failures)
        expect(env.get("FAKE_PROVIDER") == "custom", f"{label}: shell function was bypassed", failures)
        expect(env.get("launcher_calls") == "1", f"{label}: launcher must run exactly once", failures)
        expect(env.get("CMUX_CODEX_LAUNCH_COMMAND_ACTIVE") == "__UNSET__",
               f"{label}: re-entry guard leaked into Codex", failures)
        if argv == ["--version"]:
            expect(actual == argv, f"{label}: non-session args changed: {actual}", failures)
            expect(not calls, f"{label}: hooks injected into --version", failures)
        else:
            expect(env.get("REAL_PID") == env.get("CMUX_CODEX_PID"),
                   f"{label}: claimed PID is not the real Codex PID", failures)
            expect(sum(a.startswith("hooks.SessionStart=") for a in actual) == 1,
                   f"{label}: SessionStart must be injected exactly once: {actual}", failures)
            expect(env.get("CMUX_SURFACE_ID") == "11111111-1111-1111-1111-111111111111",
                   f"{label}: surface tracking was lost", failures)
            if argv:
                expect(all(a in actual for a in argv), f"{label}: resume ID/options lost: {actual}", failures)

    for command in ("", "  \n  "):
        code, actual, _, env, _ = run_wrapper(socket_state="stale", argv=["--version"], launch_command=command)
        expect(code == 0 and actual == ["--version"] and env.get("launcher_calls") == "0",
               "empty custom command must preserve the default launcher", failures)

    code, actual, _, _, _ = run_wrapper(socket_state="stale", argv=["--version"], launch_command="false")
    expect(code != 0 and not actual, "a failed custom command must not fall back to ordinary Codex", failures)

    for command in ("__script__", "__shim__"):
        code, actual, calls, env, stderr = run_wrapper(
            socket_state="stale", argv=["resume", SESSION_ID], launch_command=command,
        )
        expect(code == 0 and env.get("REAL_PID") == env.get("CMUX_CODEX_PID"),
               f"{command}: executable handoff must retain the actual Codex PID: {stderr}", failures)
        expect(SESSION_ID in actual and sum(a.startswith("hooks.SessionStart=") for a in actual) == 1,
               f"{command}: executable launcher must not recurse or duplicate hooks: {actual}", failures)
        expect(sum("hooks codex inject-args" in call for call in calls) == 1,
               f"{command}: injection must run exactly once", failures)

    code, actual, calls, env, _ = run_wrapper(
        socket_state="stale", argv=["resume", SESSION_ID], launch_command="subcodex", hooks_disabled=True,
    )
    expect(code == 0 and actual == ["resume", SESSION_ID] and not calls and env.get("FAKE_PROVIDER") == "custom",
           "disabling hooks must preserve the chosen launcher without injecting hooks", failures)

    code, actual, calls, env, _ = run_wrapper(
        socket_state="stale", argv=["--version"], launch_command="subcodex", in_cmux=False,
    )
    expect(code == 0 and actual == ["--version"] and not calls and env.get("launcher_calls") == "0",
           "outside cmux the launcher override must not apply", failures)

    code, actual, calls, env, stderr = run_wrapper(
        socket_state="stale", argv=["resume", SESSION_ID], launch_command="subcodex",
        nested_launch=True,
    )
    expect(code == 0 and env.get("launcher_calls") == "2",
           f"nested Codex must use the configured launcher again: {stderr}", failures)
    expect(env.get("REAL_PID") == env.get("CMUX_CODEX_PID") and env.get("CMUX_CODEX_HEADLESS") == "1",
           "nested Codex must establish its own real PID and headless identity", failures)
    expect(actual[-2:] == ["exec", "nested-prompt"] and sum(a.startswith("hooks.SessionStart=") for a in actual) == 1,
           f"nested Codex must retain exactly one hook set: {actual}", failures)
    expect(sum("hooks codex inject-args" in call for call in calls) == 2,
           "outer and nested Codex must each request hooks once", failures)

    code, actual, calls, env, stderr = run_wrapper(
        socket_state="stale", argv=["resume", SESSION_ID, "--no-daemon"], launch_command="subcodex",
        launcher_preflight=True,
    )
    expect(code == 0 and env.get("REAL_PID") == env.get("CMUX_CODEX_PID") and env.get("launcher_calls") == "1",
           f"a launcher version preflight must not consume the resume handoff: {stderr}", failures)
    expect(SESSION_ID in actual and "--no-daemon" in actual and sum("hooks codex inject-args" in call for call in calls) == 1,
           "version preflight must preserve resume arguments and one injection", failures)


def test_custom_launcher_profile_reorders_path(failures: list[str]) -> None:
    """Keep real PID registration and one hook set after login profiles reorder PATH."""
    for argv in ([], ["resume", SESSION_ID, "-a", "never", "-s", "workspace-write"]):
        code, actual, calls, env, stderr = run_wrapper(
            socket_state="stale", argv=argv, launch_command="subcodex",
            launcher_preflight=True, profile_reorders_path=True,
        )
        expect(code == 0 and env.get("FAKE_PROVIDER") == "custom",
               f"login profile must retain custom launcher: {stderr}", failures)
        expect(env.get("REAL_PID") == env.get("CMUX_CODEX_PID"),
               "profile PATH reorder bypassed Codex PID registration", failures)
        expect(sum(a.startswith("hooks.SessionStart=") for a in actual) == 1,
               "profile PATH reorder lost session hooks", failures)
        expect(sum("hooks codex inject-args" in call for call in calls) == 1,
               "profile PATH reorder must inject hooks exactly once", failures)
        expect(env.get("CMUX_CODEX_LAUNCH_COMMAND_ACTIVE") == "__UNSET__",
               "profile PATH reorder leaked the handoff guard", failures)
        if argv:
            expect(all(a in actual for a in argv), "profile PATH reorder lost saved resume arguments", failures)


def test_executable_launcher_inherited_path(failures: list[str]) -> None:
    """Exercise sibling and separate managed shims with native-first inherited PATH.

    The launcher must retain literal resume arguments, consume its reentry guard,
    and replace inherited agent identity with the real Codex process metadata.
    """
    argv = ["resume", SESSION_ID, "-a", "never", "-s", "workspace-write",
            "", "two words", "literal $(false); 'quoted'", "line1\nline2"]
    for managed_shim, reordered_path, sibling_shim in (
        (True, True, True), (False, False, True), (False, True, True), (False, True, False)
    ):
        label = f"executable-launcher/managed-shim={managed_shim}/reordered-path={reordered_path}/sibling={sibling_shim}"
        code, actual, calls, env, stderr = run_wrapper(
            socket_state="missing", argv=argv, launch_command="__script__",
            inherited_path_reorders_path=reordered_path,
            managed_shim_available=managed_shim, inherited_other_agent=True,
            sibling_shim_available=sibling_shim,
        )
        expect(code == 0, f"{label}: exit {code}: {stderr}", failures)
        expect(actual[-len(argv):] == argv,
               f"{label}: literal resume arguments changed: {actual}", failures)
        expect(env.get("REAL_PID") == env.get("CMUX_CODEX_PID"),
               f"{label}: executable handoff bypassed Codex PID registration", failures)
        for event in ("SessionStart", "Stop"):
            expect(sum(a.startswith(f"hooks.{event}=") for a in actual) == 1,
                   f"{label}: executable handoff must inject {event} exactly once", failures)
        expect(sum("hooks codex inject-args" in call for call in calls) == 1,
               f"{label}: executable handoff must request hooks exactly once", failures)
        expect(env.get("CMUX_CODEX_LAUNCH_COMMAND_ACTIVE") == "__UNSET__",
               f"{label}: executable handoff leaked the active marker", failures)
        expect(env.get("CMUX_AGENT_LAUNCH_KIND") == "codex"
               and env.get("CMUX_AGENT_LAUNCH_EXECUTABLE", "").endswith("/real-bin/codex")
               and env.get("CMUX_AGENT_LAUNCH_ARGV_B64") != "aW5oZXJpdGVkAA==",
               f"{label}: executable handoff retained another agent's launch identity", failures)


# cmux-launched Codex always disables the native `computer_use` provider before
# any other argument (Resources/bin/cmux-codex-wrapper), including when hook
# injection fails, so cmux-cua stays the only Computer Use provider.
NATIVE_COMPUTER_USE_POLICY = ["--disable", "computer_use"]


def assert_session_entrypoint_is_instrumented(
    *,
    socket_state: str,
    argv: list[str],
    label: str,
    failures: list[str],
    restore_token: str | None = None,
    expect_synthetic_resume: bool = False,
) -> None:
    code, real_argv, cmux_log, observed_env, stderr = run_wrapper(
        socket_state=socket_state,
        argv=argv,
        restore_token=restore_token,
    )
    expect(code == 0, f"{label}: wrapper exited {code}: {stderr}", failures)
    expect(stderr == "", f"{label}: wrapper wrote unexpected stderr: {stderr!r}", failures)
    expect(real_argv[:len(NATIVE_COMPUTER_USE_POLICY)] == NATIVE_COMPUTER_USE_POLICY,
           f"{label}: missing native Computer Use policy prefix: {real_argv}", failures)
    hook_args = real_argv[len(NATIVE_COMPUTER_USE_POLICY):]
    expect(hook_args[:3] == ["--enable", "hooks", "--dangerously-bypass-hook-trust"],
           f"{label}: missing injected hook prefix: {real_argv}", failures)
    expect(any(arg.startswith("hooks.SessionStart=") for arg in real_argv),
           f"{label}: missing SessionStart hook: {real_argv}", failures)
    expect(any(arg.startswith("hooks.Stop=") for arg in real_argv),
           f"{label}: missing Stop hook: {real_argv}", failures)
    expect(real_argv[-len(argv):] == argv if argv else len(hook_args) == 7,
           f"{label}: original argv was not preserved: {real_argv}", failures)
    expect(any("hooks codex inject-args" in line for line in cmux_log),
           f"{label}: wrapper never requested local hook args: {cmux_log}", failures)
    expect(not any("ping" in line for line in cmux_log),
           f"{label}: transient socket health must not decide session instrumentation: {cmux_log}", failures)
    synthetic_resume = any("hooks enqueue codex session-start" in line for line in cmux_log)
    expect(synthetic_resume == expect_synthetic_resume,
           f"{label}: synthetic resume SessionStart mismatch: {cmux_log}", failures)
    expect(not any("hooks codex session-start" in line for line in cmux_log),
           f"{label}: wrapper must use the queued SessionStart path: {cmux_log}", failures)
    expect(observed_env.get("CMUX_CODEX_PID") not in {None, "", "__UNSET__"},
           f"{label}: missing Codex process identity: {observed_env}", failures)
    expect(observed_env.get("CMUX_AGENT_LAUNCH_KIND") == "codex",
           f"{label}: missing launch kind: {observed_env}", failures)
    expect(observed_env.get("CMUX_AGENT_RESUME_LAUNCH") == "__UNSET__",
           f"{label}: argv-derived resume marker leaked to Codex: {observed_env}", failures)
    expect(observed_env.get("CMUX_AGENT_RESTORE_LAUNCH") == "__UNSET__",
           f"{label}: app restore marker leaked to Codex: {observed_env}", failures)
    expect(observed_env.get("CMUX_WORKSPACE_ID") == "22222222-2222-2222-2222-222222222222",
           f"{label}: workspace binding was stripped: {observed_env}", failures)
    expect(observed_env.get("CMUX_SURFACE_ID") == "11111111-1111-1111-1111-111111111111",
           f"{label}: surface binding was stripped: {observed_env}", failures)


def test_every_resume_route_is_instrumented(failures: list[str]) -> None:
    entrypoints = (
        ("explicit-id", ["resume", SESSION_ID], f"codex:{SESSION_ID}"),
        ("last", ["resume", "--last"], f"codex:{SESSION_ID}"),
        ("picker", ["resume"], None),
        # An in-TUI resume inherits the hooks installed by the bare interactive
        # launch; the wrapper never sees the later picker action.
        ("in-tui", [], None),
    )
    for socket_state in ("missing", "stale", "live"):
        for route, argv, restore_token in entrypoints:
            assert_session_entrypoint_is_instrumented(
                socket_state=socket_state,
                argv=argv,
                label=f"{route}/{socket_state}",
                failures=failures,
                restore_token=restore_token,
                expect_synthetic_resume=route == "explicit-id",
            )


def test_direct_fork_is_instrumented(failures: list[str]) -> None:
    for socket_state in ("stale", "live"):
        assert_session_entrypoint_is_instrumented(
            socket_state=socket_state,
            argv=["fork", SESSION_ID],
            label=f"fork/{socket_state}",
            failures=failures,
            expect_synthetic_resume=False,
        )


def test_explicit_disable_still_bypasses_hooks(failures: list[str]) -> None:
    code, real_argv, cmux_log, _, stderr = run_wrapper(
        socket_state="stale",
        argv=["resume", SESSION_ID],
        hooks_disabled=True,
    )
    expect(code == 0, f"disabled: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["resume", SESSION_ID], f"disabled: expected passthrough, got {real_argv}", failures)
    expect(cmux_log == [], f"disabled: expected no cmux calls, got {cmux_log}", failures)


def test_stale_socket_fresh_launch_is_instrumented(failures: list[str]) -> None:
    assert_session_entrypoint_is_instrumented(
        socket_state="stale",
        argv=["hello"],
        label="fresh/stale",
        failures=failures,
    )


def test_restore_tokens_do_not_gate_instrumentation(failures: list[str]) -> None:
    for token in (
        f"claude:{SESSION_ID}",
        "codex:aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa",
        "1",
    ):
        assert_session_entrypoint_is_instrumented(
            socket_state="stale",
            argv=["resume", SESSION_ID],
            label=f"restore-token-{token}/stale",
            failures=failures,
            restore_token=token,
            expect_synthetic_resume=True,
        )


def test_injection_failure_preserves_cmux_context(failures: list[str]) -> None:
    code, real_argv, cmux_log, observed_env, stderr = run_wrapper(
        socket_state="missing",
        argv=["resume"],
        inject_args_available=False,
    )
    expect(code == 0, f"inject-failure: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == [*NATIVE_COMPUTER_USE_POLICY, "resume"],
           f"inject-failure: original argv changed: {real_argv}", failures)
    expect(any("hooks codex inject-args" in line for line in cmux_log),
           f"inject-failure: injection was never attempted: {cmux_log}", failures)
    expect(observed_env.get("CMUX_SURFACE_ID") == "11111111-1111-1111-1111-111111111111",
           f"inject-failure: surface binding was stripped: {observed_env}", failures)
    expect(observed_env.get("CMUX_WORKSPACE_ID") == "22222222-2222-2222-2222-222222222222",
           f"inject-failure: workspace binding was stripped: {observed_env}", failures)
    expect(observed_env.get("CMUX_CODEX_PID") not in {None, "", "__UNSET__"},
           f"inject-failure: missing Codex process identity: {observed_env}", failures)
    expect(observed_env.get("CMUX_AGENT_LAUNCH_KIND") == "codex",
           f"inject-failure: missing launch kind: {observed_env}", failures)


def test_non_session_command_still_bypasses_hooks(failures: list[str]) -> None:
    code, real_argv, cmux_log, _, stderr = run_wrapper(
        socket_state="stale",
        argv=["--help"],
    )
    expect(code == 0, f"help: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["--help"], f"help: expected passthrough, got {real_argv}", failures)
    expect(cmux_log == [], f"help: expected no cmux calls, got {cmux_log}", failures)


def test_subrouter_marker_is_bound_to_current_launch_argv(failures: list[str]) -> None:
    marker = "sr codex resume"
    _, _, _, routed_env, _ = run_wrapper(
        socket_state="stale",
        argv=["fix this", "-c", 'model_provider="subrouter"'],
        subrouter_marker=marker,
    )
    expect(
        routed_env.get("CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND") == marker,
        f"routed launch did not bind its marker: {routed_env}",
        failures,
    )

    _, _, _, direct_env, _ = run_wrapper(
        socket_state="stale",
        argv=["fix this"],
        subrouter_marker=marker,
    )
    expect(
        direct_env.get("CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND") == "__UNSET__",
        f"direct nested launch retained an inherited marker: {direct_env}",
        failures,
    )


def test_headless_marker_follows_the_subcommand(failures: list[str]) -> None:
    # The agent message hooks skip headless runs, so an exec run in the same
    # pane never takes messages meant for the interactive session.
    cases = [
        (["exec", "hi"], "1"),
        (["e", "hi"], "1"),
        (["-m", "gpt", "exec", "hi"], "1"),
        (["--add-dir", "../lib", "exec", "hi"], "1"),
        (["--local-provider", "ollama", "exec", "hi"], "1"),
        (["--remote-auth-token-env", "TOKEN", "exec", "hi"], "1"),
        (["-i", "shot.png", "exec", "hi"], "1"),
        (["--image", "shot.png", "exec", "hi"], "1"),
        (["fix this"], "0"),
        (["--add-dir", "exec", "fix this"], "0"),
        (["--", "exec"], "0"),
    ]
    for argv, expected in cases:
        _, _, _, observed_env, stderr = run_wrapper(socket_state="stale", argv=argv)
        expect(
            observed_env.get("CMUX_CODEX_HEADLESS") == expected,
            f"headless {argv}: expected {expected}, got {observed_env.get('CMUX_CODEX_HEADLESS')} ({stderr})",
            failures,
        )


def main() -> int:
    """Run wrapper behavior regressions and return nonzero when any collected assertion fails."""
    failures: list[str] = []
    test_custom_launch_command(failures)
    test_custom_launcher_profile_reorders_path(failures)
    test_executable_launcher_inherited_path(failures)
    test_every_resume_route_is_instrumented(failures)
    test_direct_fork_is_instrumented(failures)
    test_explicit_disable_still_bypasses_hooks(failures)
    test_stale_socket_fresh_launch_is_instrumented(failures)
    test_restore_tokens_do_not_gate_instrumentation(failures)
    test_injection_failure_preserves_cmux_context(failures)
    test_non_session_command_still_bypasses_hooks(failures)
    test_subrouter_marker_is_bound_to_current_launch_argv(failures)
    test_headless_marker_follows_the_subcommand(failures)
    if failures:
        print("FAIL: Codex session-entrypoint wrapper reliability checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: every cmux-owned Codex session entrypoint retains SessionStart and Stop hooks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
