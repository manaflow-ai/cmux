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


def test_live_socket_injects_supported_hooks(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, claudecode, node_options, runtime_node_options, child_node_options, hook_cmux_bin, _ = run_wrapper(
        socket_state="live",
        argv=["hello"],
    )
    expect(code == 0, f"live socket: wrapper exited {code}: {stderr}", failures)
    expect("--settings" in real_argv, f"live socket: missing --settings in args: {real_argv}", failures)
    expect("--session-id" in real_argv, f"live socket: missing --session-id in args: {real_argv}", failures)
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
    hooks = settings.get("hooks", {})
    expected_hooks = {"SessionStart", "Stop", "SessionEnd", "Notification", "UserPromptSubmit", "PreToolUse"}
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
            hook_command == f'"${{CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}}" claude-hook {expected_subcommand}',
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
    test_live_socket_injects_supported_hooks(failures)
    test_plain_claude_launch_argv_has_no_empty_argument(failures)
    test_live_socket_enforces_heap_cap_for_space_separated_flag(failures)
    test_live_socket_tmpdir_failure_skips_node_options_injection(failures)
    test_live_socket_stale_mktemp_literal_does_not_warn(failures)
    test_missing_socket_skips_hook_injection(failures)
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
