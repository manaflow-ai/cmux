#!/usr/bin/env python3
"""Integration coverage for the generated Gajae Code extension and restore binding."""

from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_omp_extension_install import (
    MockCmuxSocket,
    json_rpc_messages,
    make_executable,
    wait_for_text,
)


def decode_launch_argv(raw: str) -> list[str]:
    return [
        value
        for value in base64.b64decode(raw).decode("utf-8").split("\0")
        if value
    ]


def run_hook(
    cli_path: str,
    env: dict[str, str],
    session_id: str,
    previous_session_id: str | None = None,
) -> subprocess.CompletedProcess[str]:
    payload: dict[str, str] = {
        "session_id": session_id,
        "cwd": env["CMUX_AGENT_LAUNCH_CWD"],
        "hook_event_name": "SessionStart",
    }
    if previous_session_id is not None:
        payload["previous_session_id"] = previous_session_id
    return subprocess.run(
        [cli_path, "hooks", "gajae-code", "session-start"],
        input=json.dumps(payload, separators=(",", ":")),
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )


def verify_hook_persistence(cli_path: str, root: Path, base_env: dict[str, str]) -> bool:
    hook_state_dir = root / "hook-state"
    workspace = root / "hook-workspace"
    hook_state_dir.mkdir()
    workspace.mkdir()
    workspace_id = "11111111-1111-1111-1111-111111111111"
    surface_id = "22222222-2222-2222-2222-222222222222"
    first_session_id = "gjc-hook-session-old"
    final_session_id = "gjc-hook-session-new"
    foreign_session_id = "gjc-hook-session-foreign"
    tmux_session = "gajae_code_cmux_restore"
    socket_path = Path("/tmp") / f"cmux-gjc-hook-{os.getpid()}-{time.monotonic_ns()}.sock"
    launch_argv = [
        "/Users/example/.bun/bin/gjc",
        "--resume",
        "stale-session",
        "--credential",
        "account@example.com",
        "--api-key",
        "secret-cli-value",
        "--model",
        "anthropic/claude-sonnet-4-6",
        "--tmux",
        "initial prompt should not persist",
    ]
    hook_env = base_env.copy()
    for key in list(hook_env):
        if key.startswith("GJC_"):
            hook_env.pop(key)
    hook_env.update(
        {
            "PWD": str(workspace),
            "CMUX_SOCKET_PATH": str(socket_path),
            "CMUX_WORKSPACE_ID": workspace_id,
            "CMUX_SURFACE_ID": surface_id,
            "CMUX_AGENT_HOOK_STATE_DIR": str(hook_state_dir),
            "CMUX_AGENT_LAUNCH_KIND": "gajae-code",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": launch_argv[0],
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64.b64encode(
                b"".join(value.encode("utf-8") + b"\0" for value in launch_argv)
            ).decode("ascii"),
            "CMUX_AGENT_LAUNCH_CWD": str(workspace),
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "GJC_CONFIG_DIR": ".custom-gjc",
            "GJC_TMUX_COMMAND": "/opt/homebrew/bin/tmux",
            "GJC_TMUX_SESSION": tmux_session,
            "GJC_TEAM_WORKER": "team/worker-1",
            "GJC_SESSION_ID": "secret-session-id",
            "ANTHROPIC_API_KEY": "secret-env-value",
        }
    )

    with MockCmuxSocket(socket_path, workspace_id=workspace_id, surface_id=surface_id) as server:
        first = run_hook(cli_path, hook_env, first_session_id)
        store_path = hook_state_dir / "gajae-code-hook-sessions.json"
        seeded_store = json.loads(store_path.read_text(encoding="utf-8"))
        now = time.time()
        seeded_store["sessions"][foreign_session_id] = {
            "sessionId": foreign_session_id,
            "workspaceId": "foreign-workspace",
            "surfaceId": "foreign-surface",
            "cwd": str(workspace),
            "startedAt": now,
            "updatedAt": now,
        }
        store_path.write_text(json.dumps(seeded_store), encoding="utf-8")

        second = run_hook(
            cli_path,
            hook_env,
            final_session_id,
            previous_session_id=first_session_id,
        )
        third = run_hook(
            cli_path,
            hook_env,
            final_session_id,
            previous_session_id=foreign_session_id,
        )
        results = [first, second, third]
        if any(result.returncode != 0 or result.stdout != "{}\n" for result in results):
            print("FAIL: Gajae Code session-start persistence command failed")
            for index, result in enumerate(results, start=1):
                print(
                    f"hook {index}={result.returncode} "
                    f"stdout={result.stdout!r} stderr={result.stderr!r}"
                )
            return False
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if len(json_rpc_messages(server.messages(), "surface.resume.set")) >= 3:
                break
            time.sleep(0.05)
        messages = server.messages()

    try:
        store = json.loads(store_path.read_text(encoding="utf-8"))
        sessions = store["sessions"]
        session = sessions[final_session_id]
    except Exception as exc:
        print(f"FAIL: Gajae Code hook store missing final session: {exc}")
        if store_path.exists():
            print(store_path.read_text(encoding="utf-8"))
        return False
    if first_session_id in sessions:
        print(f"FAIL: switched Gajae Code session was not retired: {sessions!r}")
        return False
    if foreign_session_id not in sessions:
        print(f"FAIL: mismatched previous Gajae Code session was retired: {sessions!r}")
        return False

    expected_fields = {
        "sessionId": final_session_id,
        "workspaceId": workspace_id,
        "surfaceId": surface_id,
        "cwd": str(workspace),
    }
    for key, expected in expected_fields.items():
        if session.get(key) != expected:
            print(f"FAIL: Gajae Code session {key} expected {expected!r}, got {session.get(key)!r}")
            return False

    launch_command = session.get("launchCommand")
    if not isinstance(launch_command, dict):
        print(f"FAIL: Gajae Code hook did not persist launch metadata: {session!r}")
        return False
    expected_arguments = [
        launch_argv[0],
        "--model",
        "anthropic/claude-sonnet-4-6",
        "--tmux",
    ]
    if launch_command.get("launcher") != "gajae-code":
        print(f"FAIL: wrong Gajae Code launcher metadata: {launch_command!r}")
        return False
    if launch_command.get("arguments") != expected_arguments:
        print(f"FAIL: unsanitized Gajae Code launch arguments: {launch_command!r}")
        return False
    environment = launch_command.get("environment")
    if not isinstance(environment, dict):
        print(f"FAIL: Gajae Code launch environment missing: {launch_command!r}")
        return False
    expected_environment = {
        "GJC_CONFIG_DIR": ".custom-gjc",
        "GJC_TMUX_COMMAND": "/opt/homebrew/bin/tmux",
        "GJC_TMUX_SESSION": tmux_session,
    }
    for key, expected in expected_environment.items():
        if environment.get(key) != expected:
            print(f"FAIL: Gajae Code restore environment lost {key}: {environment!r}")
            return False
    serialized_session = json.dumps(session, sort_keys=True)
    for forbidden in [
        "secret-cli-value",
        "secret-env-value",
        "secret-session-id",
        "team/worker-1",
        "account@example.com",
    ]:
        if forbidden in serialized_session:
            print(f"FAIL: Gajae Code hook persisted sensitive or worker data {forbidden!r}")
            return False

    resume_sets = json_rpc_messages(messages, "surface.resume.set")
    if len(resume_sets) != 3:
        print(f"FAIL: expected three surface.resume.set calls, saw {messages!r}")
        return False
    params = resume_sets[-1].get("params")
    if not isinstance(params, dict):
        print(f"FAIL: final surface.resume.set missing params: {resume_sets[-1]!r}")
        return False
    if (
        params.get("kind") != "gajae-code"
        or params.get("checkpoint_id") != final_session_id
        or params.get("auto_resume") is not True
    ):
        print(f"FAIL: final Gajae Code resume binding was wrong: {params!r}")
        return False
    command = params.get("command")
    if (
        not isinstance(command, str)
        or "--resume" not in command
        or final_session_id not in command
        or "--tmux" not in command
    ):
        print(f"FAIL: resume binding cannot restore Gajae Code tmux session: {params!r}")
        return False
    return True


def main() -> int:
    bun = shutil.which("bun")
    if bun is None:
        print("SKIP: bun not found")
        return 0
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-gajae-code-extension-") as td:
        root = Path(td)
        home = root / "home"
        home.mkdir()
        agent_dir = root / "gjc-agent"
        env = os.environ.copy()
        env["HOME"] = str(home)
        env["GJC_CODING_AGENT_DIR"] = str(agent_dir)

        install = subprocess.run(
            [cli_path, "hooks", "gjc", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        extension_path = agent_dir / "extensions" / "cmux-gajae-code-session.ts"
        if install.returncode != 0 or not extension_path.exists():
            print("FAIL: Gajae Code extension install failed")
            print(f"exit={install.returncode} stdout={install.stdout!r} stderr={install.stderr!r}")
            return 1
        extension_text = extension_path.read_text(encoding="utf-8")
        if "cmux-gajae-code-session-extension-marker" not in extension_text:
            print(f"FAIL: generated extension marker missing from {extension_path}")
            return 1

        reinstall = subprocess.run(
            [cli_path, "hooks", "gajae-code", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if reinstall.returncode != 0 or "already up to date" not in reinstall.stdout:
            print("FAIL: Gajae Code extension reinstall was not idempotent")
            print(f"exit={reinstall.returncode} stdout={reinstall.stdout!r} stderr={reinstall.stderr!r}")
            return 1

        fake_cmux = root / "fake-cmux"
        fake_args_log = root / "fake-cmux-args.log"
        fake_stdin_log = root / "fake-cmux-stdin.log"
        fake_env_log = root / "fake-cmux-env.log"
        make_executable(
            fake_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CMUX_ARGS_LOG"
payload="$(cat)"
printf '%s\n' "$payload" >> "$FAKE_CMUX_STDIN_LOG"
printf 'kind=%s\tcwd=%s\targv=%s\ttmux=%s\n' \
  "${CMUX_AGENT_LAUNCH_KIND-}" \
  "${CMUX_AGENT_LAUNCH_CWD-}" \
  "${CMUX_AGENT_LAUNCH_ARGV_B64-}" \
  "${GJC_TMUX_SESSION-}" >> "$FAKE_CMUX_ENV_LOG"
if [[ -n "${FAKE_CMUX_FAIL_ONCE_SESSION-}" \
  && "$payload" == *"${FAKE_CMUX_FAIL_ONCE_SESSION}"* \
  && ! -e "$FAKE_CMUX_FAIL_ONCE_FLAG" ]]; then
  : > "$FAKE_CMUX_FAIL_ONCE_FLAG"
  exit 17
fi
""",
        )

        check_env = env.copy()
        check_env.update(
            {
                "CMUX_TEST_GJC_EXTENSION_PATH": str(extension_path),
                "CMUX_SURFACE_ID": "surface-gjc-test",
                "CMUX_GAJAE_CODE_CMUX_BIN": str(fake_cmux),
                "FAKE_CMUX_ARGS_LOG": str(fake_args_log),
                "FAKE_CMUX_STDIN_LOG": str(fake_stdin_log),
                "FAKE_CMUX_ENV_LOG": str(fake_env_log),
                "FAKE_CMUX_FAIL_ONCE_SESSION": "gjc-session-d",
                "FAKE_CMUX_FAIL_ONCE_FLAG": str(root / "fake-cmux-failed-once"),
                "GJC_TMUX_ACTIVE_SESSION": "gajae_code_live_123",
                "CMUX_AGENT_LAUNCH_KIND": "claude",
                "CMUX_AGENT_LAUNCH_ARGV_B64": "inherited-ancestor-capture",
            }
        )
        check_source = """
const extensionPath = process.env.CMUX_TEST_GJC_EXTENSION_PATH;
const mod = await import(extensionPath);
if (typeof mod.default !== "function") throw new Error("missing default export");
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
for (const name of ["session_start", "session_switch", "session_branch", "before_agent_start", "agent_end"]) {
  if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
}
process.argv.splice(
  0,
  process.argv.length,
  "/opt/homebrew/bin/bun",
  "/opt/homebrew/lib/node_modules/@gajae-code/coding-agent/dist/cli.js",
  "--model",
  "anthropic/claude-sonnet-4-6"
);
let sessionId = "gjc-session-a";
const ctx = {
  cwd: "/tmp/gjc-project",
  sessionMetadata: { kind: "main" },
  sessionManager: { getSessionId() { return sessionId; } }
};
await handlers.get("session_start")({}, ctx);
await handlers.get("before_agent_start")({ prompt: "hello gjc" }, ctx);
await handlers.get("agent_end")({
  messages: [
    { role: "user", content: "hello gjc" },
    { role: "assistant", content: [{ type: "text", text: "done" }] }
  ],
  stopReason: "completed"
}, ctx);
sessionId = "gjc-session-b";
await handlers.get("session_switch")({ reason: "resume" }, ctx);
sessionId = "gjc-session-c";
await handlers.get("session_branch")({ previousSessionFile: "old.jsonl" }, ctx);
sessionId = "gjc-session-d";
await handlers.get("session_switch")({ reason: "resume" }, ctx);
await handlers.get("session_switch")({ reason: "retry" }, ctx);
await handlers.get("session_start")({}, {
  cwd: ctx.cwd,
  sessionManager: ctx.sessionManager
});
await handlers.get("session_start")({}, { ...ctx, sessionMetadata: { kind: "sub" } });
process.env.GJC_TEAM_WORKER = "team/worker-1";
await handlers.get("session_start")({}, ctx);
delete process.env.GJC_TEAM_WORKER;
"""
        check = subprocess.run(
            [bun, "--eval", check_source],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=check_env,
            timeout=20,
        )
        if check.returncode != 0:
            print("FAIL: generated Gajae Code extension is not importable")
            print(f"exit={check.returncode} stdout={check.stdout!r} stderr={check.stderr!r}")
            return 1

        expected_invocations = 7
        wait_for_text(fake_args_log, expected_invocations, timeout=10)
        wait_for_text(fake_stdin_log, expected_invocations, timeout=10)
        wait_for_text(fake_env_log, expected_invocations, timeout=10)
        args_log = fake_args_log.read_text(encoding="utf-8")
        stdin_log = fake_stdin_log.read_text(encoding="utf-8")
        env_log = fake_env_log.read_text(encoding="utf-8")
        if len([line for line in args_log.splitlines() if line.strip()]) != expected_invocations:
            print(f"FAIL: sub-session or team worker emitted Gajae Code hooks: {args_log!r}")
            return 1
        for expected in [
            "hooks gajae-code session-start",
            "hooks gajae-code prompt-submit",
            "hooks gajae-code stop",
        ]:
            if expected not in args_log:
                print(f"FAIL: generated extension did not invoke {expected}: {args_log!r}")
                return 1
        try:
            payloads = [json.loads(line) for line in stdin_log.splitlines() if line.strip()]
        except json.JSONDecodeError as exc:
            print(f"FAIL: generated extension emitted invalid payload JSON: {exc}; {stdin_log!r}")
            return 1
        if len(payloads) != expected_invocations:
            print(f"FAIL: expected {expected_invocations} hook payloads, got {payloads!r}")
            return 1
        by_session = {payload["session_id"]: payload for payload in payloads if "previous_session_id" in payload}
        if by_session.get("gjc-session-b", {}).get("previous_session_id") != "gjc-session-a":
            print(f"FAIL: session_switch did not carry the previous Gajae Code session: {payloads!r}")
            return 1
        if by_session.get("gjc-session-c", {}).get("previous_session_id") != "gjc-session-b":
            print(f"FAIL: session_branch did not carry the previous Gajae Code session: {payloads!r}")
            return 1
        retry_payloads = [payload for payload in payloads if payload.get("session_id") == "gjc-session-d"]
        if len(retry_payloads) != 2 or any(
            payload.get("previous_session_id") != "gjc-session-c" for payload in retry_payloads
        ):
            print(f"FAIL: failed session delivery did not retry with the prior session: {payloads!r}")
            return 1
        if not any(payload.get("prompt") == "hello gjc" for payload in payloads):
            print(f"FAIL: before_agent_start prompt missing: {payloads!r}")
            return 1
        if not any(payload.get("last_assistant_message") == "done" for payload in payloads):
            print(f"FAIL: agent_end assistant message missing: {payloads!r}")
            return 1

        env_lines = [line for line in env_log.splitlines() if line.strip()]
        if len(env_lines) != expected_invocations:
            print(f"FAIL: expected {expected_invocations} launch environments, got {env_log!r}")
            return 1
        fields = dict(field.split("=", 1) for field in env_lines[0].split("\t"))
        decoded_argv = decode_launch_argv(fields["argv"])
        expected_argv = [
            shutil.which("gjc") or "gjc",
            "--model",
            "anthropic/claude-sonnet-4-6",
            "--tmux",
        ]
        if fields.get("kind") != "gajae-code" or fields.get("tmux") != "gajae_code_live_123":
            print(f"FAIL: extension retained ancestor launch metadata or lost tmux identity: {fields!r}")
            return 1
        if decoded_argv != expected_argv:
            print(f"FAIL: extension captured wrong Gajae Code argv: expected {expected_argv!r}, got {decoded_argv!r}")
            return 1

        if not verify_hook_persistence(cli_path, root, env):
            return 1

        uninstall = subprocess.run(
            [cli_path, "hooks", "gajae-code", "uninstall", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if uninstall.returncode != 0 or extension_path.exists():
            print("FAIL: Gajae Code extension uninstall failed")
            print(f"exit={uninstall.returncode} stdout={uninstall.stdout!r} stderr={uninstall.stderr!r}")
            return 1
        extension_path.parent.mkdir(parents=True, exist_ok=True)
        extension_path.write_text("// user extension\n", encoding="utf-8")
        uninstall_foreign = subprocess.run(
            [cli_path, "hooks", "gajae-code", "uninstall", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if (
            uninstall_foreign.returncode != 0
            or not extension_path.exists()
            or "Refusing to remove" not in uninstall_foreign.stdout
        ):
            print("FAIL: uninstall did not preserve a non-cmux Gajae Code extension")
            return 1

        relative_root = root / "relative-root"
        relative_root.mkdir()
        relative_env = os.environ.copy()
        relative_env["HOME"] = str(home)
        relative_env["GJC_CODING_AGENT_DIR"] = "relative-agent"
        relative_install = subprocess.run(
            [cli_path, "hooks", "gajae-code", "install", "--yes"],
            cwd=relative_root,
            capture_output=True,
            text=True,
            check=False,
            env=relative_env,
            timeout=20,
        )
        relative_path = relative_root / "relative-agent" / "extensions" / "cmux-gajae-code-session.ts"
        if relative_install.returncode != 0 or not relative_path.exists():
            print("FAIL: relative GJC_CODING_AGENT_DIR did not resolve like Gajae Code")
            print(f"exit={relative_install.returncode} stdout={relative_install.stdout!r} stderr={relative_install.stderr!r}")
            return 1

        config_env = os.environ.copy()
        config_env["HOME"] = str(home)
        config_env.pop("GJC_CODING_AGENT_DIR", None)
        config_env["GJC_CONFIG_DIR"] = ".custom-gjc"
        config_install = subprocess.run(
            [cli_path, "hooks", "gajae-code", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=config_env,
            timeout=20,
        )
        config_path = home / ".custom-gjc" / "agent" / "extensions" / "cmux-gajae-code-session.ts"
        if config_install.returncode != 0 or not config_path.exists():
            print("FAIL: GJC_CONFIG_DIR did not select the Gajae Code config root")
            print(f"exit={config_install.returncode} stdout={config_install.stdout!r} stderr={config_install.stderr!r}")
            return 1

        default_env = os.environ.copy()
        default_env["HOME"] = str(home)
        default_env.pop("GJC_CODING_AGENT_DIR", None)
        default_env.pop("GJC_CONFIG_DIR", None)
        default_install = subprocess.run(
            [cli_path, "hooks", "gjc", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=default_env,
            timeout=20,
        )
        default_path = home / ".gjc" / "agent" / "extensions" / "cmux-gajae-code-session.ts"
        if default_install.returncode != 0 or not default_path.exists():
            print("FAIL: default Gajae Code extension path did not resolve under ~/.gjc/agent")
            print(f"exit={default_install.returncode} stdout={default_install.stdout!r} stderr={default_install.stderr!r}")
            return 1

    print("PASS: Gajae Code extension lifecycle, switching, tmux restore, and install safety")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
