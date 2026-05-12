#!/usr/bin/env python3
"""
Regression tests for Resources/bin/claude wrapper hook injection.
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "claude"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def parse_settings_arg(argv: list[str]) -> dict:
    if "--settings" not in argv:
        return {}
    index = argv.index("--settings")
    if index + 1 >= len(argv):
        return {}
    return json.loads(argv[index + 1])


def run_wrapper(
    *,
    socket_state: str,
    argv: list[str],
    node_options: str | None = None,
    tmpdir: str | None = None,
    hooks_disabled: bool = False,
) -> tuple[int, list[str], list[str], str, str, str, str, str, str, str]:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        bundled_dir = tmp / "bundled cli"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)
        bundled_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "claude"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        real_claudecode_log = tmp / "real-claudecode.log"
        real_node_options_log = tmp / "real-node-options.log"
        real_runtime_node_options_log = tmp / "real-runtime-node-options.log"
        real_child_node_options_log = tmp / "real-child-node-options.log"
        real_launch_argv_b64_log = tmp / "real-launch-argv-b64.log"
        hook_cmux_bin_log = tmp / "hook-cmux-bin.log"
        cmux_log = tmp / "cmux.log"
        socket_path = str(tmp / "cmux.sock")

        make_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
printf '%s\\n' "${CLAUDECODE-__UNSET__}" > "$FAKE_REAL_CLAUDECODE_LOG"
printf '%s\\n' "${NODE_OPTIONS-__UNSET__}" > "$FAKE_REAL_NODE_OPTIONS_LOG"
printf '%s\\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-__UNSET__}" > "$FAKE_REAL_LAUNCH_ARGV_B64_LOG"
printf '%s\\n' "${CMUX_CLAUDE_HOOK_CMUX_BIN-__UNSET__}" > "$FAKE_HOOK_CMUX_BIN_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"
done
exec node "$FAKE_REAL_NODE_SCRIPT" "$@"
""",
        )

        make_executable(
            real_dir / "claude-real.js",
            """#!/usr/bin/env node
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");

fs.writeFileSync(
  process.env.FAKE_REAL_RUNTIME_NODE_OPTIONS_LOG,
  `${process.env.NODE_OPTIONS ?? "__UNSET__"}\\n`,
  "utf8",
);

const child = spawnSync(
  process.execPath,
  ["-e", "process.stdout.write(process.env.NODE_OPTIONS ?? '__UNSET__')"],
  { encoding: "utf8" },
);
if (child.error) {
  console.error(child.error.message);
  process.exit(1);
}
if ((child.status ?? 0) !== 0) {
  process.stderr.write(child.stderr ?? "");
  process.exit(child.status ?? 1);
}

fs.writeFileSync(
  process.env.FAKE_REAL_CHILD_NODE_OPTIONS_LOG,
  `${child.stdout ?? ""}\\n`,
  "utf8",
);
""",
        )

        make_executable(
            wrapper_dir / "cmux",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s timeout=%s\\n' "$*" "${CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC-__UNSET__}" >> "$FAKE_CMUX_LOG"
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  if [[ "${FAKE_CMUX_PING_OK:-0}" == "1" ]]; then
    exit 0
  fi
  exit 1
fi
exit 0
""",
        )
        bundled_cli_path = bundled_dir / "cmux"
        make_executable(
            bundled_cli_path,
            """#!/usr/bin/env bash
exit 0
""",
        )

        test_socket: socket.socket | None = None
        if socket_state in {"live", "stale"}:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test_socket.bind(socket_path)

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
        env["CMUX_SURFACE_ID"] = "surface:test"
        env["CMUX_SOCKET_PATH"] = socket_path
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_REAL_CLAUDECODE_LOG"] = str(real_claudecode_log)
        env["FAKE_REAL_NODE_OPTIONS_LOG"] = str(real_node_options_log)
        env["FAKE_REAL_RUNTIME_NODE_OPTIONS_LOG"] = str(real_runtime_node_options_log)
        env["FAKE_REAL_CHILD_NODE_OPTIONS_LOG"] = str(real_child_node_options_log)
        env["FAKE_REAL_LAUNCH_ARGV_B64_LOG"] = str(real_launch_argv_b64_log)
        env["FAKE_REAL_NODE_SCRIPT"] = str(real_dir / "claude-real.js")
        env["FAKE_HOOK_CMUX_BIN_LOG"] = str(hook_cmux_bin_log)
        env["FAKE_CMUX_LOG"] = str(cmux_log)
        env["FAKE_CMUX_PING_OK"] = "1" if socket_state == "live" else "0"
        env["CMUX_BUNDLED_CLI_PATH"] = str(bundled_cli_path)
        env["CLAUDECODE"] = "nested-session-sentinel"
        if hooks_disabled:
            env["CMUX_CLAUDE_HOOKS_DISABLED"] = "1"
        else:
            env.pop("CMUX_CLAUDE_HOOKS_DISABLED", None)
        env.pop("NODE_OPTIONS", None)
        if tmpdir is not None:
            env["TMPDIR"] = tmpdir
        if node_options is not None:
            env["NODE_OPTIONS"] = node_options

        try:
            proc = subprocess.run(
                ["claude", *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            if test_socket is not None:
                test_socket.close()

        claudecode_lines = read_lines(real_claudecode_log)
        hook_cmux_bin_lines = read_lines(hook_cmux_bin_log)
        launch_argv_b64_lines = read_lines(real_launch_argv_b64_log)
        claudecode_value = claudecode_lines[0] if claudecode_lines else ""
        node_options_lines = read_lines(real_node_options_log)
        node_options_value = node_options_lines[0] if node_options_lines else ""
        runtime_node_options_lines = read_lines(real_runtime_node_options_log)
        runtime_node_options_value = runtime_node_options_lines[0] if runtime_node_options_lines else ""
        child_node_options_lines = read_lines(real_child_node_options_log)
        child_node_options_value = child_node_options_lines[0] if child_node_options_lines else ""
        hook_cmux_bin_value = hook_cmux_bin_lines[0] if hook_cmux_bin_lines else ""
        launch_argv_b64_value = launch_argv_b64_lines[0] if launch_argv_b64_lines else ""
        return (
            proc.returncode,
            read_lines(real_args_log),
            read_lines(cmux_log),
            proc.stderr.strip(),
            claudecode_value,
            node_options_value,
            runtime_node_options_value,
            child_node_options_value,
            hook_cmux_bin_value,
            launch_argv_b64_value,
        )


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def decode_nul_argv(encoded: str) -> list[str]:
    raw = base64.b64decode(encoded)
    parts = raw.split(b"\0")
    if parts and parts[-1] == b"":
        parts = parts[:-1]
    return [part.decode("utf-8") for part in parts]


def run_wrapper_auth_env(
    *,
    argv: list[str],
    inherited_env: dict[str, str],
    setup_env=None,
) -> tuple[int, dict[str, str], list[str], str]:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-auth-env-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "claude"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        auth_env_log = tmp / "auth-env.log"
        args_log = tmp / "args.log"
        socket_path = str(tmp / "cmux.sock")

        make_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_AUTH_ENV_LOG"
: > "$FAKE_ARGS_LOG"
keys=(
  ANTHROPIC_API_KEY
  ANTHROPIC_AUTH_TOKEN
  ANTHROPIC_BASE_URL
  ANTHROPIC_MODEL
  ANTHROPIC_SMALL_FAST_MODEL
  CLAUDE_CODE_USE_BEDROCK
  CLAUDE_CODE_USE_VERTEX
  CLAUDE_CONFIG_DIR
)
for key in "${keys[@]}"; do
  if [[ ${!key+x} ]]; then
    printf '%s=%s\\n' "$key" "${!key}" >> "$FAKE_AUTH_ENV_LOG"
  else
    printf '%s=__UNSET__\\n' "$key" >> "$FAKE_AUTH_ENV_LOG"
  fi
done
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_ARGS_LOG"
done
""",
        )

        make_executable(
            wrapper_dir / "cmux",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  exit 0
fi
exit 0
""",
        )

        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            test_socket.bind(socket_path)

            env = os.environ.copy()
            env.pop("CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV", None)
            env.pop("CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS", None)
            env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
            env["CMUX_SURFACE_ID"] = "surface:test"
            env["CMUX_SOCKET_PATH"] = socket_path
            env["FAKE_AUTH_ENV_LOG"] = str(auth_env_log)
            env["FAKE_ARGS_LOG"] = str(args_log)
            if setup_env is not None:
                env.update(setup_env(tmp))
            env.update(inherited_env)

            proc = subprocess.run(
                ["claude", *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            test_socket.close()

        auth_env = dict(line.split("=", 1) for line in read_lines(auth_env_log))
        return proc.returncode, auth_env, read_lines(args_log), proc.stderr.strip()


def test_live_socket_injects_supported_hooks_without_unlocking_bypass(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, claudecode, node_options, runtime_node_options, child_node_options, hook_cmux_bin, _ = run_wrapper(
        socket_state="live",
        argv=["hello"],
    )
    expect(code == 0, f"live socket: wrapper exited {code}: {stderr}", failures)
    expect("--settings" in real_argv, f"live socket: missing --settings in args: {real_argv}", failures)
    expect("--session-id" in real_argv, f"live socket: missing --session-id in args: {real_argv}", failures)
    for flag in ("--allow-dangerously-skip-permissions", "--dangerously-skip-permissions"):
        expect(
            flag not in real_argv,
            f"live socket: wrapper should not unlock bypass permissions via {flag}: {real_argv}",
            failures,
        )
    expect(real_argv[-1] == "hello", f"live socket: expected original arg to pass through, got {real_argv}", failures)
    expect(any(" ping" in line for line in cmux_log), f"live socket: expected cmux ping, got {cmux_log}", failures)
    expect(
        any("timeout=0.75" in line for line in cmux_log),
        f"live socket: expected bounded ping timeout, got {cmux_log}",
        failures,
    )
    expect(claudecode == "__UNSET__", f"live socket: expected CLAUDECODE unset, got {claudecode!r}", failures)
    require_flag, _, remaining_flags = node_options.partition(" ")
    expect(
        require_flag.startswith("--require="),
        f"live socket: expected NODE_OPTIONS restore preload, got {node_options!r}",
        failures,
    )
    expect(
        remaining_flags == "--max-old-space-size=4096",
        f"live socket: expected injected heap cap after preload, got {node_options!r}",
        failures,
    )
    expect(runtime_node_options == "__UNSET__", f"live socket: expected runtime NODE_OPTIONS restored, got {runtime_node_options!r}", failures)
    expect(child_node_options == "__UNSET__", f"live socket: expected child NODE_OPTIONS restored, got {child_node_options!r}", failures)
    expect(hook_cmux_bin.endswith("/bundled cli/cmux"), f"live socket: expected bundled cmux pin, got {hook_cmux_bin!r}", failures)

    settings = parse_settings_arg(real_argv)
    expect(
        settings.get("preferredNotifChannel") == "notifications_disabled",
        f"expected Claude notifications disabled in generated settings, got {settings}",
        failures,
    )
    hooks = settings.get("hooks", {})
    expected_hooks = {"SessionStart", "Stop", "SessionEnd", "Notification", "UserPromptSubmit", "PreToolUse", "PermissionRequest"}
    expect(set(hooks.keys()) == expected_hooks, f"unexpected hook keys: {hooks.keys()}, expected {expected_hooks}", failures)
    for hook_name, expected_subcommand in {
        "SessionStart": "session-start",
        "Stop": "stop",
        "SessionEnd": "session-end",
        "Notification": "notification",
        "UserPromptSubmit": "prompt-submit",
        "PreToolUse": "pre-tool-use",
    }.items():
        hook_command = hooks.get(hook_name, [{}])[0].get("hooks", [{}])[0].get("command", "")
        expect(
            hook_command == f'"${{CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}}" hooks claude {expected_subcommand}',
            f"{hook_name} hook should pin bundled cmux, got {hook_command!r}",
            failures,
        )
    # PreToolUse should be async to avoid blocking tool execution
    pre_tool_use_hooks = hooks.get("PreToolUse", [{}])[0].get("hooks", [{}])
    expect(
        any(h.get("async") is True for h in pre_tool_use_hooks),
        f"PreToolUse hook should have async:true, got {pre_tool_use_hooks}",
        failures,
    )
    permission_request_hooks = hooks.get("PermissionRequest", [{}])[0].get("hooks", [{}])
    expect(
        any(h.get("command") == '"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks feed --source claude' for h in permission_request_hooks),
        f"PermissionRequest hook should call hooks feed, got {permission_request_hooks}",
        failures,
    )
    # SessionEnd should have a short timeout (session is exiting)
    session_end_hooks = hooks.get("SessionEnd", [{}])[0].get("hooks", [{}])
    expect(
        any(h.get("timeout", 999) <= 2 for h in session_end_hooks),
        f"SessionEnd hook should have short timeout, got {session_end_hooks}",
        failures,
    )


def test_plain_claude_launch_argv_has_no_empty_argument(failures: list[str]) -> None:
    code, _, _, stderr, _, _, _, _, _, launch_argv_b64 = run_wrapper(
        socket_state="live",
        argv=[],
    )
    expect(code == 0, f"plain claude: wrapper exited {code}: {stderr}", failures)
    argv = decode_nul_argv(launch_argv_b64)
    expect(len(argv) == 1, f"plain claude: expected only executable in encoded launch argv, got {argv}", failures)
    expect(argv[0].endswith("/real-bin/claude"), f"plain claude: expected real claude executable, got {argv}", failures)


def test_live_socket_preserves_third_party_claude_auth_for_fresh_launch(failures: list[str]) -> None:
    inherited = {
        "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
        "ANTHROPIC_API_KEY": "stale-api-key",
        "ANTHROPIC_AUTH_TOKEN": "third-party-auth-token",
        "ANTHROPIC_BASE_URL": "https://api.example.test",
        "ANTHROPIC_MODEL": "stale-model",
        "ANTHROPIC_SMALL_FAST_MODEL": "stale-small-model",
        "CLAUDE_CODE_USE_BEDROCK": "1",
        "CLAUDE_CODE_USE_VERTEX": "1",
    }
    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["hello"],
        inherited_env=inherited,
    )
    expect(code == 0, f"fresh auth env: wrapper exited {code}: {stderr}", failures)
    expect(auth_env.get("CLAUDE_CONFIG_DIR") == "/tmp/claude-config", f"fresh auth env: expected CLAUDE_CONFIG_DIR preserved, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}", failures)
    expect(auth_env.get("ANTHROPIC_AUTH_TOKEN") == "third-party-auth-token", f"fresh auth env: expected ANTHROPIC_AUTH_TOKEN preserved, got {auth_env.get('ANTHROPIC_AUTH_TOKEN')!r}", failures)
    expect(auth_env.get("ANTHROPIC_BASE_URL") == "https://api.example.test", f"fresh auth env: expected ANTHROPIC_BASE_URL preserved, got {auth_env.get('ANTHROPIC_BASE_URL')!r}", failures)
    for key in [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
    ]:
        expect(auth_env.get(key) == "__UNSET__", f"fresh auth env: expected {key} unset, got {auth_env.get(key)!r}", failures)
    expect("--session-id" in real_argv, f"fresh auth env: expected session injection, got {real_argv}", failures)


def test_live_socket_normalizes_subrouter_claude_config_dir(failures: list[str]) -> None:
    expected: dict[str, str] = {}

    def setup(tmp: Path) -> dict[str, str]:
        home = tmp / "home"
        legacy = home / ".subrouter" / "codex" / "claude" / "_p1775010019397"
        legacy.mkdir(parents=True)
        (home / ".codex-accounts").symlink_to(home / ".subrouter" / "codex", target_is_directory=True)
        expected["path"] = str(home / ".codex-accounts" / "claude" / "_p1775010019397")
        return {"HOME": str(home)}

    code, auth_env, _, stderr = run_wrapper_auth_env(
        argv=["--dangerously-skip-permissions"],
        inherited_env={},
        setup_env=lambda tmp: {
            **setup(tmp),
            "CLAUDE_CONFIG_DIR": str(tmp / "home" / ".subrouter" / "codex" / "claude" / "_p1775010019397"),
        },
    )
    expect(code == 0, f"normalize config dir: wrapper exited {code}: {stderr}", failures)
    expect(auth_env.get("CLAUDE_CONFIG_DIR") == expected["path"], f"normalize config dir: expected {expected['path']!r}, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}", failures)


def test_live_socket_preserves_claude_auth_for_resume_launch(failures: list[str]) -> None:
    expected_auth_env = {
        "CLAUDE_CONFIG_DIR": "/tmp/resume-claude-config",
        "ANTHROPIC_MODEL": "resume-model",
    }
    inherited = {
        **expected_auth_env,
        "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV": "1",
        "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS": "CLAUDE_CONFIG_DIR,ANTHROPIC_MODEL",
    }
    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["--resume", "claude-session-123"],
        inherited_env=inherited,
    )
    expect(code == 0, f"resume auth env: wrapper exited {code}: {stderr}", failures)
    for key, value in expected_auth_env.items():
        expect(auth_env.get(key) == value, f"resume auth env: expected {key}={value!r}, got {auth_env.get(key)!r}", failures)
    expect("--session-id" not in real_argv, f"resume auth env: expected no injected session id, got {real_argv}", failures)


def test_live_socket_preserves_only_listed_claude_auth_keys(failures: list[str]) -> None:
    inherited = {
        "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
        "ANTHROPIC_API_KEY": "stale-api-key",
        "ANTHROPIC_MODEL": "resume-model",
        "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV": "1",
        "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS": "ANTHROPIC_MODEL",
    }
    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["--resume", "claude-session-123"],
        inherited_env=inherited,
    )
    expect(code == 0, f"listed auth env: wrapper exited {code}: {stderr}", failures)
    expect(auth_env.get("ANTHROPIC_MODEL") == "resume-model", f"listed auth env: expected model preserved, got {auth_env.get('ANTHROPIC_MODEL')!r}", failures)
    expect(auth_env.get("CLAUDE_CONFIG_DIR") == "/tmp/claude-config", f"listed auth env: expected CLAUDE_CONFIG_DIR preserved, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}", failures)
    expect(auth_env.get("ANTHROPIC_API_KEY") == "__UNSET__", f"listed auth env: expected unlisted ANTHROPIC_API_KEY unset, got {auth_env.get('ANTHROPIC_API_KEY')!r}", failures)
    expect("--session-id" not in real_argv, f"listed auth env: expected no injected session id, got {real_argv}", failures)


def test_live_socket_enforces_heap_cap_for_space_separated_flag(failures: list[str]) -> None:
    existing = "--max-old-space-size 2048 --trace-warnings"
    restored = "--max-old-space-size=2048 --trace-warnings"
    code, _, _, stderr, _, node_options, runtime_node_options, child_node_options, _, _ = run_wrapper(
        socket_state="live",
        argv=["hello"],
        node_options=existing,
    )
    expect(code == 0, f"space-separated heap flag: wrapper exited {code}: {stderr}", failures)
    require_flag, _, remaining_flags = node_options.partition(" ")
    expect(
        require_flag.startswith("--require="),
        f"space-separated heap flag: expected restore preload, got {node_options!r}",
        failures,
    )
    expect(
        remaining_flags == "--max-old-space-size=4096 --trace-warnings",
        "space-separated heap flag: expected wrapper to replace the existing max-old-space-size option after the preload, "
        f"got {node_options!r}",
        failures,
    )
    expect(runtime_node_options == restored, f"space-separated heap flag: expected runtime NODE_OPTIONS restored, got {runtime_node_options!r}", failures)
    expect(child_node_options == restored, f"space-separated heap flag: expected child NODE_OPTIONS restored, got {child_node_options!r}", failures)


def test_live_socket_tmpdir_failure_skips_node_options_injection(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-bad-tmp-") as td:
        bad_tmpdir = Path(td) / "not-a-directory"
        bad_tmpdir.write_text("occupied", encoding="utf-8")
        code, real_argv, cmux_log, stderr, claudecode, node_options, runtime_node_options, child_node_options, _, _ = run_wrapper(
            socket_state="live",
            argv=["hello"],
            tmpdir=str(bad_tmpdir),
        )
    expect(code == 0, f"tmpdir failure: wrapper exited {code}: {stderr}", failures)
    expect("--settings" in real_argv, f"tmpdir failure: missing --settings in args: {real_argv}", failures)
    expect("--session-id" in real_argv, f"tmpdir failure: missing --session-id in args: {real_argv}", failures)
    expect(any(" ping" in line for line in cmux_log), f"tmpdir failure: expected cmux ping, got {cmux_log}", failures)
    expect(claudecode == "__UNSET__", f"tmpdir failure: expected CLAUDECODE unset, got {claudecode!r}", failures)
    expect(node_options == "__UNSET__", f"tmpdir failure: expected NODE_OPTIONS injection to be skipped, got {node_options!r}", failures)
    expect(runtime_node_options == "__UNSET__", f"tmpdir failure: expected runtime NODE_OPTIONS passthrough, got {runtime_node_options!r}", failures)
    expect(child_node_options == "__UNSET__", f"tmpdir failure: expected child NODE_OPTIONS passthrough, got {child_node_options!r}", failures)


def test_live_socket_preserves_explicit_bypass_availability_flag(failures: list[str]) -> None:
    cases = [
        ("allow/plain", ["--allow-dangerously-skip-permissions", "hello"], True, "--allow-dangerously-skip-permissions"),
        ("allow/resume", ["--allow-dangerously-skip-permissions", "--resume", "some-session-id"], False, "--allow-dangerously-skip-permissions"),
        ("short/plain", ["--dangerously-skip-permissions", "hello"], True, "--dangerously-skip-permissions"),
        ("short/resume", ["--dangerously-skip-permissions", "--resume", "some-session-id"], False, "--dangerously-skip-permissions"),
    ]
    for label, argv, expects_session_id, expected_flag in cases:
        code, real_argv, _, stderr, _, _, _, _, _, _ = run_wrapper(
            socket_state="live",
            argv=argv,
        )
        expect(code == 0, f"explicit bypass flag ({label}): wrapper exited {code}: {stderr}", failures)
        count = real_argv.count(expected_flag)
        expect(count == 1, f"explicit bypass flag ({label}): expected one {expected_flag}, got {count} in {real_argv}", failures)
        if expects_session_id:
            expect("--session-id" in real_argv, f"explicit bypass flag ({label}): expected injected session id, got {real_argv}", failures)
        else:
            expect("--session-id" not in real_argv, f"explicit bypass flag ({label}): expected no injected session id, got {real_argv}", failures)


def test_live_socket_stale_mktemp_literal_does_not_warn(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-tmp-") as td:
        tmpdir = Path(td)
        guard_dir = tmpdir / "cmux-claude-node-options"
        guard_dir.mkdir(parents=True, exist_ok=True)
        (guard_dir / "restore-node-options.XXXXXX.cjs").write_text("stale", encoding="utf-8")
        code, _, _, stderr, _, node_options, runtime_node_options, child_node_options, _, _ = run_wrapper(
            socket_state="live",
            argv=["hello"],
            tmpdir=str(tmpdir),
        )
    expect(code == 0, f"stale mktemp literal: wrapper exited {code}: {stderr}", failures)
    expect("mktemp:" not in stderr, f"stale mktemp literal: unexpected mktemp warning: {stderr!r}", failures)
    require_flag, _, remaining_flags = node_options.partition(" ")
    expect(
        require_flag.startswith("--require="),
        f"stale mktemp literal: expected NODE_OPTIONS restore preload, got {node_options!r}",
        failures,
    )
    expect(
        remaining_flags == "--max-old-space-size=4096",
        f"stale mktemp literal: expected injected heap cap after preload, got {node_options!r}",
        failures,
    )
    expect(runtime_node_options == "__UNSET__", f"stale mktemp literal: expected runtime NODE_OPTIONS restored, got {runtime_node_options!r}", failures)
    expect(child_node_options == "__UNSET__", f"stale mktemp literal: expected child NODE_OPTIONS restored, got {child_node_options!r}", failures)


def test_missing_socket_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, claudecode, node_options, runtime_node_options, child_node_options, hook_cmux_bin, _ = run_wrapper(
        socket_state="missing",
        argv=["hello"],
    )
    expect(code == 0, f"missing socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["hello"], f"missing socket: expected passthrough args, got {real_argv}", failures)
    expect(cmux_log == [], f"missing socket: expected no cmux calls, got {cmux_log}", failures)
    expect(claudecode == "__UNSET__", f"missing socket: expected CLAUDECODE unset, got {claudecode!r}", failures)
    expect(node_options == "__UNSET__", f"missing socket: expected NODE_OPTIONS passthrough, got {node_options!r}", failures)
    expect(runtime_node_options == "__UNSET__", f"missing socket: expected runtime NODE_OPTIONS passthrough, got {runtime_node_options!r}", failures)
    expect(child_node_options == "__UNSET__", f"missing socket: expected child NODE_OPTIONS passthrough, got {child_node_options!r}", failures)
    expect(hook_cmux_bin == "__UNSET__", f"missing socket: expected hook cmux unset, got {hook_cmux_bin!r}", failures)


def test_disabled_integration_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, claudecode, node_options, runtime_node_options, child_node_options, hook_cmux_bin, _ = run_wrapper(
        socket_state="live",
        argv=["hello"],
        hooks_disabled=True,
    )
    expect(code == 0, f"disabled integration: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["hello"], f"disabled integration: expected passthrough args, got {real_argv}", failures)
    expect("--settings" not in real_argv, f"disabled integration: expected no --settings injection, got {real_argv}", failures)
    expect("notifications_disabled" not in " ".join(real_argv), f"disabled integration: expected no notification suppression, got {real_argv}", failures)
    expect(cmux_log == [], f"disabled integration: expected no cmux calls, got {cmux_log}", failures)
    expect(claudecode == "__UNSET__", f"disabled integration: expected CLAUDECODE unset, got {claudecode!r}", failures)
    expect(node_options == "__UNSET__", f"disabled integration: expected NODE_OPTIONS passthrough, got {node_options!r}", failures)
    expect(runtime_node_options == "__UNSET__", f"disabled integration: expected runtime NODE_OPTIONS passthrough, got {runtime_node_options!r}", failures)
    expect(child_node_options == "__UNSET__", f"disabled integration: expected child NODE_OPTIONS passthrough, got {child_node_options!r}", failures)
    expect(hook_cmux_bin == "__UNSET__", f"disabled integration: expected hook cmux unset, got {hook_cmux_bin!r}", failures)


def test_stale_socket_skips_hook_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, claudecode, node_options, runtime_node_options, child_node_options, hook_cmux_bin, _ = run_wrapper(
        socket_state="stale",
        argv=["hello"],
    )
    expect(code == 0, f"stale socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["hello"], f"stale socket: expected passthrough args, got {real_argv}", failures)
    expect(any(" ping" in line for line in cmux_log), f"stale socket: expected cmux ping probe, got {cmux_log}", failures)
    expect(
        any("timeout=0.75" in line for line in cmux_log),
        f"stale socket: expected bounded ping timeout, got {cmux_log}",
        failures,
    )
    expect(claudecode == "__UNSET__", f"stale socket: expected CLAUDECODE unset, got {claudecode!r}", failures)
    expect(node_options == "__UNSET__", f"stale socket: expected NODE_OPTIONS passthrough, got {node_options!r}", failures)
    expect(runtime_node_options == "__UNSET__", f"stale socket: expected runtime NODE_OPTIONS passthrough, got {runtime_node_options!r}", failures)
    expect(child_node_options == "__UNSET__", f"stale socket: expected child NODE_OPTIONS passthrough, got {child_node_options!r}", failures)
    expect(hook_cmux_bin == "__UNSET__", f"stale socket: expected hook cmux unset, got {hook_cmux_bin!r}", failures)


def main() -> int:
    failures: list[str] = []
    test_live_socket_injects_supported_hooks_without_unlocking_bypass(failures)
    test_plain_claude_launch_argv_has_no_empty_argument(failures)
    test_live_socket_preserves_third_party_claude_auth_for_fresh_launch(failures)
    test_live_socket_normalizes_subrouter_claude_config_dir(failures)
    test_live_socket_preserves_claude_auth_for_resume_launch(failures)
    test_live_socket_preserves_only_listed_claude_auth_keys(failures)
    test_live_socket_enforces_heap_cap_for_space_separated_flag(failures)
    test_live_socket_tmpdir_failure_skips_node_options_injection(failures)
    test_live_socket_preserves_explicit_bypass_availability_flag(failures)
    test_live_socket_stale_mktemp_literal_does_not_warn(failures)
    test_missing_socket_skips_hook_injection(failures)
    test_disabled_integration_skips_hook_injection(failures)
    test_stale_socket_skips_hook_injection(failures)

    if failures:
        print("FAIL: claude wrapper regression checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: claude wrapper restores child NODE_OPTIONS while injecting supported hooks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
