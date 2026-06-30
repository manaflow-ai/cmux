#!/usr/bin/env python3
"""
Regression test: the generated Pi extension is importable and emits cmux hook calls.
"""

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


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def wait_for_text(path: Path, expected_count: int, timeout: float = 5.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            text = path.read_text(encoding="utf-8")
            if len([line for line in text.splitlines() if line.strip()]) >= expected_count:
                return text
        time.sleep(0.05)
    return path.read_text(encoding="utf-8") if path.exists() else ""


def payloads_from_log(text: str) -> list[dict[str, object]]:
    payloads: list[dict[str, object]] = []
    for raw in text.split("\n---\n"):
        raw = raw.strip()
        if not raw:
            continue
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            payloads.append(payload)
    return payloads


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

    with tempfile.TemporaryDirectory(prefix="cmux-pi-extension-") as td:
        root = Path(td)
        config_dir = root / "pi-agent"
        env = os.environ.copy()
        env["PI_CODING_AGENT_DIR"] = str(config_dir)

        install = subprocess.run(
            [cli_path, "hooks", "pi", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if install.returncode != 0:
            print("FAIL: pi extension install failed")
            print(f"exit={install.returncode}")
            print(f"stdout={install.stdout.strip()}")
            print(f"stderr={install.stderr.strip()}")
            return 1

        extension_path = config_dir / "extensions" / "cmux-session.ts"
        if not extension_path.exists():
            print(f"FAIL: expected extension at {extension_path}")
            return 1
        extension_text = extension_path.read_text(encoding="utf-8")
        if "cmux-pi-session-extension-marker" not in extension_text:
            print(f"FAIL: expected cmux marker in {extension_path}")
            return 1

        if "@earendil-works/pi-coding-agent" not in extension_text:
            print("FAIL: generated Pi extension does not import the current Pi package")
            return 1

        bin_dir = root / "bin"
        bin_dir.mkdir()
        fake_pi = bin_dir / "pi"
        make_executable(fake_pi, "#!/usr/bin/env bash\nexit 0\n")

        fake_cmux = root / "fake-cmux"
        fake_args_log = root / "fake-cmux-args.log"
        fake_stdin_log = root / "fake-cmux-stdin.log"
        fake_env_log = root / "fake-cmux-env.log"
        fake_binding = root / "fake-surface-binding.json"
        make_executable(
            fake_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_TEST_PI_ARGS_LOG"
payload="$(cat)"
printf '%s' "$payload" >> "$CMUX_TEST_PI_STDIN_LOG"
printf '\n---\n' >> "$CMUX_TEST_PI_STDIN_LOG"
{
  printf 'kind=%s\n' "${CMUX_AGENT_LAUNCH_KIND-}"
  printf 'cwd=%s\n' "${CMUX_AGENT_LAUNCH_CWD-}"
  printf 'argv=%s\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-}"
  if [ -n "${OPENAI_API_KEY-}" ]; then printf 'OPENAI_API_KEY=present\n'; fi
  if [ -n "${ANTHROPIC_AUTH_TOKEN-}" ]; then printf 'ANTHROPIC_AUTH_TOKEN=present\n'; fi
  if [ -n "${CUSTOM_PASSWORD-}" ]; then printf 'CUSTOM_PASSWORD=present\n'; fi
  if [ -n "${AMP_API_KEY-}" ]; then printf 'AMP_API_KEY=present\n'; fi
  if [ -n "${CMUX_LEAK_TOKEN-}" ]; then printf 'CMUX_LEAK_TOKEN=present\n'; fi
  if [ -n "${DATABASE_URL-}" ]; then printf 'DATABASE_URL=present\n'; fi
  if [ -n "${DB_PASS-}" ]; then printf 'DB_PASS=present\n'; fi
  if [ -n "${SENTRY_DSN-}" ]; then printf 'SENTRY_DSN=present\n'; fi
  if [ -n "${GH_PAT-}" ]; then printf 'GH_PAT=present\n'; fi
  if [ -n "${CLOUDFLARE_AUTH_KEY-}" ]; then printf 'CLOUDFLARE_AUTH_KEY=present\n'; fi
  if [ -n "${STRIPE_SK-}" ]; then printf 'STRIPE_SK=present\n'; fi
  if [ -n "${SLACK_WEBHOOK_URL-}" ]; then printf 'SLACK_WEBHOOK_URL=present\n'; fi
  if [ -n "${CMUX_TEST_PI_TOKEN-}" ]; then printf 'CMUX_TEST_PI_TOKEN=present\n'; fi
} >> "$CMUX_TEST_PI_ENV_LOG"
case "$*" in
  *"hooks pi notification"*)
    if printf '%s' "$payload" | grep -q 'pi-session-notification-fails'; then
      printf 'forced notification failure\n' >&2
      exit 42
    fi
    printf '{}\n'
    ;;
  *"surface resume get"*)
    if [ -f "$CMUX_TEST_PI_BINDING_FILE" ]; then
      cat "$CMUX_TEST_PI_BINDING_FILE"
    else
      printf '{"resume_binding":null}\n'
    fi
    ;;
  *"surface resume set"*)
    checkpoint_id=""
    previous=""
    for token in "$@"; do
      if [ "$previous" = "--checkpoint-id" ]; then
        checkpoint_id="$token"
        break
      fi
      previous="$token"
    done
    printf '{"resume_binding":{"kind":"pi","checkpoint_id":"%s","source":"agent-hook","command":"pi --session %s"}}\n' "$checkpoint_id" "$checkpoint_id" > "$CMUX_TEST_PI_BINDING_FILE"
    printf '{"ok":true}\n'
    ;;
  *"surface resume clear"*)
    rm -f "$CMUX_TEST_PI_BINDING_FILE"
    printf '{"ok":true}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
""",
        )

        check_env = env.copy()
        check_env["PATH"] = str(bin_dir) + os.pathsep + check_env.get("PATH", "")
        check_env["CMUX_TEST_PI_EXTENSION_PATH"] = str(extension_path)
        check_env["CMUX_SURFACE_ID"] = "surface-pi-test"
        check_env["CMUX_WORKSPACE_ID"] = "workspace-pi-test"
        check_env["CMUX_PI_CMUX_BIN"] = str(fake_cmux)
        check_env["CMUX_TEST_PI_ARGS_LOG"] = str(fake_args_log)
        check_env["CMUX_TEST_PI_STDIN_LOG"] = str(fake_stdin_log)
        check_env["CMUX_TEST_PI_ENV_LOG"] = str(fake_env_log)
        check_env["CMUX_TEST_PI_BINDING_FILE"] = str(fake_binding)
        check_env["OPENAI_API_KEY"] = "openai-secret-should-not-leak"
        check_env["ANTHROPIC_AUTH_TOKEN"] = "anthropic-secret-should-not-leak"
        check_env["CUSTOM_PASSWORD"] = "password-should-not-leak"
        check_env["AMP_API_KEY"] = "amp-secret-should-not-leak"
        check_env["CMUX_LEAK_TOKEN"] = "cmux-secret-should-not-leak"
        check_env["DATABASE_URL"] = "postgres://user:password@example.invalid/db"
        check_env["DB_PASS"] = "db-pass-should-not-leak"
        check_env["SENTRY_DSN"] = "https://public:private@example.invalid/1"
        check_env["GH_PAT"] = "github-pat-should-not-leak"
        check_env["CLOUDFLARE_AUTH_KEY"] = "cloudflare-key-should-not-leak"
        check_env["STRIPE_SK"] = "stripe-secret-should-not-leak"
        check_env["SLACK_WEBHOOK_URL"] = "https://hooks.slack.invalid/secret"
        check_env["CMUX_TEST_PI_TOKEN"] = "test-token-should-not-leak"
        check_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
if (typeof mod.default !== "function") throw new Error("missing default export");
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
for (const name of [
  "session_start",
  "before_agent_start",
  "agent_end",
  "session_shutdown",
  "tool_execution_start",
  "tool_execution_end",
]) {
  if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
}
process.argv.splice(
  0,
  process.argv.length,
  "/opt/homebrew/bin/node",
  "/tmp/node_modules/@earendil-works/pi-coding-agent/dist/cli.js",
  "--model",
  "anthropic/claude-sonnet-4-5"
);
const ctx = {
  cwd: "/tmp/pi-project",
  sessionManager: {
    getSessionId() { return "pi-session-test"; }
  }
};
await handlers.get("session_start")({}, ctx);
await handlers.get("before_agent_start")({ prompt: "hello pi" }, ctx);
await handlers.get("tool_execution_start")({
  id: "tool-event-start-should-not-be-turn-id",
  toolCallId: "tool-call-1",
  toolName: "bash",
  args: { command: "echo ok" }
}, ctx);
await handlers.get("tool_execution_end")({
  id: "tool-event-end-should-not-be-turn-id",
  toolCallId: "tool-call-1",
  toolName: "bash",
  result: { content: [{ type: "text", text: "ok" }] },
  isError: false
}, ctx);
await handlers.get("agent_end")({
  messages: [
    { role: "user", content: "hello pi" },
    { role: "assistant", content: [{ type: "text", text: "done" }] }
  ],
  stopReason: "completed"
}, ctx);
await handlers.get("session_shutdown")({ reason: "quit" }, ctx);
const interruptedCtx = {
  cwd: "/tmp/pi-project",
  sessionManager: {
    getSessionId() { return "pi-session-interrupted"; }
  }
};
await handlers.get("session_start")({}, interruptedCtx);
await handlers.get("before_agent_start")({ prompt: "interrupt me" }, interruptedCtx);
await handlers.get("session_shutdown")({ reason: "terminated" }, interruptedCtx);
process.env.CMUX_PI_HOOKS_DISABLED = "1";
const disabledCtx = {
  cwd: "/tmp/pi-project",
  sessionManager: {
    getSessionId() { return "pi-session-disabled"; }
  }
};
await handlers.get("session_start")({}, disabledCtx);
await handlers.get("session_shutdown")({ reason: "disabled" }, disabledCtx);
delete process.env.CMUX_PI_HOOKS_DISABLED;
const notificationFailureCtx = {
  cwd: "/tmp/pi-project",
  sessionManager: {
    getSessionId() { return "pi-session-notification-fails"; }
  }
};
await handlers.get("session_start")({}, notificationFailureCtx);
await handlers.get("before_agent_start")({ prompt: "finish without routed notification" }, notificationFailureCtx);
await handlers.get("agent_end")({
  messages: [
    { role: "user", content: "finish without routed notification" },
    { role: "assistant", content: "notification should fail" }
  ],
  stopReason: "completed"
}, notificationFailureCtx);
"""
        # cmux no-surface hibernation coverage (PR #6991): a plugin agent launched
        # without a surface env must still register session hooks once a socket and a
        # scoped identity (here, a workspace) are present, must stay silent when no
        # socket is available, and must skip surface-scoped resume bindings.
        #
        # Regression (CodeRabbit + autoreview, PR #6991): when a surface id is present
        # but no socket is available, the extension must stay completely silent. A
        # skipped session_start must not run ensureResumeBinding ("surface resume set"),
        # and session_shutdown must not run clearResumeBinding ("surface resume clear");
        # either would otherwise route to the default/wrong cmux socket without a socket.
        no_socket_args_log = root / "fake-cmux-args-surface-no-socket.log"
        no_socket_stdin_log = root / "fake-cmux-stdin-surface-no-socket.log"
        no_socket_env_log = root / "fake-cmux-env-surface-no-socket.log"
        no_socket_binding = root / "fake-surface-binding-surface-no-socket.json"
        surface_no_socket_env = check_env.copy()  # surface + workspace present, no socket yet
        surface_no_socket_env.pop("CMUX_SOCKET_PATH", None)
        surface_no_socket_env["CMUX_TEST_PI_ARGS_LOG"] = str(no_socket_args_log)
        surface_no_socket_env["CMUX_TEST_PI_STDIN_LOG"] = str(no_socket_stdin_log)
        surface_no_socket_env["CMUX_TEST_PI_ENV_LOG"] = str(no_socket_env_log)
        surface_no_socket_env["CMUX_TEST_PI_BINDING_FILE"] = str(no_socket_binding)
        surface_no_socket_check = subprocess.run(
            [bun, "--eval", check_source],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=surface_no_socket_env,
            timeout=20,
        )
        if surface_no_socket_check.returncode != 0:
            print("FAIL: generated Pi extension failed with a surface but no socket")
            print(f"exit={surface_no_socket_check.returncode}")
            print(f"stdout={surface_no_socket_check.stdout.strip()}")
            print(f"stderr={surface_no_socket_check.stderr.strip()}")
            return 1
        surface_no_socket_args = (
            no_socket_args_log.read_text(encoding="utf-8") if no_socket_args_log.exists() else ""
        )
        if surface_no_socket_args.strip():
            print(
                "FAIL: Pi extension invoked cmux without a socket; with a surface id but no "
                "CMUX_SOCKET_PATH it must route no session hook and no surface resume "
                f"set/clear: {surface_no_socket_args!r}"
            )
            return 1

        no_surface_args_log = root / "fake-cmux-args-no-surface.log"
        no_surface_stdin_log = root / "fake-cmux-stdin-no-surface.log"
        no_surface_env_log = root / "fake-cmux-env-no-surface.log"
        no_surface_binding = root / "fake-surface-binding-no-surface.json"
        no_surface_env = check_env.copy()
        no_surface_env.pop("CMUX_SOCKET_PATH", None)
        no_surface_env.pop("CMUX_SURFACE_ID", None)
        no_surface_env.pop("CMUX_PANEL_ID", None)
        no_surface_env["CMUX_WORKSPACE_ID"] = "workspace-pi-test"
        no_surface_env["CMUX_TEST_PI_ARGS_LOG"] = str(no_surface_args_log)
        no_surface_env["CMUX_TEST_PI_STDIN_LOG"] = str(no_surface_stdin_log)
        no_surface_env["CMUX_TEST_PI_ENV_LOG"] = str(no_surface_env_log)
        no_surface_env["CMUX_TEST_PI_BINDING_FILE"] = str(no_surface_binding)

        no_socket_check = subprocess.run(
            [bun, "--eval", check_source],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=no_surface_env,
            timeout=20,
        )
        if no_socket_check.returncode != 0:
            print("FAIL: generated Pi extension failed without socket context")
            print(f"exit={no_socket_check.returncode}")
            print(f"stdout={no_socket_check.stdout.strip()}")
            print(f"stderr={no_socket_check.stderr.strip()}")
            return 1
        if no_surface_args_log.exists() and no_surface_args_log.read_text(encoding="utf-8").strip():
            print("FAIL: extension invoked cmux without CMUX_SOCKET_PATH")
            print(no_surface_args_log.read_text(encoding="utf-8"))
            return 1

        no_surface_env["CMUX_SOCKET_PATH"] = str(root / "cmux-test-no-surface.sock")
        no_surface_check = subprocess.run(
            [bun, "--eval", check_source],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=no_surface_env,
            timeout=20,
        )
        if no_surface_check.returncode != 0:
            print("FAIL: generated Pi extension failed without surface context")
            print(f"exit={no_surface_check.returncode}")
            print(f"stdout={no_surface_check.stdout.strip()}")
            print(f"stderr={no_surface_check.stderr.strip()}")
            return 1
        no_surface_args = wait_for_text(no_surface_args_log, 1, timeout=20.0)
        if "hooks pi session-start" not in no_surface_args:
            print(f"FAIL: Pi extension did not register session hooks without a surface, got {no_surface_args!r}")
            return 1
        if "surface resume" in no_surface_args:
            print(f"FAIL: Pi extension attempted a surface-scoped resume binding without a surface, got {no_surface_args!r}")
            return 1
        if "hooks feed" in no_surface_args:
            print(f"FAIL: Pi extension emitted surface-scoped feed telemetry without a surface, got {no_surface_args!r}")
            return 1

        check_env["CMUX_SOCKET_PATH"] = str(root / "cmux-test.sock")
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
            print("FAIL: generated Pi extension is not importable")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

        args_log = wait_for_text(fake_args_log, 21, timeout=20.0)
        stdin_log = wait_for_text(fake_stdin_log, 34, timeout=20.0)
        env_log = wait_for_text(fake_env_log, 21 * 3, timeout=20.0)
        for expected in [
            "hooks pi session-start",
            "hooks pi prompt-submit",
            "hooks pi stop",
            "hooks pi notification",
            "hooks feed --source pi --event PreToolUse",
            "hooks feed --source pi --event PostToolUse",
            "surface resume get",
            "surface resume set",
            "surface resume clear",
        ]:
            if expected not in args_log:
                print(f"FAIL: extension did not invoke {expected}, got {args_log!r}")
                return 1

        arg_lines = [line for line in args_log.splitlines() if line.strip()]
        resume_ops = []
        for line in [line for line in arg_lines if "surface resume " in line]:
            if "surface resume get" in line:
                resume_ops.append("get")
            elif "surface resume set" in line:
                resume_ops.append("set")
            elif "surface resume clear" in line:
                resume_ops.append("clear")
        expected_resume_ops = ["set", "get", "clear", "set", "get", "clear", "set", "get"]
        if resume_ops != expected_resume_ops:
            print(f"FAIL: extension did not verify resume binding after set, got {resume_ops!r}")
            return 1
        stop_notification_ops = []
        for line in arg_lines:
            if "hooks pi notification" in line:
                stop_notification_ops.append("notification")
            elif "hooks pi stop" in line:
                stop_notification_ops.append("stop")
        if stop_notification_ops[:2] != ["notification", "stop"]:
            print(
                "FAIL: Pi completion stop suppressed native fallback before custom notification, "
                f"got {stop_notification_ops!r}"
            )
            return 1
        if stop_notification_ops[-2:] != ["notification", "stop"]:
            print(
                "FAIL: Pi notification failure path did not attempt custom notification before stop, "
                f"got {stop_notification_ops!r}"
            )
            return 1

        payloads = payloads_from_log(stdin_log)
        if not any(payload.get("session_id") == "pi-session-test" for payload in payloads):
            print(f"FAIL: extension did not pass session id, got {payloads!r}")
            return 1
        prompt_payload = next((payload for payload in payloads if payload.get("prompt") == "hello pi"), None)
        stop_payload = next((payload for payload in payloads if payload.get("last_assistant_message") == "done"), None)
        if prompt_payload is None or stop_payload is None:
            print(f"FAIL: extension did not pass prompt/assistant payload, got {payloads!r}")
            return 1
        prompt_turn_id = prompt_payload.get("turn_id")
        if not isinstance(prompt_turn_id, str) or not prompt_turn_id:
            print(f"FAIL: prompt-submit payload did not include a fallback turn_id, got {prompt_payload!r}")
            return 1
        if stop_payload.get("turn_id") != prompt_turn_id:
            print(f"FAIL: stop payload did not reuse prompt turn_id, prompt={prompt_payload!r}, stop={stop_payload!r}")
            return 1
        if stop_payload.get("cmux_notification_routed") is not True:
            print(f"FAIL: successful Pi completion notification did not mark stop as routed: {stop_payload!r}")
            return 1
        fallback_stop_payload = next(
            (
                payload
                for payload in payloads
                if payload.get("session_id") == "pi-session-notification-fails"
                and payload.get("hook_event_name") == "Stop"
            ),
            None,
        )
        if fallback_stop_payload is None:
            print(f"FAIL: notification failure session did not send a stop payload, got {payloads!r}")
            return 1
        if fallback_stop_payload.get("cmux_notification_routed") is True:
            print(
                "FAIL: failed Pi completion notification still suppressed native notification fallback, "
                f"got {fallback_stop_payload!r}"
            )
            return 1
        interrupted_stop_payload = next(
            (payload for payload in payloads if payload.get("terminationReason") == "terminated"),
            None,
        )
        if interrupted_stop_payload is None:
            print(f"FAIL: interrupted session shutdown did not send stop payload, got {payloads!r}")
            return 1
        if interrupted_stop_payload.get("cmux_notification_routed") is True:
            print(
                "FAIL: interrupted session shutdown suppressed native notification fallback, "
                f"got {interrupted_stop_payload!r}"
            )
            return 1
        feed_events = [payload for payload in payloads if payload.get("hook_event_name") in {"PreToolUse", "PostToolUse"}]
        if len(feed_events) != 2 or {payload.get("tool_name") for payload in feed_events} != {"bash"}:
            print(f"FAIL: Pi Feed bridge payloads were incomplete: {feed_events!r}")
            return 1
        if {payload.get("turn_id") for payload in feed_events} != {prompt_turn_id}:
            print(f"FAIL: Pi Feed bridge did not use the active prompt turn id: {feed_events!r}")
            return 1
        notification_payload = next(
            (payload for payload in payloads if payload.get("hook_event_name") == "Notification"),
            None,
        )
        if notification_payload is None or notification_payload.get("message") != "done":
            print(f"FAIL: Pi completion notification was not routed through hooks pi notification: {payloads!r}")
            return 1
        if "kind=pi" not in env_log or "cwd=/tmp/pi-project" not in env_log or "argv=" not in env_log:
            print(f"FAIL: extension did not pass launch metadata environment, got {env_log!r}")
            return 1
        leaked = [
            name
            for name in [
                "OPENAI_API_KEY",
                "ANTHROPIC_AUTH_TOKEN",
                "CUSTOM_PASSWORD",
                "AMP_API_KEY",
                "CMUX_LEAK_TOKEN",
                "DATABASE_URL",
                "DB_PASS",
                "SENTRY_DSN",
                "GH_PAT",
                "CLOUDFLARE_AUTH_KEY",
                "STRIPE_SK",
                "SLACK_WEBHOOK_URL",
                "CMUX_TEST_PI_TOKEN",
            ]
            if f"{name}=present" in env_log
        ]
        if leaked:
            print(f"FAIL: extension leaked secret environment keys to hook subprocesses: {leaked}; env={env_log!r}")
            return 1
        argv_line = next((line for line in env_log.splitlines() if line.startswith("argv=")), "")
        try:
            decoded_argv = [
                value
                for value in base64.b64decode(argv_line.removeprefix("argv=")).decode("utf-8").split("\0")
                if value
            ]
        except Exception as exc:
            print(f"FAIL: extension launch argv was not valid base64 NUL data: {exc}; env={env_log!r}")
            return 1
        expected_argv = [
            str(fake_pi),
            "--model",
            "anthropic/claude-sonnet-4-5",
        ]
        if decoded_argv != expected_argv:
            print(f"FAIL: extension captured wrong Pi launch argv; expected {expected_argv!r}, got {decoded_argv!r}")
            return 1

    print("PASS: generated Pi extension installs and emits cmux hooks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
