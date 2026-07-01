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
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"


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

        wrapper = wrapper_dir / "cmux-claude-wrapper"
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
if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: claude [options] [command] [prompt]

Commands:
  agents             Manage agents
  doctor             Check Claude health
  experimental-next  Future command exposed by the real CLI help
  plugin|plugins     Manage plugins
  update|upgrade     Update Claude
HELP
  exit 0
fi
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
                [str(wrapper), *argv],
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


def run_wrapper_terminal_env_probe(
    argv: list[str],
    *,
    hooks_disabled: bool = False,
) -> tuple[int, dict[str, str], list[str], str, set[str]]:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-env-probe-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "cmux-claude-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        env_log = tmp / "real-env.log"
        args_log = tmp / "real-args.log"
        socket_path = str(tmp / "cmux.sock")
        fingerprint_env = {
            "CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.envprobe",
            "CMUX_BUNDLED_CLI_PATH": str(wrapper_dir / "cmux"),
            "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION": "1",
            "CMUX_PANEL_ID": "panel:test",
            "CMUX_PORT": "9170",
            "CMUX_PORT_END": "9179",
            "CMUX_PORT_RANGE": "10",
            "CMUX_SHELL_INTEGRATION": "1",
            "CMUX_SHELL_INTEGRATION_DIR": str(tmp / "shell-integration"),
            "CMUX_SOCKET_PATH": socket_path,
            "CMUX_SURFACE_ID": "surface:test",
            "CMUX_TAB_ID": "tab:test",
            "CMUX_WORKSPACE_ID": "workspace:test",
            "TERMINFO": str(tmp / "terminfo"),
        }
        if hooks_disabled:
            fingerprint_env["CMUX_CLAUDE_HOOKS_DISABLED"] = "1"
        probe_key_lines = "\n".join(f"  {key}" for key in fingerprint_env)

        make_executable(
            real_dir / "claude",
            f"""#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ENV_LOG"
: > "$FAKE_REAL_ARGS_LOG"
keys=(
{probe_key_lines}
)
for key in "${{keys[@]}}"; do
  if [[ ${{!key+x}} ]]; then
    printf '%s=%s\\n' "$key" "${{!key}}" >> "$FAKE_REAL_ENV_LOG"
  else
    printf '%s=__UNSET__\\n' "$key" >> "$FAKE_REAL_ENV_LOG"
  fi
done
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"
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
            env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
            env.update(fingerprint_env)
            env["FAKE_REAL_ENV_LOG"] = str(env_log)
            env["FAKE_REAL_ARGS_LOG"] = str(args_log)

            proc = subprocess.run(
                [str(wrapper), *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            test_socket.close()

        observed_env = dict(line.split("=", 1) for line in read_lines(env_log))
        return proc.returncode, observed_env, read_lines(args_log), proc.stderr.strip(), set(fingerprint_env)


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
    socket_state: str = "live",
    hooks_disabled: bool = False,
    in_cmux: bool = True,
    setup_env=None,
) -> tuple[int, dict[str, str], list[str], str]:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-auth-env-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "cmux-claude-wrapper"
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
  ANTHROPIC_BEDROCK_BASE_URL
  ANTHROPIC_MODEL
  ANTHROPIC_SMALL_FAST_MODEL
  ANTHROPIC_VERTEX_BASE_URL
  ANTHROPIC_VERTEX_PROJECT_ID
  AWS_PROFILE
  AWS_REGION
  CLAUDE_CODE_USE_BEDROCK
  CLAUDE_CODE_USE_VERTEX
  CLAUDE_CONFIG_DIR
  CLOUD_ML_REGION
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
  if [[ "${FAKE_CMUX_PING_OK:-0}" == "1" ]]; then
    exit 0
  fi
  exit 1
fi
exit 0
""",
        )

        test_socket: socket.socket | None = None
        if socket_state in {"live", "stale"}:
            test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if test_socket is not None:
                test_socket.bind(socket_path)

            env = os.environ.copy()
            for ambient_cmux_key in [k for k in env if k.startswith("CMUX_")]:
                env.pop(ambient_cmux_key, None)
            for ambient_aws_key in [k for k in env if k.startswith("AWS_")]:
                env.pop(ambient_aws_key, None)
            for ambient_key in (
                "ANTHROPIC_API_KEY",
                "ANTHROPIC_AUTH_TOKEN",
                "ANTHROPIC_BASE_URL",
                "ANTHROPIC_BEDROCK_BASE_URL",
                "ANTHROPIC_MODEL",
                "ANTHROPIC_SMALL_FAST_MODEL",
                "ANTHROPIC_VERTEX_BASE_URL",
                "ANTHROPIC_VERTEX_PROJECT_ID",
                "CLAUDE_CODE_USE_BEDROCK",
                "CLAUDE_CODE_USE_VERTEX",
                "CLAUDE_CONFIG_DIR",
                "CLOUD_ML_REGION",
            ):
                env.pop(ambient_key, None)
            env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
            if in_cmux:
                env["CMUX_SURFACE_ID"] = "surface:test"
                env["CMUX_SOCKET_PATH"] = socket_path
            env["FAKE_AUTH_ENV_LOG"] = str(auth_env_log)
            env["FAKE_ARGS_LOG"] = str(args_log)
            env["FAKE_CMUX_PING_OK"] = "1" if socket_state == "live" else "0"
            if hooks_disabled:
                env["CMUX_CLAUDE_HOOKS_DISABLED"] = "1"
            if setup_env is not None:
                env.update(setup_env(tmp))
            env.update(inherited_env)

            proc = subprocess.run(
                [str(wrapper), *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            if test_socket is not None:
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
    expected_hooks = {"SessionStart", "Stop", "SubagentStop", "SessionEnd", "Notification", "UserPromptSubmit", "PreToolUse", "PermissionRequest"}
    expect(set(hooks.keys()) == expected_hooks, f"unexpected hook keys: {hooks.keys()}, expected {expected_hooks}", failures)
    for hook_name, expected_subcommand in {
        "SessionStart": "session-start",
        "Stop": "stop",
        "SessionEnd": "session-end",
        "Notification": "notification",
        "UserPromptSubmit": "prompt-submit",
    }.items():
        hook_command = hooks.get(hook_name, [{}])[0].get("hooks", [{}])[0].get("command", "")
        expect(
            hook_command == f'"${{CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}}" hooks claude {expected_subcommand}',
            f"{hook_name} hook should pin bundled cmux, got {hook_command!r}",
            failures,
        )
    pre_tool_use_groups = hooks.get("PreToolUse", [])
    cron_guard_groups = [group for group in pre_tool_use_groups if group.get("matcher") == "CronCreate"]
    expect(cron_guard_groups, f"PreToolUse should install a CronCreate guard, got {pre_tool_use_groups}", failures)
    if cron_guard_groups:
        cron_guard_hooks = cron_guard_groups[0].get("hooks", [])
        expect(
            any(
                h.get("command") == '"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks claude cron-create-guard'
                and h.get("async") is not True
                for h in cron_guard_hooks
            ),
            f"CronCreate guard should synchronously call hooks claude cron-create-guard, got {cron_guard_hooks}",
            failures,
        )

    # General PreToolUse telemetry should remain async to avoid blocking tool execution.
    pre_tool_use_hooks = [
        hook
        for group in pre_tool_use_groups
        for hook in group.get("hooks", [])
        if "pre-tool-use" in hook.get("command", "")
    ]
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
    subagent_stop_hooks = hooks.get("SubagentStop", [{}])[0].get("hooks", [{}])
    expect(
        any(
            h.get("command") == '"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks feed --source claude'
            and h.get("async") is True
            for h in subagent_stop_hooks
        ),
        f"SubagentStop hook should call hooks feed asynchronously, got {subagent_stop_hooks}",
        failures,
    )
    expect(
        not any("hooks claude stop" in h.get("command", "") for h in subagent_stop_hooks),
        f"SubagentStop hook should not call the visible stop hook, got {subagent_stop_hooks}",
        failures,
    )
    # SessionEnd should have a short timeout (session is exiting)
    session_end_hooks = hooks.get("SessionEnd", [{}])[0].get("hooks", [{}])
    expect(
        any(h.get("timeout", 999) <= 2 for h in session_end_hooks),
        f"SessionEnd hook should have short timeout, got {session_end_hooks}",
        failures,
    )


def test_live_socket_merges_user_settings_into_hooks(failures: list[str]) -> None:
    code, real_argv, _cmux_log, stderr, *_ = run_wrapper(
        socket_state="live",
        argv=["--settings", '{"ultracode": true, "effortLevel": "max"}', "-p", "hi"],
    )
    expect(code == 0, f"merge user settings: wrapper exited {code}: {stderr}", failures)
    expect(
        real_argv.count("--settings") == 1,
        f"merge user settings: expected one merged --settings, got {real_argv}",
        failures,
    )
    settings = parse_settings_arg(real_argv)
    expect(
        settings.get("preferredNotifChannel") == "notifications_disabled",
        f"merge user settings: cmux hook settings lost, got {settings}",
        failures,
    )
    expected_hooks = {
        "SessionStart", "Stop", "SubagentStop", "SessionEnd",
        "Notification", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
    }
    expect(
        set(settings.get("hooks", {}).keys()) == expected_hooks,
        f"merge user settings: cmux hooks missing after merge, got {settings.get('hooks', {}).keys()}",
        failures,
    )
    expect(
        settings.get("ultracode") is True,
        f"merge user settings: user 'ultracode' dropped, got {settings}",
        failures,
    )
    expect(
        settings.get("effortLevel") == "max",
        f"merge user settings: user 'effortLevel' dropped, got {settings}",
        failures,
    )
    expect(
        '{"ultracode": true, "effortLevel": "max"}' not in real_argv,
        f"merge user settings: raw user --settings should be folded in, got {real_argv}",
        failures,
    )
    expect(
        "-p" in real_argv and "hi" in real_argv,
        f"merge user settings: user args dropped, got {real_argv}",
        failures,
    )


def test_live_socket_merges_inline_settings_form(failures: list[str]) -> None:
    code, real_argv, _cmux_log, stderr, *_ = run_wrapper(
        socket_state="live",
        argv=['--settings={"ultracode": true}', "hello"],
    )
    expect(code == 0, f"inline settings: wrapper exited {code}: {stderr}", failures)
    expect(
        real_argv.count("--settings") == 1,
        f"inline settings: expected one merged --settings, got {real_argv}",
        failures,
    )
    settings = parse_settings_arg(real_argv)
    expect(settings.get("ultracode") is True, f"inline settings: user key dropped, got {settings}", failures)
    expect(
        settings.get("preferredNotifChannel") == "notifications_disabled",
        f"inline settings: cmux hooks lost, got {settings}",
        failures,
    )
    expect(real_argv[-1] == "hello", f"inline settings: positional arg dropped, got {real_argv}", failures)


def test_live_socket_repeated_settings_user_value_wins_conflict(failures: list[str]) -> None:
    # The wrapper folds repeated user --settings into ONE merged payload, so
    # Claude Code never sees multiple --settings and its own multi-flag
    # precedence (which changed from first-wins on <=2.1.168 to last-wins on
    # >=2.1.169) is irrelevant. Among the user's own repeated --settings, the
    # earliest-listed value wins a scalar conflict. Asserted on the WRAPPER
    # OUTPUT (a single merged --settings in argv).
    code, real_argv, _cmux_log, stderr, *_ = run_wrapper(
        socket_state="live",
        argv=[
            "--settings", '{"effortLevel": "high", "a": 1}',
            "--settings", '{"effortLevel": "low", "b": 2}',
            "hi",
        ],
    )
    expect(code == 0, f"merged: wrapper exited {code}: {stderr}", failures)
    expect(
        real_argv.count("--settings") == 1,
        f"merged: expected one combined --settings, got {real_argv}",
        failures,
    )
    settings = parse_settings_arg(real_argv)
    expect(
        settings.get("effortLevel") == "high",
        f"merged: earliest user --settings should win the conflict, got {settings}",
        failures,
    )
    expect(
        settings.get("a") == 1 and settings.get("b") == 2,
        f"merged: non-conflicting user keys should all survive, got {settings}",
        failures,
    )
    expect(
        settings.get("preferredNotifChannel") == "notifications_disabled",
        f"merged: cmux hook settings lost, got {settings}",
        failures,
    )


def test_live_socket_user_nonobject_hooks_does_not_drop_cmux_hooks(failures: list[str]) -> None:
    # Regression: the merge must never let a non-object/array user value clobber
    # cmux's own hook structure. If a user --settings sets `hooks` to a non-object
    # (here an array; `null` behaves the same), the cmux hook object must survive
    # so notifications/status keep working, while the user's other keys still apply.
    code, real_argv, _cmux_log, stderr, *_ = run_wrapper(
        socket_state="live",
        argv=[
            "--settings", '{"hooks": [], "myKey": "kept"}',
            "hi",
        ],
    )
    expect(code == 0, f"nonobject-hooks: wrapper exited {code}: {stderr}", failures)
    expect(
        real_argv.count("--settings") == 1,
        f"nonobject-hooks: expected one combined --settings, got {real_argv}",
        failures,
    )
    settings = parse_settings_arg(real_argv)
    hooks = settings.get("hooks")
    expect(
        isinstance(hooks, dict) and "SessionStart" in hooks,
        f"nonobject-hooks: cmux hook object dropped by non-object user hooks, got {hooks!r}",
        failures,
    )
    expect(
        settings.get("preferredNotifChannel") == "notifications_disabled",
        f"nonobject-hooks: cmux preferredNotifChannel lost, got {settings}",
        failures,
    )
    expect(
        settings.get("myKey") == "kept",
        f"nonobject-hooks: user non-conflicting key dropped, got {settings}",
        failures,
    )


def test_live_socket_invalid_settings_warns_and_falls_back(failures: list[str]) -> None:
    # A malformed --settings must not be dropped in silence: the wrapper surfaces
    # a stderr warning instead of quietly reverting to the dual --settings
    # behavior that #2816 fixes.
    code, real_argv, _cmux_log, stderr, *_ = run_wrapper(
        socket_state="live",
        argv=["--settings", "{not valid json", "hi"],
    )
    expect(code == 0, f"invalid settings: wrapper exited {code}: {stderr}", failures)
    expect(
        "merge failed" in stderr,
        f"invalid settings: expected a stderr warning, got {stderr!r}",
        failures,
    )
    expect(
        "{not valid json" in real_argv,
        f"invalid settings: expected fallback to forward original args, got {real_argv}",
        failures,
    )


def test_live_socket_merges_settings_file_form(failures: list[str]) -> None:
    # --settings <path> reads JSON from disk (readFileSync/expand). Exercise that
    # loader branch end-to-end so path parsing/merging cannot silently regress.
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-settings-file-") as td:
        settings_path = Path(td) / "user-settings.json"
        settings_path.write_text('{"ultracode": true, "effortLevel": "max"}', encoding="utf-8")
        code, real_argv, _cmux_log, stderr, *_ = run_wrapper(
            socket_state="live",
            argv=["--settings", str(settings_path), "hello"],
        )
    expect(code == 0, f"settings file: wrapper exited {code}: {stderr}", failures)
    expect(
        real_argv.count("--settings") == 1,
        f"settings file: expected one merged --settings, got {real_argv}",
        failures,
    )
    settings = parse_settings_arg(real_argv)
    expect(settings.get("ultracode") is True, f"settings file: user key dropped, got {settings}", failures)
    expect(settings.get("effortLevel") == "max", f"settings file: user key dropped, got {settings}", failures)
    expect(
        settings.get("preferredNotifChannel") == "notifications_disabled",
        f"settings file: cmux hooks lost, got {settings}",
        failures,
    )
    expect(real_argv[-1] == "hello", f"settings file: positional arg dropped, got {real_argv}", failures)


def test_live_socket_empty_settings_warns_instead_of_silent_drop(failures: list[str]) -> None:
    # An explicit empty --settings= must not be swallowed in silence: the wrapper
    # surfaces the merge-failure warning instead of dropping the flag with no
    # signal (CodeRabbit review on #5388).
    code, real_argv, _cmux_log, stderr, *_ = run_wrapper(
        socket_state="live",
        argv=["--settings=", "hi"],
    )
    expect(code == 0, f"empty settings: wrapper exited {code}: {stderr}", failures)
    expect(
        "merge failed" in stderr,
        f"empty settings: expected a stderr warning, got {stderr!r}",
        failures,
    )
    expect(
        "--settings=" in real_argv and "hi" in real_argv,
        f"empty settings: expected fallback to forward original args, got {real_argv}",
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


def test_command_like_invocations_bypass_hook_injection(failures: list[str]) -> None:
    subcommands = [
        "mcp",
        "config",
        "api-key",
        "rc",
        "remote-control",
        "agents",
        "doctor",
        "update",
        "upgrade",
        "auth",
        "project",
        "setup-token",
        "install",
        "daemon",
        "experimental-next",
    ]
    for subcommand in subcommands:
        code, real_argv, _, stderr, _, node_options, _, _, _, _ = run_wrapper(
            socket_state="live",
            argv=[subcommand],
        )
        expect(code == 0, f"{subcommand} passthrough: wrapper exited {code}: {stderr}", failures)
        expect(real_argv == [subcommand], f"{subcommand} passthrough: expected raw argv, got {real_argv}", failures)
        expect("--settings" not in real_argv, f"{subcommand} passthrough: expected no --settings injection, got {real_argv}", failures)
        expect("--session-id" not in real_argv, f"{subcommand} passthrough: expected no --session-id injection, got {real_argv}", failures)
        expect(node_options == "__UNSET__", f"{subcommand} passthrough: expected no NODE_OPTIONS injection, got {node_options!r}", failures)

    code, real_argv, _, stderr, _, _, _, _, _, _ = run_wrapper(
        socket_state="live",
        argv=["--model", "sonnet", "agents"],
    )
    expect(code == 0, f"agents after global option passthrough: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["--model", "sonnet", "agents"], f"agents after global option passthrough: expected raw argv, got {real_argv}", failures)
    expect("--settings" not in real_argv, f"agents after global option passthrough: expected no --settings injection, got {real_argv}", failures)
    expect("--session-id" not in real_argv, f"agents after global option passthrough: expected no --session-id injection, got {real_argv}", failures)


def test_passthrough_flags_bypass_hook_injection(failures: list[str]) -> None:
    for flag in ("--help", "--version", "-h", "-v"):
        code, real_argv, _, stderr, _, node_options, _, _, _, _ = run_wrapper(
            socket_state="live",
            argv=[flag],
        )
        expect(code == 0, f"{flag} passthrough: wrapper exited {code}: {stderr}", failures)
        expect(real_argv == [flag], f"{flag} passthrough: expected raw argv, got {real_argv}", failures)
        expect("--settings" not in real_argv, f"{flag} passthrough: expected no --settings injection, got {real_argv}", failures)
        expect("--session-id" not in real_argv, f"{flag} passthrough: expected no --session-id injection, got {real_argv}", failures)
        expect(node_options == "__UNSET__", f"{flag} passthrough: expected no NODE_OPTIONS injection, got {node_options!r}", failures)


def test_agents_subcommand_removes_cmux_terminal_fingerprint(failures: list[str]) -> None:
    code, observed_env, real_argv, stderr, expected_keys = run_wrapper_terminal_env_probe(["agents"])
    expect(code == 0, f"agents env probe: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["agents"], f"agents env probe: expected raw argv, got {real_argv}", failures)
    expect(
        set(observed_env) == expected_keys,
        f"agents env probe: expected probed keys {sorted(expected_keys)}, got {sorted(observed_env)}",
        failures,
    )

    for key, value in observed_env.items():
        expect(
            value == "__UNSET__",
            f"agents env probe: expected {key} unset, got {value!r}",
            failures,
        )


def test_hooks_disabled_preserves_cmux_terminal_env_for_custom_hooks(failures: list[str]) -> None:
    scenarios = [
        ("interactive", ["hello"]),
        ("command-like", ["agents"]),
    ]
    for label, argv in scenarios:
        code, observed_env, real_argv, stderr, expected_keys = run_wrapper_terminal_env_probe(
            argv,
            hooks_disabled=True,
        )
        expect(code == 0, f"hooks-disabled {label} env probe: wrapper exited {code}: {stderr}", failures)
        expect(real_argv == argv, f"hooks-disabled {label} env probe: expected raw argv, got {real_argv}", failures)
        expect(
            set(observed_env) == expected_keys,
            f"hooks-disabled {label} env probe: expected probed keys {sorted(expected_keys)}, got {sorted(observed_env)}",
            failures,
        )

        for key, expected_value in {
            "CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.envprobe",
            "CMUX_CLAUDE_HOOKS_DISABLED": "1",
            "CMUX_PANEL_ID": "panel:test",
            "CMUX_SURFACE_ID": "surface:test",
            "CMUX_TAB_ID": "tab:test",
            "CMUX_WORKSPACE_ID": "workspace:test",
        }.items():
            expect(
                observed_env.get(key) == expected_value,
                f"hooks-disabled {label} env probe: expected {key} preserved as {expected_value!r}, got {observed_env.get(key)!r}",
                failures,
            )
        for key in sorted(k for k in expected_keys if k.startswith("CMUX_")):
            expect(
                observed_env.get(key) != "__UNSET__",
                f"hooks-disabled {label} env probe: expected {key} to survive passthrough, got unset",
                failures,
            )


def test_live_socket_preserves_third_party_claude_auth_for_fresh_launch(failures: list[str]) -> None:
    # The model ids here are backend-qualified (Vertex `@<date>` / Bedrock
    # `<region>.anthropic.<model>-v1:0`) so they are still scrubbed on the
    # default Anthropic path; plain-id preservation is covered by
    # test_live_socket_preserves_plain_anthropic_model_on_default_path (#7047).
    inherited = {
        "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
        "ANTHROPIC_API_KEY": "stale-api-key",
        "ANTHROPIC_AUTH_TOKEN": "third-party-auth-token",
        "ANTHROPIC_BASE_URL": "https://api.example.test",
        "ANTHROPIC_MODEL": "claude-sonnet-4-5@20250929",
        "ANTHROPIC_SMALL_FAST_MODEL": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
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


def test_hooks_disabled_clears_stale_auth_selection_before_passthrough(failures: list[str]) -> None:
    # Backend-qualified model ids (still scrubbed on the default Anthropic path);
    # plain-id preservation is covered by
    # test_live_socket_preserves_plain_anthropic_model_on_default_path (#7047).
    inherited = {
        "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
        "ANTHROPIC_API_KEY": "stale-api-key",
        "ANTHROPIC_MODEL": "claude-sonnet-4-5@20250929",
        "ANTHROPIC_SMALL_FAST_MODEL": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    }
    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["hello"],
        hooks_disabled=True,
        inherited_env=inherited,
    )
    expect(code == 0, f"hooks-disabled auth env: wrapper exited {code}: {stderr}", failures)
    expect(auth_env.get("CLAUDE_CONFIG_DIR") == "/tmp/claude-config", f"hooks-disabled auth env: expected CLAUDE_CONFIG_DIR preserved, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}", failures)
    for key in [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
    ]:
        expect(auth_env.get(key) == "__UNSET__", f"hooks-disabled auth env: expected {key} unset, got {auth_env.get(key)!r}", failures)
    expect(real_argv == ["hello"], f"hooks-disabled auth env: expected passthrough args, got {real_argv}", failures)


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


def test_live_socket_resume_self_heals_mismatched_claude_config_dir(failures: list[str]) -> None:
    # Regression for https://github.com/manaflow-ai/cmux/issues/6194: when cmux is
    # launched with a foreign CLAUDE_CONFIG_DIR (e.g. the .app was opened from a
    # terminal whose agent set one), a restored `claude --resume <id>` must still
    # find the session by self-healing CLAUDE_CONFIG_DIR to the config root that
    # actually holds the transcript, instead of reporting "No conversation found"
    # and dropping the user back to a bare shell.
    session_id = "aee7524f-3fc9-4a78-be26-ccd6400fe5d1"
    expected: dict[str, str] = {}

    def setup_env(tmp: Path) -> dict[str, str]:
        home = tmp / "home"
        # The session transcript actually lives under the DEFAULT config dir.
        default_root = home / ".claude"
        (default_root / "projects" / "-Users-austinwang").mkdir(parents=True)
        (default_root / "projects" / "-Users-austinwang" / f"{session_id}.jsonl").write_text(
            "{}\n", encoding="utf-8"
        )
        # A FOREIGN config dir is inherited: a valid config dir that does NOT hold
        # this session (mirrors the cmux app inheriting an agent's CLAUDE_CONFIG_DIR).
        foreign_root = home / ".codex-accounts" / "claude" / "_pforeign"
        (foreign_root / "projects").mkdir(parents=True)
        expected["path"] = str(default_root)
        return {
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(foreign_root),
        }

    code, auth_env, _, stderr = run_wrapper_auth_env(
        argv=["--resume", session_id],
        inherited_env={},
        setup_env=setup_env,
    )
    expect(code == 0, f"resume self-heal: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("CLAUDE_CONFIG_DIR") == expected["path"],
        "resume self-heal: expected CLAUDE_CONFIG_DIR reset to the transcript's config root "
        f"{expected['path']!r}, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}",
        failures,
    )


def test_live_socket_resume_self_heals_bare_legacy_subrouter_config_dir(failures: list[str]) -> None:
    session_id = "e8a5bdb8-c24f-498e-a6ee-1ad9fe34328b"
    expected: dict[str, str] = {}

    def setup_env(tmp: Path) -> dict[str, str]:
        home = tmp / "home"
        legacy_root = home / ".subrouter" / "codex" / "claude"
        (legacy_root / "projects" / "-Users-austinwang").mkdir(parents=True)
        (legacy_root / "projects" / "-Users-austinwang" / f"{session_id}.jsonl").write_text(
            "{}\n", encoding="utf-8"
        )
        foreign_root = home / ".codex-accounts" / "claude" / "_pforeign"
        (foreign_root / "projects").mkdir(parents=True)
        expected["path"] = str(legacy_root)
        return {
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(foreign_root),
        }

    code, auth_env, _, stderr = run_wrapper_auth_env(
        argv=["--resume", session_id],
        inherited_env={},
        setup_env=setup_env,
    )
    expect(code == 0, f"bare legacy resume self-heal: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("CLAUDE_CONFIG_DIR") == expected["path"],
        "bare legacy resume self-heal: expected CLAUDE_CONFIG_DIR reset to the transcript's config root "
        f"{expected['path']!r}, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}",
        failures,
    )


def test_stale_socket_resume_self_heals_mismatched_claude_config_dir(failures: list[str]) -> None:
    # App restore can launch terminal startup commands before the cmux socket is
    # accepting pings. Hook injection should be skipped in that window, but
    # explicit `--resume` still has to select the config root that owns the
    # transcript or Claude reports "No conversation found".
    session_id = "5b5d0816-ef91-4a8d-8933-68a114787c40"
    expected: dict[str, str] = {}

    def setup_env(tmp: Path) -> dict[str, str]:
        home = tmp / "home"
        default_root = home / ".claude"
        (default_root / "projects" / "-Users-austinwang-manaflow-term-cmux166").mkdir(parents=True)
        (
            default_root / "projects" / "-Users-austinwang-manaflow-term-cmux166" / f"{session_id}.jsonl"
        ).write_text("{}\n", encoding="utf-8")
        foreign_root = home / ".codex-accounts" / "claude" / "_pforeign"
        (foreign_root / "projects").mkdir(parents=True)
        expected["path"] = str(default_root)
        return {
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(foreign_root),
        }

    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["--resume", session_id],
        inherited_env={},
        socket_state="stale",
        setup_env=setup_env,
    )
    expect(code == 0, f"stale socket resume self-heal: wrapper exited {code}: {stderr}", failures)
    expect(
        real_argv == ["--resume", session_id],
        f"stale socket resume self-heal: expected passthrough resume argv, got {real_argv}",
        failures,
    )
    expect(
        auth_env.get("CLAUDE_CONFIG_DIR") == expected["path"],
        "stale socket resume self-heal: expected CLAUDE_CONFIG_DIR reset to the transcript's config root "
        f"{expected['path']!r}, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}",
        failures,
    )


def test_stale_socket_resume_self_heals_after_value_option(failures: list[str]) -> None:
    # The stale-socket path runs before hook injection. Its resume parser still
    # has to skip value-taking options that appear before `--resume`, including
    # newer Claude options that are not in cmux's preserved-argument allowlists.
    session_id = "017427ef-1828-43d9-ae1d-8ec6d4b2bdb7"
    expected: dict[str, str] = {}

    def setup_env(tmp: Path) -> dict[str, str]:
        home = tmp / "home"
        default_root = home / ".claude"
        (default_root / "projects" / "-Users-austinwang-manaflow-term-cmux166").mkdir(parents=True)
        (
            default_root / "projects" / "-Users-austinwang-manaflow-term-cmux166" / f"{session_id}.jsonl"
        ).write_text("{}\n", encoding="utf-8")
        foreign_root = home / ".codex-accounts" / "claude" / "_pforeign"
        (foreign_root / "projects").mkdir(parents=True)
        expected["path"] = str(default_root)
        return {
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(foreign_root),
        }

    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["--permission-prompt-tool", "/tmp/cmux-permission-tool", "--resume", session_id],
        inherited_env={},
        socket_state="stale",
        setup_env=setup_env,
    )
    expect(code == 0, f"stale socket option resume self-heal: wrapper exited {code}: {stderr}", failures)
    expect(
        real_argv == ["--permission-prompt-tool", "/tmp/cmux-permission-tool", "--resume", session_id],
        f"stale socket option resume self-heal: expected passthrough argv, got {real_argv}",
        failures,
    )
    expect(
        auth_env.get("CLAUDE_CONFIG_DIR") == expected["path"],
        "stale socket option resume self-heal: expected CLAUDE_CONFIG_DIR reset to the transcript's config root "
        f"{expected['path']!r}, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}",
        failures,
    )
    expect(
        "command not found" not in stderr,
        f"stale socket option resume self-heal: parser emitted shell diagnostic: {stderr}",
        failures,
    )


def test_plain_terminal_resume_does_not_self_heal_mismatched_claude_config_dir(failures: list[str]) -> None:
    # Outside cmux, the wrapper must be a passthrough and must not repoint the
    # user's selected Claude account just because another config root has the id.
    session_id = "57d7a2a6-6261-4a6f-b950-10f892a0fd81"

    for hooks_disabled in (False, True):
        expected: dict[str, str] = {}

        def setup_env(tmp: Path) -> dict[str, str]:
            home = tmp / "home"
            default_root = home / ".claude"
            (default_root / "projects" / "-Users-austinwang").mkdir(parents=True)
            (default_root / "projects" / "-Users-austinwang" / f"{session_id}.jsonl").write_text(
                "{}\n", encoding="utf-8"
            )
            foreign_root = home / ".codex-accounts" / "claude" / "_pforeign"
            (foreign_root / "projects").mkdir(parents=True)
            expected["path"] = str(foreign_root)
            return {
                "HOME": str(home),
                "CLAUDE_CONFIG_DIR": str(foreign_root),
            }

        label = "hooks-disabled" if hooks_disabled else "normal"
        code, auth_env, real_argv, stderr = run_wrapper_auth_env(
            argv=["--resume", session_id],
            inherited_env={},
            socket_state="missing",
            hooks_disabled=hooks_disabled,
            in_cmux=False,
            setup_env=setup_env,
        )
        expect(code == 0, f"plain terminal {label} resume: wrapper exited {code}: {stderr}", failures)
        expect(
            real_argv == ["--resume", session_id],
            f"plain terminal {label} resume: expected passthrough argv, got {real_argv}",
            failures,
        )
        expect(
            auth_env.get("CLAUDE_CONFIG_DIR") == expected["path"],
            f"plain terminal {label} resume: expected CLAUDE_CONFIG_DIR to stay on the user's "
            f"selected root {expected['path']!r}, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}",
            failures,
        )


def test_live_socket_resume_after_unlisted_value_option_does_not_inject_session_id(failures: list[str]) -> None:
    code, real_argv, _, stderr, _, _, _, _, _, _ = run_wrapper(
        socket_state="live",
        argv=["--permission-prompt-tool", "/tmp/cmux-permission-tool", "--resume", "some-session-id"],
    )
    expect(code == 0, f"unlisted value option resume: wrapper exited {code}: {stderr}", failures)
    expect("--settings" in real_argv, f"unlisted value option resume: expected hook settings injection, got {real_argv}", failures)
    expect("--session-id" not in real_argv, f"unlisted value option resume: expected no generated session id, got {real_argv}", failures)
    passthrough_argv = list(real_argv)
    if "--settings" in passthrough_argv:
        settings_index = passthrough_argv.index("--settings")
        del passthrough_argv[settings_index:settings_index + 2]
    expect(
        passthrough_argv == ["--permission-prompt-tool", "/tmp/cmux-permission-tool", "--resume", "some-session-id"],
        f"unlisted value option resume: expected original argv preserved around injected settings, got {real_argv}",
        failures,
    )


def test_live_socket_resume_after_prompt_text_does_not_inject_session_id(failures: list[str]) -> None:
    session_id = "828449c9-b276-4f79-9f62-c20b52a8d5bb"
    expected: dict[str, str] = {}

    def setup_env(tmp: Path) -> dict[str, str]:
        home = tmp / "home"
        default_root = home / ".claude"
        (default_root / "projects" / "-work").mkdir(parents=True)
        (default_root / "projects" / "-work" / f"{session_id}.jsonl").write_text(
            "{}\n", encoding="utf-8"
        )
        foreign_root = home / ".codex-accounts" / "claude" / "_pforeign"
        (foreign_root / "projects").mkdir(parents=True)
        expected["path"] = str(default_root)
        return {
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(foreign_root),
        }

    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["follow up", "--resume", session_id],
        inherited_env={},
        setup_env=setup_env,
    )
    expect(code == 0, f"prompt-before-resume self-heal: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("CLAUDE_CONFIG_DIR") == expected["path"],
        "prompt-before-resume self-heal: expected CLAUDE_CONFIG_DIR reset to the transcript's config root "
        f"{expected['path']!r}, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}",
        failures,
    )
    expect("--settings" in real_argv, f"prompt-before-resume: expected hook settings injection, got {real_argv}", failures)
    expect("--session-id" not in real_argv, f"prompt-before-resume: expected no generated session id, got {real_argv}", failures)
    passthrough_argv = list(real_argv)
    if "--settings" in passthrough_argv:
        settings_index = passthrough_argv.index("--settings")
        del passthrough_argv[settings_index:settings_index + 2]
    expect(
        passthrough_argv == ["follow up", "--resume", session_id],
        f"prompt-before-resume: expected original argv preserved around injected settings, got {real_argv}",
        failures,
    )


def test_live_socket_resume_self_heals_nested_claude_transcript_config_dir(failures: list[str]) -> None:
    # Claude can store transcripts below nested project subdirectories. The
    # self-heal must still detect the holding config root, or `claude --resume`
    # keeps using the foreign inherited CLAUDE_CONFIG_DIR and fails.
    session_id = "4c86a3d2-28e3-4147-a7d1-31a1bcb7af10"
    expected: dict[str, str] = {}

    def setup_env(tmp: Path) -> dict[str, str]:
        home = tmp / "home"
        default_root = home / ".claude"
        transcript_dir = default_root / "projects" / "-Users-austinwang" / session_id / "messages"
        transcript_dir.mkdir(parents=True)
        (transcript_dir / f"{session_id}.jsonl").write_text("{}\n", encoding="utf-8")
        foreign_root = home / ".codex-accounts" / "claude" / "_pforeign"
        (foreign_root / "projects").mkdir(parents=True)
        expected["path"] = str(default_root)
        return {
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(foreign_root),
        }

    code, auth_env, _, stderr = run_wrapper_auth_env(
        argv=["--resume", session_id],
        inherited_env={},
        setup_env=setup_env,
    )
    expect(code == 0, f"nested resume self-heal: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("CLAUDE_CONFIG_DIR") == expected["path"],
        "nested resume self-heal: expected CLAUDE_CONFIG_DIR reset to the nested transcript's config root "
        f"{expected['path']!r}, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}",
        failures,
    )


def test_live_socket_resume_keeps_correct_claude_config_dir(failures: list[str]) -> None:
    # The self-heal must NOT override a CLAUDE_CONFIG_DIR that already holds the
    # session (no false positives that would repoint a correct resume).
    session_id = "bd83f291-c63e-46ce-bb65-753a76e5fbff"
    expected: dict[str, str] = {}

    def setup_env(tmp: Path) -> dict[str, str]:
        home = tmp / "home"
        # The current (custom) config dir DOES hold the session.
        current_root = home / ".codex-accounts" / "claude" / "_pcurrent"
        (current_root / "projects" / "-work").mkdir(parents=True)
        (current_root / "projects" / "-work" / f"{session_id}.jsonl").write_text(
            "{}\n", encoding="utf-8"
        )
        # A same-id transcript also exists under the default dir; the current dir
        # must still win because it already has it.
        default_root = home / ".claude"
        (default_root / "projects" / "-work").mkdir(parents=True)
        (default_root / "projects" / "-work" / f"{session_id}.jsonl").write_text(
            "{}\n", encoding="utf-8"
        )
        expected["path"] = str(current_root)
        return {
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(current_root),
        }

    code, auth_env, _, stderr = run_wrapper_auth_env(
        argv=["--resume", session_id],
        inherited_env={},
        setup_env=setup_env,
    )
    expect(code == 0, f"resume keep-correct: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("CLAUDE_CONFIG_DIR") == expected["path"],
        "resume keep-correct: expected CLAUDE_CONFIG_DIR left at the holding root "
        f"{expected['path']!r}, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}",
        failures,
    )


def test_live_socket_resume_self_heal_ignores_prompt_text_after_double_dash(failures: list[str]) -> None:
    # A fresh prompt can contain literal --resume text after `--`; that must not
    # trigger resume self-healing or suppress cmux's generated --session-id.
    session_id = "7e2f5010-98d4-465f-93f6-a01608943e5f"
    expected: dict[str, str] = {}

    def setup_env(tmp: Path) -> dict[str, str]:
        home = tmp / "home"
        default_root = home / ".claude"
        (default_root / "projects" / "-work").mkdir(parents=True)
        (default_root / "projects" / "-work" / f"{session_id}.jsonl").write_text(
            "{}\n", encoding="utf-8"
        )
        foreign_root = home / ".codex-accounts" / "claude" / "_pforeign"
        (foreign_root / "projects").mkdir(parents=True)
        expected["path"] = str(foreign_root)
        return {
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(foreign_root),
        }

    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["--", "explain", "--resume", session_id],
        inherited_env={},
        setup_env=setup_env,
    )
    expect(code == 0, f"resume prompt text: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("CLAUDE_CONFIG_DIR") == expected["path"],
        "resume prompt text: expected CLAUDE_CONFIG_DIR to stay on the fresh prompt root "
        f"{expected['path']!r}, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}",
        failures,
    )
    expect("--session-id" in real_argv, f"resume prompt text: expected generated --session-id, got {real_argv}", failures)


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


def test_live_socket_preserved_claude_config_dir_skips_resume_self_heal(failures: list[str]) -> None:
    session_id = "582054f9-2f87-4e90-ad8d-2f532ed8c61b"
    expected: dict[str, str] = {}

    def setup_env(tmp: Path) -> dict[str, str]:
        home = tmp / "home"
        default_root = home / ".claude"
        (default_root / "projects" / "-work").mkdir(parents=True)
        (default_root / "projects" / "-work" / f"{session_id}.jsonl").write_text(
            "{}\n", encoding="utf-8"
        )
        selected_root = home / ".subrouter" / "codex" / "claude" / "aziz-claude-1"
        (selected_root / "projects").mkdir(parents=True)
        expected["path"] = str(selected_root)
        return {
            "HOME": str(home),
            "CLAUDE_CONFIG_DIR": str(selected_root),
            "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV": "1",
            "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS": "CLAUDE_CONFIG_DIR",
        }

    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["--resume", session_id, "--fork-session"],
        inherited_env={},
        setup_env=setup_env,
    )
    expect(code == 0, f"preserved resume config dir: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("CLAUDE_CONFIG_DIR") == expected["path"],
        "preserved resume config dir: expected CLAUDE_CONFIG_DIR to remain on the selected profile root "
        f"{expected['path']!r}, got {auth_env.get('CLAUDE_CONFIG_DIR')!r}",
        failures,
    )
    expect(real_argv[-3:] == ["--resume", session_id, "--fork-session"], f"preserved resume config dir: expected resume+fork argv, got {real_argv}", failures)


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


def test_live_socket_auto_preserves_vertex_auth_when_truthy(failures: list[str]) -> None:
    # Regression for https://github.com/manaflow-ai/cmux/issues/3641.
    inherited = {
        "CLAUDE_CODE_USE_VERTEX": "1",
        "ANTHROPIC_API_KEY": "anthropic-key-must-be-scrubbed-on-vertex",
        "ANTHROPIC_MODEL": "claude-sonnet-4-5@20250929",
        "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5@20251001",
        "ANTHROPIC_VERTEX_PROJECT_ID": "my-gcp-project",
        "ANTHROPIC_VERTEX_BASE_URL": "https://us-east5-aiplatform.googleapis.com",
        "CLOUD_ML_REGION": "us-east5",
    }
    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["hello"],
        inherited_env=inherited,
    )
    expect(code == 0, f"vertex auto-preserve: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("CLAUDE_CODE_USE_VERTEX") == "1",
        f"vertex auto-preserve: expected CLAUDE_CODE_USE_VERTEX=1 preserved, got {auth_env.get('CLAUDE_CODE_USE_VERTEX')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_MODEL") == "claude-sonnet-4-5@20250929",
        f"vertex auto-preserve: expected Vertex ANTHROPIC_MODEL preserved, got {auth_env.get('ANTHROPIC_MODEL')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_SMALL_FAST_MODEL") == "claude-haiku-4-5@20251001",
        f"vertex auto-preserve: expected Vertex ANTHROPIC_SMALL_FAST_MODEL preserved, got {auth_env.get('ANTHROPIC_SMALL_FAST_MODEL')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_VERTEX_PROJECT_ID") == "my-gcp-project",
        f"vertex auto-preserve: expected ANTHROPIC_VERTEX_PROJECT_ID preserved, got {auth_env.get('ANTHROPIC_VERTEX_PROJECT_ID')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_VERTEX_BASE_URL") == "https://us-east5-aiplatform.googleapis.com",
        f"vertex auto-preserve: expected ANTHROPIC_VERTEX_BASE_URL preserved, got {auth_env.get('ANTHROPIC_VERTEX_BASE_URL')!r}",
        failures,
    )
    expect(
        auth_env.get("CLOUD_ML_REGION") == "us-east5",
        f"vertex auto-preserve: expected CLOUD_ML_REGION preserved, got {auth_env.get('CLOUD_ML_REGION')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_API_KEY") == "__UNSET__",
        f"vertex auto-preserve: expected ANTHROPIC_API_KEY cleared (Vertex does not consume it), got {auth_env.get('ANTHROPIC_API_KEY')!r}",
        failures,
    )
    expect(
        "--session-id" in real_argv,
        f"vertex auto-preserve: expected session injection, got {real_argv}",
        failures,
    )


def test_live_socket_auto_preserves_bedrock_auth_when_truthy(failures: list[str]) -> None:
    # Regression for https://github.com/manaflow-ai/cmux/issues/3638.
    inherited = {
        "CLAUDE_CODE_USE_BEDROCK": "1",
        "ANTHROPIC_API_KEY": "anthropic-key-must-be-scrubbed-on-bedrock",
        "ANTHROPIC_MODEL": "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
        "ANTHROPIC_SMALL_FAST_MODEL": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
        "ANTHROPIC_BEDROCK_BASE_URL": "https://bedrock-runtime.us-west-2.amazonaws.com",
        "AWS_REGION": "us-west-2",
        "AWS_PROFILE": "bedrock-prod",
    }
    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["hello"],
        inherited_env=inherited,
    )
    expect(code == 0, f"bedrock auto-preserve: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("CLAUDE_CODE_USE_BEDROCK") == "1",
        f"bedrock auto-preserve: expected CLAUDE_CODE_USE_BEDROCK=1 preserved, got {auth_env.get('CLAUDE_CODE_USE_BEDROCK')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_MODEL") == "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
        f"bedrock auto-preserve: expected Bedrock ANTHROPIC_MODEL preserved, got {auth_env.get('ANTHROPIC_MODEL')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_SMALL_FAST_MODEL") == "us.anthropic.claude-haiku-4-5-20251001-v1:0",
        f"bedrock auto-preserve: expected Bedrock ANTHROPIC_SMALL_FAST_MODEL preserved, got {auth_env.get('ANTHROPIC_SMALL_FAST_MODEL')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_BEDROCK_BASE_URL") == "https://bedrock-runtime.us-west-2.amazonaws.com",
        f"bedrock auto-preserve: expected ANTHROPIC_BEDROCK_BASE_URL preserved, got {auth_env.get('ANTHROPIC_BEDROCK_BASE_URL')!r}",
        failures,
    )
    expect(
        auth_env.get("AWS_REGION") == "us-west-2",
        f"bedrock auto-preserve: expected AWS_REGION preserved, got {auth_env.get('AWS_REGION')!r}",
        failures,
    )
    expect(
        auth_env.get("AWS_PROFILE") == "bedrock-prod",
        f"bedrock auto-preserve: expected AWS_PROFILE preserved, got {auth_env.get('AWS_PROFILE')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_API_KEY") == "__UNSET__",
        f"bedrock auto-preserve: expected ANTHROPIC_API_KEY cleared (Bedrock does not consume it), got {auth_env.get('ANTHROPIC_API_KEY')!r}",
        failures,
    )
    expect(
        "--session-id" in real_argv,
        f"bedrock auto-preserve: expected session injection, got {real_argv}",
        failures,
    )


def test_live_socket_does_not_auto_preserve_when_all_backends_are_falsy(failures: list[str]) -> None:
    # Falsy backend flags must be cleared, and the backend-specific model ids
    # that only make sense with those backends must NOT be auto-preserved. Plain
    # ids are covered separately by
    # test_live_socket_preserves_plain_anthropic_model_on_default_path, so use
    # backend-qualified values here to keep this focused on the no-live-backend
    # leak guard (#3641 / #3638 / #7047).
    inherited = {
        "CLAUDE_CODE_USE_VERTEX": "0",
        "CLAUDE_CODE_USE_BEDROCK": "",
        "ANTHROPIC_MODEL": "claude-sonnet-4-5@20250929",
        "ANTHROPIC_SMALL_FAST_MODEL": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    }
    code, auth_env, _, stderr = run_wrapper_auth_env(
        argv=["hello"],
        inherited_env=inherited,
    )
    expect(code == 0, f"falsy backends: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("CLAUDE_CODE_USE_VERTEX") == "__UNSET__",
        f"falsy backends: expected CLAUDE_CODE_USE_VERTEX=0 to be cleared, got {auth_env.get('CLAUDE_CODE_USE_VERTEX')!r}",
        failures,
    )
    expect(
        auth_env.get("CLAUDE_CODE_USE_BEDROCK") == "__UNSET__",
        f"falsy backends: expected empty CLAUDE_CODE_USE_BEDROCK to be cleared, got {auth_env.get('CLAUDE_CODE_USE_BEDROCK')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_MODEL") == "__UNSET__",
        f"falsy backends: expected backend-qualified ANTHROPIC_MODEL cleared (no live Vertex/Bedrock backend), got {auth_env.get('ANTHROPIC_MODEL')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_SMALL_FAST_MODEL") == "__UNSET__",
        f"falsy backends: expected backend-qualified ANTHROPIC_SMALL_FAST_MODEL cleared (no live Vertex/Bedrock backend), got {auth_env.get('ANTHROPIC_SMALL_FAST_MODEL')!r}",
        failures,
    )


def test_live_socket_preserves_plain_anthropic_model_on_default_path(failures: list[str]) -> None:
    # Regression for https://github.com/manaflow-ai/cmux/issues/7047.
    # A user who pins `export ANTHROPIC_MODEL=claude-opus-4-8[1m]` to get the
    # Max-plan 1M context window must keep that selection inside cmux on the
    # default Anthropic API path, exactly like a plain Terminal does. A plain
    # (non-backend-qualified) id is valid against the Anthropic API, so the
    # auth-selection scrub must NOT strip it when no Vertex/Bedrock backend is
    # active.
    inherited = {
        "ANTHROPIC_MODEL": "claude-opus-4-8[1m]",
        "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5",
    }
    code, auth_env, real_argv, stderr = run_wrapper_auth_env(
        argv=["hello"],
        inherited_env=inherited,
    )
    expect(code == 0, f"plain model default path: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("ANTHROPIC_MODEL") == "claude-opus-4-8[1m]",
        f"plain model default path: expected ANTHROPIC_MODEL preserved, got {auth_env.get('ANTHROPIC_MODEL')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_SMALL_FAST_MODEL") == "claude-haiku-4-5",
        f"plain model default path: expected ANTHROPIC_SMALL_FAST_MODEL preserved, got {auth_env.get('ANTHROPIC_SMALL_FAST_MODEL')!r}",
        failures,
    )
    # The model pin must not block the normal cmux hook/session injection.
    expect(
        "--session-id" in real_argv,
        f"plain model default path: expected session injection, got {real_argv}",
        failures,
    )


def test_live_socket_strips_backend_qualified_model_on_default_path(failures: list[str]) -> None:
    # Guard for the #7047 fix: preserving plain ids must NOT reintroduce the leak
    # the scrub was added to prevent. A stale backend-qualified id is invalid on
    # the default Anthropic API and must still be stripped when no Vertex/Bedrock
    # backend is active. Each value isolates a distinct marker in
    # claude_model_id_is_backend_qualified so every arm is proven independently.
    # In particular `anthropic.claude-3-haiku-20240307` carries the Bedrock vendor
    # namespace with no `@`/`:`/`/`, so it exercises the `*anthropic.*` arm alone:
    # dropping that arm would leave only this case failing.
    backend_qualified_ids = [
        "claude-sonnet-4-5@20250929",                     # Vertex: '@' publisher-date pin
        "anthropic.claude-3-haiku-20240307",              # Bedrock vendor namespace, no ':' suffix
        "us.anthropic.claude-haiku-4-5-20251001-v1:0",    # Bedrock cross-region inference profile
        "arn:aws:bedrock:us-east-1:1:inference-profile/p",  # Bedrock application-inference-profile ARN
    ]
    for model_id in backend_qualified_ids:
        code, auth_env, _, stderr = run_wrapper_auth_env(
            argv=["hello"],
            inherited_env={"ANTHROPIC_MODEL": model_id},
        )
        expect(
            code == 0,
            f"backend-qualified default path ({model_id!r}): wrapper exited {code}: {stderr}",
            failures,
        )
        expect(
            auth_env.get("ANTHROPIC_MODEL") == "__UNSET__",
            f"backend-qualified default path: expected {model_id!r} stripped on the default Anthropic path, got {auth_env.get('ANTHROPIC_MODEL')!r}",
            failures,
        )


def test_live_socket_auto_preserve_accepts_all_documented_truthy_variants(failures: list[str]) -> None:
    # The wrapper recognizes 1|true|TRUE|yes|YES as truthy (matching the
    # existing CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV parser); the focused
    # auto-preserve tests above only exercise "1". This loop pins all 5
    # documented variants for both backends so a future "simplification"
    # of the case statement cannot silently drop yes/YES/true/TRUE.
    for backend_key in ("CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_BEDROCK"):
        for variant in ("1", "true", "TRUE", "yes", "YES"):
            inherited = {backend_key: variant}
            code, auth_env, _, stderr = run_wrapper_auth_env(
                argv=["hello"],
                inherited_env=inherited,
            )
            label = f"{backend_key}={variant!r}"
            expect(code == 0, f"truthy variants ({label}): wrapper exited {code}: {stderr}", failures)
            expect(
                auth_env.get(backend_key) == variant,
                f"truthy variants ({label}): expected {backend_key} preserved, got {auth_env.get(backend_key)!r}",
                failures,
            )


def test_live_socket_explicit_key_list_is_additive_to_vertex_auto_preserve(failures: list[str]) -> None:
    # Pins the precedence between the explicit-opt-in key list
    # (CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS) and the Vertex/Bedrock
    # auto-preserve introduced for #3641 / #3638: the key list adds entries
    # to preservation, it does NOT exclude keys from auto-preserve.
    inherited = {
        "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV": "1",
        "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS": "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY": "explicitly-listed-key-must-survive",
        "CLAUDE_CODE_USE_VERTEX": "1",
        "ANTHROPIC_MODEL": "claude-sonnet-4-5@20250929",
    }
    code, auth_env, _, stderr = run_wrapper_auth_env(
        argv=["hello"],
        inherited_env=inherited,
    )
    expect(code == 0, f"additive list: wrapper exited {code}: {stderr}", failures)
    expect(
        auth_env.get("ANTHROPIC_API_KEY") == "explicitly-listed-key-must-survive",
        f"additive list: expected listed ANTHROPIC_API_KEY preserved, got {auth_env.get('ANTHROPIC_API_KEY')!r}",
        failures,
    )
    expect(
        auth_env.get("CLAUDE_CODE_USE_VERTEX") == "1",
        f"additive list: expected CLAUDE_CODE_USE_VERTEX auto-preserved despite not being in the explicit list, got {auth_env.get('CLAUDE_CODE_USE_VERTEX')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_MODEL") == "claude-sonnet-4-5@20250929",
        f"additive list: expected ANTHROPIC_MODEL auto-preserved (Vertex truthy) despite not being in the explicit list, got {auth_env.get('ANTHROPIC_MODEL')!r}",
        failures,
    )


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
    test_live_socket_merges_user_settings_into_hooks(failures)
    test_live_socket_merges_inline_settings_form(failures)
    test_live_socket_repeated_settings_user_value_wins_conflict(failures)
    test_live_socket_user_nonobject_hooks_does_not_drop_cmux_hooks(failures)
    test_live_socket_invalid_settings_warns_and_falls_back(failures)
    test_live_socket_merges_settings_file_form(failures)
    test_live_socket_empty_settings_warns_instead_of_silent_drop(failures)
    test_plain_claude_launch_argv_has_no_empty_argument(failures)
    test_command_like_invocations_bypass_hook_injection(failures)
    test_passthrough_flags_bypass_hook_injection(failures)
    test_agents_subcommand_removes_cmux_terminal_fingerprint(failures)
    test_hooks_disabled_preserves_cmux_terminal_env_for_custom_hooks(failures)
    test_live_socket_preserves_third_party_claude_auth_for_fresh_launch(failures)
    test_hooks_disabled_clears_stale_auth_selection_before_passthrough(failures)
    test_live_socket_normalizes_subrouter_claude_config_dir(failures)
    test_live_socket_resume_self_heals_mismatched_claude_config_dir(failures)
    test_live_socket_resume_self_heals_bare_legacy_subrouter_config_dir(failures)
    test_stale_socket_resume_self_heals_mismatched_claude_config_dir(failures)
    test_stale_socket_resume_self_heals_after_value_option(failures)
    test_plain_terminal_resume_does_not_self_heal_mismatched_claude_config_dir(failures)
    test_live_socket_resume_after_unlisted_value_option_does_not_inject_session_id(failures)
    test_live_socket_resume_after_prompt_text_does_not_inject_session_id(failures)
    test_live_socket_resume_self_heals_nested_claude_transcript_config_dir(failures)
    test_live_socket_resume_keeps_correct_claude_config_dir(failures)
    test_live_socket_resume_self_heal_ignores_prompt_text_after_double_dash(failures)
    test_live_socket_preserves_claude_auth_for_resume_launch(failures)
    test_live_socket_preserved_claude_config_dir_skips_resume_self_heal(failures)
    test_live_socket_preserves_only_listed_claude_auth_keys(failures)
    test_live_socket_auto_preserves_vertex_auth_when_truthy(failures)
    test_live_socket_auto_preserves_bedrock_auth_when_truthy(failures)
    test_live_socket_does_not_auto_preserve_when_all_backends_are_falsy(failures)
    test_live_socket_preserves_plain_anthropic_model_on_default_path(failures)
    test_live_socket_strips_backend_qualified_model_on_default_path(failures)
    test_live_socket_auto_preserve_accepts_all_documented_truthy_variants(failures)
    test_live_socket_explicit_key_list_is_additive_to_vertex_auto_preserve(failures)
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
