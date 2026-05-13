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
    shadow_python3: bool = False,
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
        if shadow_python3:
            make_executable(
                wrapper_dir / "python3",
                """#!/usr/bin/env bash
exit 127
""",
            )

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

        wrapper = wrapper_dir / "claude"
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


def run_wrapper_background_child_spawn(
    *,
    child_args: list[str] | None = None,
    child_command: str | None = None,
    child_node_options: str | None = None,
    launch_method: str = "spawnSync",
) -> tuple[int, list[str], list[str], str, str, str, str, str, str]:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-bg-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        child_dir = tmp / "child-bin"
        bundled_dir = tmp / "bundled cli"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)
        child_dir.mkdir(parents=True, exist_ok=True)
        bundled_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "claude"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        parent_args_log = tmp / "parent-args.log"
        child_args_log = tmp / "child-args.log"
        child_node_options_env_log = tmp / "child-node-options-env.log"
        child_runtime_node_options_log = tmp / "child-runtime-node-options.log"
        child_cmux_pid_log = tmp / "child-cmux-pid.log"
        child_launch_argv_b64_log = tmp / "child-launch-argv-b64.log"
        execfile_callback_log = tmp / "execfile-callback.log"
        socket_path = str(tmp / "cmux.sock")

        make_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "agents" ]]; then
  : > "$FAKE_PARENT_ARGS_LOG"
  for arg in "$@"; do
    printf '%s\\n' "$arg" >> "$FAKE_PARENT_ARGS_LOG"
  done
  exec node "$FAKE_PARENT_NODE_SCRIPT" "$@"
fi
: > "$FAKE_CHILD_ARGS_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_CHILD_ARGS_LOG"
done
printf '%s\\n' "${NODE_OPTIONS-__UNSET__}" > "$FAKE_CHILD_NODE_OPTIONS_ENV_LOG"
exec node "$FAKE_CHILD_NODE_SCRIPT" "$@"
""",
        )
        make_executable(
            real_dir / "claude-parent.js",
            """#!/usr/bin/env node
const fs = require("node:fs");
const { exec, execFile, execSync, spawnSync } = require("node:child_process");
const childCommand = process.env.FAKE_CHILD_COMMAND || process.env.FAKE_CHILD_CLAUDE;
const childArgs = process.env.FAKE_CHILD_ARGS_JSON
  ? JSON.parse(process.env.FAKE_CHILD_ARGS_JSON)
  : ["--session-id", "agent-session-123", "--agent", "claude"];
const childEnv = { ...process.env };
if (process.env.FAKE_CHILD_NODE_OPTIONS !== undefined) {
  childEnv.NODE_OPTIONS = process.env.FAKE_CHILD_NODE_OPTIONS;
}

function shellQuote(value) {
  const stringValue = String(value);
  if (stringValue === "") {
    return "''";
  }
  if (/^[A-Za-z0-9_/:.,@%+=-]+$/.test(stringValue)) {
    return stringValue;
  }
  return "'" + stringValue.replace(/'/g, "'\"'\"'") + "'";
}

function childShellCommand() {
  return [childCommand, ...childArgs].map(shellQuote).join(" ");
}

if (process.env.FAKE_CHILD_LAUNCH_METHOD === "execCallback") {
  exec(childShellCommand(), { env: childEnv }, (error, stdout, stderr) => {
    fs.writeFileSync(process.env.FAKE_EXECFILE_CALLBACK_LOG, "called\\n", "utf8");
    if (error) {
      process.stderr.write(stderr ?? error.message);
      process.exitCode = error.code || 1;
    }
  });
} else if (process.env.FAKE_CHILD_LAUNCH_METHOD === "execSync") {
  try {
    execSync(childShellCommand(), {
      encoding: "utf8",
      env: childEnv,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (error) {
    process.stderr.write(error.stderr ?? error.message);
    process.exit(error.status ?? 1);
  }
} else if (process.env.FAKE_CHILD_LAUNCH_METHOD === "execFileCallback") {
  execFile(childCommand, childArgs, (error, stdout, stderr) => {
    fs.writeFileSync(process.env.FAKE_EXECFILE_CALLBACK_LOG, "called\\n", "utf8");
    if (error) {
      process.stderr.write(stderr ?? error.message);
      process.exitCode = error.code || 1;
    }
  });
} else if (process.env.FAKE_CHILD_LAUNCH_METHOD === "execFileUndefinedOptions") {
  execFile(childCommand, undefined, { env: childEnv }, (error, stdout, stderr) => {
    fs.writeFileSync(process.env.FAKE_EXECFILE_CALLBACK_LOG, "called\\n", "utf8");
    if (error) {
      process.stderr.write(stderr ?? error.message);
      process.exitCode = error.code || 1;
    }
  });
} else {
  let child;
  if (process.env.FAKE_CHILD_LAUNCH_METHOD === "spawnSyncUndefinedOptions") {
    child = spawnSync(childCommand, undefined, {
      encoding: "utf8",
      env: childEnv,
    });
  } else {
    child = spawnSync(
      childCommand,
      childArgs,
      {
        encoding: "utf8",
        env: childEnv,
      },
    );
  }
  if (child.error) {
    console.error(child.error.message);
    process.exit(1);
  }
  if ((child.status ?? 0) !== 0) {
    process.stderr.write(child.stderr ?? "");
    process.exit(child.status ?? 1);
  }
}
""",
        )
        make_executable(
            child_dir / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_CHILD_ARGS_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_CHILD_ARGS_LOG"
done
printf '%s\\n' "${NODE_OPTIONS-__UNSET__}" > "$FAKE_CHILD_NODE_OPTIONS_ENV_LOG"
exec node "$FAKE_CHILD_NODE_SCRIPT" "$@"
""",
        )
        make_executable(
            child_dir / "claude-child.js",
            """#!/usr/bin/env node
const fs = require("node:fs");
fs.writeFileSync(
  process.env.FAKE_CHILD_RUNTIME_NODE_OPTIONS_LOG,
  `${process.env.NODE_OPTIONS ?? "__UNSET__"}\\n`,
  "utf8",
);
fs.writeFileSync(
  process.env.FAKE_CHILD_CMUX_PID_LOG,
  `${process.env.CMUX_CLAUDE_PID ?? "__UNSET__"}\\n`,
  "utf8",
);
fs.writeFileSync(
  process.env.FAKE_CHILD_LAUNCH_ARGV_B64_LOG,
  `${process.env.CMUX_AGENT_LAUNCH_ARGV_B64 ?? "__UNSET__"}\\n`,
  "utf8",
);
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
        bundled_cli_path = bundled_dir / "cmux"
        make_executable(
            bundled_cli_path,
            """#!/usr/bin/env bash
exit 0
""",
        )

        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            test_socket.bind(socket_path)
            env = os.environ.copy()
            env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
            env["CMUX_SURFACE_ID"] = "surface:test"
            env["CMUX_SOCKET_PATH"] = socket_path
            env["CMUX_BUNDLED_CLI_PATH"] = str(bundled_cli_path)
            env["FAKE_PARENT_ARGS_LOG"] = str(parent_args_log)
            env["FAKE_PARENT_NODE_SCRIPT"] = str(real_dir / "claude-parent.js")
            env["FAKE_CHILD_CLAUDE"] = str(child_dir / "claude")
            env["FAKE_CHILD_COMMAND"] = child_command or str(child_dir / "claude")
            env["FAKE_CHILD_ARGS_LOG"] = str(child_args_log)
            env["FAKE_CHILD_NODE_OPTIONS_ENV_LOG"] = str(child_node_options_env_log)
            env["FAKE_CHILD_RUNTIME_NODE_OPTIONS_LOG"] = str(child_runtime_node_options_log)
            env["FAKE_CHILD_CMUX_PID_LOG"] = str(child_cmux_pid_log)
            env["FAKE_CHILD_LAUNCH_ARGV_B64_LOG"] = str(child_launch_argv_b64_log)
            env["FAKE_CHILD_NODE_SCRIPT"] = str(child_dir / "claude-child.js")
            env["FAKE_CHILD_LAUNCH_METHOD"] = launch_method
            env["FAKE_EXECFILE_CALLBACK_LOG"] = str(execfile_callback_log)
            env["CLAUDECODE"] = "nested-session-sentinel"
            if child_args is not None:
                env["FAKE_CHILD_ARGS_JSON"] = json.dumps(child_args)
            else:
                env.pop("FAKE_CHILD_ARGS_JSON", None)
            if child_node_options is not None:
                env["FAKE_CHILD_NODE_OPTIONS"] = child_node_options
            else:
                env.pop("FAKE_CHILD_NODE_OPTIONS", None)
            env.pop("NODE_OPTIONS", None)
            env.pop("CMUX_CLAUDE_HOOKS_DISABLED", None)

            proc = subprocess.run(
                ["claude", "agents"],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            test_socket.close()

        child_node_options_env = read_lines(child_node_options_env_log)
        child_runtime_node_options = read_lines(child_runtime_node_options_log)
        child_cmux_pid = read_lines(child_cmux_pid_log)
        child_launch_argv_b64 = read_lines(child_launch_argv_b64_log)
        execfile_callback = read_lines(execfile_callback_log)
        return (
            proc.returncode,
            read_lines(parent_args_log),
            read_lines(child_args_log),
            child_node_options_env[0] if child_node_options_env else "",
            child_runtime_node_options[0] if child_runtime_node_options else "",
            child_cmux_pid[0] if child_cmux_pid else "",
            child_launch_argv_b64[0] if child_launch_argv_b64 else "",
            execfile_callback[0] if execfile_callback else "",
            proc.stderr.strip(),
        )


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

    env_only_value_options = [
        ("development channel", ["--dangerously-load-development-channels", "beta", "agents"]),
        ("fork session", ["--fork-session", "fork-123", "agents"]),
        ("from pr", ["--from-pr", "3887", "agents"]),
        ("from pr inline", ["--from-pr=3887", "agents"]),
        ("resume", ["--resume", "session-123", "agents"]),
        ("short resume", ["-r", "session-123", "agents"]),
        ("session id", ["--session-id", "session-123", "agents"]),
        ("session id inline", ["--session-id=session-123", "agents"]),
        ("teammate mode", ["--teammate-mode", "review", "agents"]),
        ("tmux", ["--tmux", "pane:%1", "agents"]),
        ("worktree", ["--worktree", "feature-worktree", "agents"]),
        ("worktree inline", ["--worktree=feature-worktree", "agents"]),
        ("short worktree", ["-w", "feature-worktree", "agents"]),
        ("short worktree inline", ["-w=feature-worktree", "agents"]),
        ("debug flag", ["--debug", "agents"]),
        ("debug value", ["--debug", "verbose", "agents"]),
        ("debug flag daemon", ["--debug", "daemon", "run", "--origin", "transient"]),
    ]
    for label, argv in env_only_value_options:
        code, real_argv, _, stderr, _, node_options, runtime_node_options, _, _, _ = run_wrapper(
            socket_state="live",
            argv=argv,
        )
        expect(code == 0, f"{label} agents passthrough: wrapper exited {code}: {stderr}", failures)
        expect(real_argv == argv, f"{label} agents passthrough: expected raw argv, got {real_argv}", failures)
        expect(real_argv.count("--settings") == argv.count("--settings"), f"{label} agents passthrough: expected no injected --settings, got {real_argv}", failures)
        expect(real_argv.count("--session-id") == argv.count("--session-id"), f"{label} agents passthrough: expected no injected --session-id, got {real_argv}", failures)
        expect(
            "--require=" in node_options and "--max-old-space-size=4096" in node_options,
            f"{label} agents passthrough: expected env-only preload NODE_OPTIONS, got {node_options!r}",
            failures,
        )
        expect(
            runtime_node_options == "__UNSET__",
            f"{label} agents passthrough: expected runtime NODE_OPTIONS restored, got {runtime_node_options!r}",
            failures,
        )


def test_foreground_claude_settings_detection_parses_hooks_json(failures: list[str]) -> None:
    existing_cmux_settings = json.dumps(
        {
            "other": {"kept": True},
            "hooks": {
                "Stop": [
                    {
                        "hooks": [
                            {
                                "command": "cmux hooks feed --source claude",
                                "type": "command",
                            }
                        ],
                        "matcher": "",
                    }
                ]
            },
        },
        indent=2,
        sort_keys=True,
    )
    argv = ["--settings", existing_cmux_settings, "--print", "hello"]
    code, real_argv, _, stderr, _, _, _, _, _, _ = run_wrapper(
        socket_state="live",
        argv=argv,
    )
    expect(code == 0, f"foreground settings parse: wrapper exited {code}: {stderr}", failures)
    expect(real_argv.count("--settings") == 1, f"foreground settings parse: expected existing cmux settings to dedupe injection, got {real_argv}", failures)
    if "--settings" in real_argv:
        settings_index = real_argv.index("--settings")
        expect(
            settings_index + 1 < len(real_argv) and real_argv[settings_index + 1] == existing_cmux_settings,
            f"foreground settings parse: expected original settings payload preserved, got {real_argv}",
            failures,
        )
    expect("--session-id" in real_argv, f"foreground settings parse: expected session id injection, got {real_argv}", failures)
    expect(real_argv[-len(argv):] == argv, f"foreground settings parse: expected original args preserved, got {real_argv}", failures)


def test_foreground_claude_settings_detection_does_not_require_python(failures: list[str]) -> None:
    existing_cmux_settings = json.dumps(
        {
            "hooks": {
                "PermissionRequest": [
                    {
                        "hooks": [
                            {
                                "command": "cmux hooks feed --source claude",
                                "type": "command",
                            }
                        ],
                        "matcher": "",
                    }
                ]
            }
        },
        indent=2,
        sort_keys=True,
    )
    argv = ["--settings", existing_cmux_settings, "--print", "hello"]
    code, real_argv, _, stderr, _, _, _, _, _, _ = run_wrapper(
        socket_state="live",
        argv=argv,
        shadow_python3=True,
    )
    expect(code == 0, f"foreground settings parse without python: wrapper exited {code}: {stderr}", failures)
    expect(real_argv.count("--settings") == 1, f"foreground settings parse without python: expected existing cmux settings to dedupe injection, got {real_argv}", failures)
    expect("--session-id" in real_argv, f"foreground settings parse without python: expected session id injection, got {real_argv}", failures)
    expect(real_argv[-len(argv):] == argv, f"foreground settings parse without python: expected original args preserved, got {real_argv}", failures)


def test_background_claude_child_launches_inherit_cmux_hooks(failures: list[str]) -> None:
    code, parent_argv, child_argv, child_node_options_env, child_runtime_node_options, child_cmux_pid, child_launch_argv_b64, _, stderr = run_wrapper_background_child_spawn()
    expect(code == 0, f"background child: wrapper exited {code}: {stderr}", failures)
    expect(parent_argv == ["agents"], f"background child: expected parent agents command to stay raw, got {parent_argv}", failures)
    has_settings = "--settings" in child_argv
    has_session_id = "--session-id" in child_argv
    expect(has_settings, f"background child: expected child claude launch to receive --settings, got {child_argv}", failures)
    expect(has_session_id, f"background child: expected child session args preserved, got {child_argv}", failures)
    if has_settings and has_session_id:
        expect(
            child_argv.index("--settings") < child_argv.index("--session-id"),
            f"background child: expected injected settings before child session args, got {child_argv}",
            failures,
        )

    settings = parse_settings_arg(child_argv)
    hooks = settings.get("hooks", {})
    expect("SessionStart" in hooks, f"background child: expected SessionStart hook in child settings, got {settings}", failures)
    expect(
        any(
            h.get("command") == '"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks feed --source claude'
            for group in hooks.get("PermissionRequest", [])
            for h in group.get("hooks", [])
        ),
        f"background child: expected PermissionRequest feed bridge in child settings, got {settings}",
        failures,
    )
    expect(
        "--require=" in child_node_options_env and "--max-old-space-size=4096" in child_node_options_env,
        f"background child: expected child Claude process to inherit cmux preload NODE_OPTIONS, got {child_node_options_env!r}",
        failures,
    )
    expect(
        child_runtime_node_options == "__UNSET__",
        f"background child: expected child runtime NODE_OPTIONS restored, got {child_runtime_node_options!r}",
        failures,
    )
    expect(
        child_cmux_pid.isdigit() and int(child_cmux_pid) > 0,
        f"background child: expected child preload to reset CMUX_CLAUDE_PID to its own pid, got {child_cmux_pid!r}",
        failures,
    )
    launch_argv = decode_nul_argv(child_launch_argv_b64)
    expect(bool(launch_argv), f"background child: expected non-empty launch argv, got {launch_argv}", failures)
    if launch_argv:
        expect(launch_argv[0].endswith("/child-bin/claude"), f"background child: expected child executable in launch argv, got {launch_argv}", failures)
    expect("--agent" in launch_argv, f"background child: expected child agent flag in launch argv, got {launch_argv}", failures)


def test_background_claude_child_through_wrapper_deduplicates_injection(failures: list[str]) -> None:
    code, _, child_argv, child_node_options_env, child_runtime_node_options, _, _, _, stderr = run_wrapper_background_child_spawn(
        child_command="claude",
    )
    expect(code == 0, f"background wrapper child: wrapper exited {code}: {stderr}", failures)
    expect(
        child_argv.count("--settings") == 1,
        f"background wrapper child: expected exactly one cmux settings payload, got {child_argv}",
        failures,
    )
    expect(
        child_argv.count("--session-id") == 1,
        f"background wrapper child: expected original child session id to be preserved once, got {child_argv}",
        failures,
    )
    expect(
        child_node_options_env.count("--require=") == 1,
        f"background wrapper child: expected exactly one cmux preload, got {child_node_options_env!r}",
        failures,
    )
    expect(
        child_node_options_env.count("--max-old-space-size=4096") == 1,
        f"background wrapper child: expected exactly one cmux heap cap, got {child_node_options_env!r}",
        failures,
    )
    expect(
        child_runtime_node_options == "__UNSET__",
        f"background wrapper child: expected runtime NODE_OPTIONS restored, got {child_runtime_node_options!r}",
        failures,
    )


def test_background_claude_child_preserves_explicit_node_options_override(failures: list[str]) -> None:
    child_override = "--trace-warnings"
    code, _, child_argv, child_node_options_env, child_runtime_node_options, _, _, _, stderr = run_wrapper_background_child_spawn(
        child_node_options=child_override,
    )
    expect(code == 0, f"background child override: wrapper exited {code}: {stderr}", failures)
    expect("--settings" in child_argv, f"background child override: expected child claude launch to receive --settings, got {child_argv}", failures)
    expect(
        "--require=" in child_node_options_env
        and "--max-old-space-size=4096" in child_node_options_env
        and child_override in child_node_options_env,
        f"background child override: expected preload plus child NODE_OPTIONS override, got {child_node_options_env!r}",
        failures,
    )
    expect(
        child_runtime_node_options == child_override,
        f"background child override: expected runtime NODE_OPTIONS to restore child override, got {child_runtime_node_options!r}",
        failures,
    )


def test_background_claude_child_preserves_options_when_args_omitted(failures: list[str]) -> None:
    child_override = "--trace-warnings"
    cases = [
        ("spawnSync undefined args", "spawnSyncUndefinedOptions"),
        ("execFile undefined args", "execFileUndefinedOptions"),
    ]
    for label, launch_method in cases:
        code, _, child_argv, child_node_options_env, child_runtime_node_options, _, _, execfile_callback, stderr = run_wrapper_background_child_spawn(
            child_node_options=child_override,
            launch_method=launch_method,
        )
        expect(code == 0, f"background {label}: wrapper exited {code}: {stderr}", failures)
        expect("--settings" in child_argv, f"background {label}: expected child claude launch to receive --settings, got {child_argv}", failures)
        expect(
            child_override in child_node_options_env,
            f"background {label}: expected explicit child NODE_OPTIONS override preserved in env, got {child_node_options_env!r}",
            failures,
        )
        expect(
            child_runtime_node_options == child_override,
            f"background {label}: expected runtime NODE_OPTIONS to restore child override, got {child_runtime_node_options!r}",
            failures,
        )
        if launch_method.startswith("execFile"):
            expect(execfile_callback == "called", f"background {label}: expected execFile callback to run, got {execfile_callback!r}", failures)


def test_background_claude_exec_file_launch_preserves_callback(failures: list[str]) -> None:
    code, _, child_argv, _, _, _, _, execfile_callback, stderr = run_wrapper_background_child_spawn(
        launch_method="execFileCallback",
    )
    expect(code == 0, f"background execFile: wrapper exited {code}: {stderr}", failures)
    expect("--settings" in child_argv, f"background execFile: expected child claude launch to receive --settings, got {child_argv}", failures)
    expect(execfile_callback == "called", f"background execFile: expected execFile callback to run, got {execfile_callback!r}", failures)


def test_background_claude_exec_shell_launches_inherit_cmux_hooks(failures: list[str]) -> None:
    cases = [
        ("exec callback", "execCallback"),
        ("exec sync", "execSync"),
    ]
    for label, launch_method in cases:
        code, _, child_argv, child_node_options_env, child_runtime_node_options, _, child_launch_argv_b64, execfile_callback, stderr = run_wrapper_background_child_spawn(
            launch_method=launch_method,
        )
        expect(code == 0, f"background {label}: wrapper exited {code}: {stderr}", failures)
        expect("--settings" in child_argv, f"background {label}: expected child claude launch to receive --settings, got {child_argv}", failures)
        expect("--agent" in child_argv, f"background {label}: expected child agent args preserved, got {child_argv}", failures)
        expect(
            "--require=" in child_node_options_env and "--max-old-space-size=4096" in child_node_options_env,
            f"background {label}: expected preload NODE_OPTIONS, got {child_node_options_env!r}",
            failures,
        )
        expect(
            child_runtime_node_options == "__UNSET__",
            f"background {label}: expected runtime NODE_OPTIONS restored, got {child_runtime_node_options!r}",
            failures,
        )
        launch_argv = decode_nul_argv(child_launch_argv_b64)
        expect(bool(launch_argv), f"background {label}: expected non-empty launch argv, got {launch_argv}", failures)
        if launch_argv:
            expect(launch_argv[0].endswith("/child-bin/claude"), f"background {label}: expected child executable in launch argv, got {launch_argv}", failures)
        if launch_method == "execCallback":
            expect(execfile_callback == "called", f"background {label}: expected exec callback to run, got {execfile_callback!r}", failures)


def test_background_claude_child_settings_detection_parses_hooks_json(failures: list[str]) -> None:
    user_settings = json.dumps(
        {
            "description": "This value mentions hooks claude but is not a hook command.",
            "hooks": {
                "SessionStart": [
                    {
                        "matcher": "",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "echo not-cmux",
                            }
                        ],
                    }
                ]
            },
        },
        separators=(",", ":"),
    )
    child_args = ["--settings", user_settings, "--session-id", "agent-session-123", "--agent", "claude"]
    code, _, child_argv, _, _, _, _, _, stderr = run_wrapper_background_child_spawn(child_args=child_args)
    expect(code == 0, f"background settings parse: wrapper exited {code}: {stderr}", failures)
    expect(
        child_argv.count("--settings") == 2,
        f"background settings parse: expected cmux settings plus user settings, got {child_argv}",
        failures,
    )
    settings = parse_settings_arg(child_argv)
    permission_request_hooks = settings.get("hooks", {}).get("PermissionRequest", [{}])[0].get("hooks", [])
    expect(
        any(h.get("command") == '"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks feed --source claude' for h in permission_request_hooks),
        f"background settings parse: expected parsed cmux settings to be injected, got {settings}",
        failures,
    )


def test_background_claude_daemon_child_gets_env_without_settings(failures: list[str]) -> None:
    child_args = ["daemon", "run", "--origin", "transient"]
    code, _, child_argv, child_node_options_env, child_runtime_node_options, child_cmux_pid, child_launch_argv_b64, _, stderr = run_wrapper_background_child_spawn(
        child_args=child_args,
    )
    expect(code == 0, f"background daemon child: wrapper exited {code}: {stderr}", failures)
    expect(child_argv == child_args, f"background daemon child: expected daemon args to stay raw, got {child_argv}", failures)
    expect("--settings" not in child_argv, f"background daemon child: expected no --settings injection, got {child_argv}", failures)
    expect(
        "--require=" in child_node_options_env and "--max-old-space-size=4096" in child_node_options_env,
        f"background daemon child: expected preload NODE_OPTIONS, got {child_node_options_env!r}",
        failures,
    )
    expect(
        child_runtime_node_options == "__UNSET__",
        f"background daemon child: expected runtime NODE_OPTIONS restored, got {child_runtime_node_options!r}",
        failures,
    )
    expect(
        child_cmux_pid.isdigit() and int(child_cmux_pid) > 0,
        f"background daemon child: expected child preload to reset CMUX_CLAUDE_PID to its own pid, got {child_cmux_pid!r}",
        failures,
    )
    launch_argv = decode_nul_argv(child_launch_argv_b64)
    expect(bool(launch_argv), f"background daemon child: expected non-empty launch argv, got {launch_argv}", failures)
    if launch_argv:
        expect(launch_argv[0].endswith("/child-bin/claude"), f"background daemon child: expected child executable in launch argv, got {launch_argv}", failures)
    expect(launch_argv[1:] == child_args, f"background daemon child: expected daemon launch argv recorded, got {launch_argv}", failures)


def test_background_claude_env_only_subcommands_after_options_get_env_without_settings(failures: list[str]) -> None:
    cases = [
        ("short model agents", ["-m", "sonnet", "agents"]),
        ("debug flag agents", ["--debug", "agents"]),
        ("debug value agents", ["--debug", "verbose", "agents"]),
        ("debug flag daemon", ["--debug", "daemon", "run", "--origin", "transient"]),
    ]
    for label, child_args in cases:
        code, _, child_argv, child_node_options_env, child_runtime_node_options, child_cmux_pid, child_launch_argv_b64, _, stderr = run_wrapper_background_child_spawn(
            child_args=child_args,
        )
        expect(code == 0, f"background {label}: wrapper exited {code}: {stderr}", failures)
        expect(child_argv == child_args, f"background {label}: expected env-only args to stay raw, got {child_argv}", failures)
        expect("--settings" not in child_argv, f"background {label}: expected no --settings injection, got {child_argv}", failures)
        expect(
            "--require=" in child_node_options_env and "--max-old-space-size=4096" in child_node_options_env,
            f"background {label}: expected preload NODE_OPTIONS, got {child_node_options_env!r}",
            failures,
        )
        expect(
            child_runtime_node_options == "__UNSET__",
            f"background {label}: expected runtime NODE_OPTIONS restored, got {child_runtime_node_options!r}",
            failures,
        )
        expect(
            child_cmux_pid.isdigit() and int(child_cmux_pid) > 0,
            f"background {label}: expected child preload to reset CMUX_CLAUDE_PID to its own pid, got {child_cmux_pid!r}",
            failures,
        )
        launch_argv = decode_nul_argv(child_launch_argv_b64)
        expect(bool(launch_argv), f"background {label}: expected non-empty launch argv, got {launch_argv}", failures)
        if launch_argv:
            expect(launch_argv[0].endswith("/child-bin/claude"), f"background {label}: expected child executable in launch argv, got {launch_argv}", failures)
        expect(launch_argv[1:] == child_args, f"background {label}: expected env-only launch argv recorded, got {launch_argv}", failures)


def test_background_claude_wrapper_exec_env_only_subcommands_after_value_options(failures: list[str]) -> None:
    cases = [
        ("session id agents", ["--session-id", "agent-session-123", "agents"]),
        ("session id inline agents", ["--session-id=agent-session-123", "agents"]),
        ("resume agents", ["--resume", "resume-session-123", "agents"]),
        ("short resume agents", ["-r", "resume-session-123", "agents"]),
        ("worktree agents", ["--worktree", "feature-worktree", "agents"]),
        ("short worktree agents", ["-w", "feature-worktree", "agents"]),
        ("from pr daemon", ["--from-pr", "3887", "daemon", "run", "--origin", "transient"]),
    ]
    launch_methods = ["execCallback", "execSync"]
    for label, child_args in cases:
        for launch_method in launch_methods:
            code, _, child_argv, child_node_options_env, child_runtime_node_options, child_cmux_pid, child_launch_argv_b64, execfile_callback, stderr = run_wrapper_background_child_spawn(
                child_args=child_args,
                child_command="claude",
                launch_method=launch_method,
            )
            case_label = f"{label} via {launch_method}"
            expect(code == 0, f"background wrapper exec {case_label}: wrapper exited {code}: {stderr}", failures)
            expect(child_argv == child_args, f"background wrapper exec {case_label}: expected env-only args to stay raw, got {child_argv}", failures)
            expect("--settings" not in child_argv, f"background wrapper exec {case_label}: expected no --settings injection, got {child_argv}", failures)
            expect(
                "--require=" in child_node_options_env and "--max-old-space-size=4096" in child_node_options_env,
                f"background wrapper exec {case_label}: expected preload NODE_OPTIONS, got {child_node_options_env!r}",
                failures,
            )
            expect(
                child_runtime_node_options == "__UNSET__",
                f"background wrapper exec {case_label}: expected runtime NODE_OPTIONS restored, got {child_runtime_node_options!r}",
                failures,
            )
            expect(
                child_cmux_pid.isdigit() and int(child_cmux_pid) > 0,
                f"background wrapper exec {case_label}: expected child preload to reset CMUX_CLAUDE_PID to its own pid, got {child_cmux_pid!r}",
                failures,
            )
            launch_argv = decode_nul_argv(child_launch_argv_b64)
            expect(bool(launch_argv), f"background wrapper exec {case_label}: expected non-empty launch argv, got {launch_argv}", failures)
            if launch_argv:
                expect(launch_argv[0].endswith("/real-bin/claude"), f"background wrapper exec {case_label}: expected real executable in launch argv, got {launch_argv}", failures)
            expect(launch_argv[1:] == child_args, f"background wrapper exec {case_label}: expected env-only launch argv recorded, got {launch_argv}", failures)
            if launch_method == "execCallback":
                expect(execfile_callback == "called", f"background wrapper exec {case_label}: expected exec callback to run, got {execfile_callback!r}", failures)


def test_background_claude_child_short_model_value_does_not_skip_hook_injection(failures: list[str]) -> None:
    child_args = ["-m", "config", "--session-id", "agent-session-123", "--agent", "claude"]
    code, _, child_argv, child_node_options_env, child_runtime_node_options, _, _, _, stderr = run_wrapper_background_child_spawn(
        child_args=child_args,
    )
    expect(code == 0, f"background short model child: wrapper exited {code}: {stderr}", failures)
    has_settings = "--settings" in child_argv
    has_model_flag = "-m" in child_argv
    expect(has_settings, f"background short model child: expected child claude launch to receive --settings, got {child_argv}", failures)
    expect(has_model_flag, f"background short model child: expected original model flag preserved, got {child_argv}", failures)
    if has_settings and has_model_flag:
        expect(
            child_argv.index("--settings") < child_argv.index("-m"),
            f"background short model child: expected injected settings before original args, got {child_argv}",
            failures,
        )
    expect(
        child_argv[-len(child_args):] == child_args,
        f"background short model child: expected original args preserved, got {child_argv}",
        failures,
    )
    expect(
        "--require=" in child_node_options_env and "--max-old-space-size=4096" in child_node_options_env,
        f"background short model child: expected preload NODE_OPTIONS, got {child_node_options_env!r}",
        failures,
    )
    expect(
        child_runtime_node_options == "__UNSET__",
        f"background short model child: expected runtime NODE_OPTIONS restored, got {child_runtime_node_options!r}",
        failures,
    )


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
    scenarios = [
        ("agents env probe", {}),
        ("agents hooks-disabled env probe", {"hooks_disabled": True}),
    ]
    for label, kwargs in scenarios:
        code, observed_env, real_argv, stderr, expected_keys = run_wrapper_terminal_env_probe(["agents"], **kwargs)
        expect(code == 0, f"{label}: wrapper exited {code}: {stderr}", failures)
        expect(real_argv == ["agents"], f"{label}: expected raw argv, got {real_argv}", failures)
        expect(
            set(observed_env) == expected_keys,
            f"{label}: expected probed keys {sorted(expected_keys)}, got {sorted(observed_env)}",
            failures,
        )

        for key, value in observed_env.items():
            expect(
                value == "__UNSET__",
                f"{label}: expected {key} unset, got {value!r}",
                failures,
            )


def test_live_socket_preserves_third_party_claude_auth_for_fresh_launch(failures: list[str]) -> None:
    inherited = {
        "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
        "ANTHROPIC_API_KEY": "stale-api-key",
        "ANTHROPIC_AUTH_TOKEN": "third-party-auth-token",
        "ANTHROPIC_BASE_URL": "https://api.example.test",
        "ANTHROPIC_MODEL": "stale-model",
        "ANTHROPIC_SMALL_FAST_MODEL": "stale-small-model",
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
    inherited = {
        "CLAUDE_CODE_USE_VERTEX": "0",
        "CLAUDE_CODE_USE_BEDROCK": "",
        "ANTHROPIC_MODEL": "stale-model",
        "ANTHROPIC_SMALL_FAST_MODEL": "stale-small-model",
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
        f"falsy backends: expected ANTHROPIC_MODEL cleared (no live Vertex/Bedrock backend), got {auth_env.get('ANTHROPIC_MODEL')!r}",
        failures,
    )
    expect(
        auth_env.get("ANTHROPIC_SMALL_FAST_MODEL") == "__UNSET__",
        f"falsy backends: expected ANTHROPIC_SMALL_FAST_MODEL cleared (no live Vertex/Bedrock backend), got {auth_env.get('ANTHROPIC_SMALL_FAST_MODEL')!r}",
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
    test_plain_claude_launch_argv_has_no_empty_argument(failures)
    test_command_like_invocations_bypass_hook_injection(failures)
    test_foreground_claude_settings_detection_parses_hooks_json(failures)
    test_foreground_claude_settings_detection_does_not_require_python(failures)
    test_background_claude_child_launches_inherit_cmux_hooks(failures)
    test_background_claude_child_through_wrapper_deduplicates_injection(failures)
    test_background_claude_child_preserves_explicit_node_options_override(failures)
    test_background_claude_child_preserves_options_when_args_omitted(failures)
    test_background_claude_exec_file_launch_preserves_callback(failures)
    test_background_claude_exec_shell_launches_inherit_cmux_hooks(failures)
    test_background_claude_child_settings_detection_parses_hooks_json(failures)
    test_background_claude_daemon_child_gets_env_without_settings(failures)
    test_background_claude_env_only_subcommands_after_options_get_env_without_settings(failures)
    test_background_claude_wrapper_exec_env_only_subcommands_after_value_options(failures)
    test_background_claude_child_short_model_value_does_not_skip_hook_injection(failures)
    test_passthrough_flags_bypass_hook_injection(failures)
    test_agents_subcommand_removes_cmux_terminal_fingerprint(failures)
    test_live_socket_preserves_third_party_claude_auth_for_fresh_launch(failures)
    test_live_socket_normalizes_subrouter_claude_config_dir(failures)
    test_live_socket_preserves_claude_auth_for_resume_launch(failures)
    test_live_socket_preserves_only_listed_claude_auth_keys(failures)
    test_live_socket_auto_preserves_vertex_auth_when_truthy(failures)
    test_live_socket_auto_preserves_bedrock_auth_when_truthy(failures)
    test_live_socket_does_not_auto_preserve_when_all_backends_are_falsy(failures)
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
