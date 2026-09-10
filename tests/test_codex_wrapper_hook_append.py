#!/usr/bin/env python3
"""Behavioral regression tests for cmux Codex hook argument composition.

Codex discovers hooks per configuration layer and appends them from lowest to
highest: the user's ``hooks.json`` and ``[hooks]`` table in ``config.toml``, a
trusted project's ``.codex/hooks.json``, and finally the session flags. The
``-c hooks.<event>=...`` values cmux injects only define that session-flags
layer, so they must carry exactly one cmux handler per event and must never
re-declare the user's handlers: a copied user handler is discovered twice and
runs twice (https://github.com/manaflow-ai/cmux/issues/12081).

The argv-level tests run against the built cmux CLI. The live test also runs
the real ``codex`` binary through ``Resources/bin/cmux-codex-wrapper`` against
a hermetic local model provider and is skipped when no real codex is installed.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from collections.abc import Iterator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from claude_teams_test_utils import (
    FOCUSED_SURFACE_ID,
    FOCUSED_WORKSPACE_ID,
    focused_cmux_server,
    resolve_cmux_cli,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-codex-wrapper"
ACTIVATION_PREFIX = ["--enable", "hooks", "--dangerously-bypass-hook-trust"]
# The events named in issue 12081. The CLI's own baseline (an empty hooks.json)
# defines the complete injected set, which newer schemas extend.
ISSUE_EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "Stop",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
]
# Every hook event Codex 0.153 knows, so user handlers on events cmux never
# injects are covered too. The issue events carry awkward commands: quotes,
# backslashes, a TOML triple quote, and a newline. None of them may leak into
# the args cmux emits, and none of them may break the cmux value shape.
USER_COMMANDS = {
    "SessionStart": 'user-12081-session-start "quoted" back\\slash',
    "UserPromptSubmit": "user-12081-prompt-submit '''triple'''",
    "Stop": "user-12081-stop\nsecond line",
    "PreToolUse": "user-12081-pre-tool-use",
    "PostToolUse": "user-12081-post-tool-use",
    "PermissionRequest": "user-12081-permission-request",
    "PreCompact": "user-12081-pre-compact",
    "PostCompact": "user-12081-post-compact",
    "SessionEnd": "user-12081-session-end",
    "SubagentStart": "user-12081-subagent-start",
    "SubagentStop": "user-12081-subagent-stop",
    "Interrupt": "user-12081-interrupt",
}
LIVE_EVENTS = ["SessionStart", "UserPromptSubmit", "Stop"]
# Every user-owned handler the live run must fire exactly once: the three
# hooks.json handlers above plus one SessionStart handler in each of the other
# documented user layers (config.toml `[hooks]` and a trusted project's
# `.codex/hooks.json`).
LIVE_USER_MARKERS = LIVE_EVENTS + ["SessionStart:config.toml", "SessionStart:project"]
# cmux's own handlers that a one-turn `codex exec` with no tool calls fires.
LIVE_CMUX_SUBCOMMANDS = ["session-start", "prompt-submit", "stop"]


def user_hooks_json(commands: dict[str, str]) -> dict:
    return {
        "hooks": {
            event: [
                {
                    "matcher": "",
                    "hooks": [{"type": "command", "command": command, "timeout": 30}],
                }
            ]
            for event, command in commands.items()
        }
    }


def clean_environment(**overrides: str) -> dict[str, str]:
    """A minimal environment with no ambient cmux terminal context."""
    environment = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "TERM": "xterm",
    }
    environment.update(overrides)
    return environment


def run_inject_args(cli_path: str, codex_home: Path, home: Path) -> list[str]:
    result = subprocess.run(
        [cli_path, "hooks", "codex", "inject-args"],
        env=clean_environment(HOME=str(home), CODEX_HOME=str(codex_home)),
        capture_output=True,
        check=True,
    )
    return [argument.decode("utf-8") for argument in result.stdout.split(b"\0") if argument]


def hook_assignments(arguments: list[str]) -> dict[str, list[str]]:
    """Map each ``hooks.<event>`` key to every ``-c`` value assigned to it."""
    assignments: dict[str, list[str]] = {}
    for index, argument in enumerate(arguments[:-1]):
        value = arguments[index + 1]
        if argument == "-c" and value.startswith("hooks."):
            key, _, body = value.partition("=")
            assignments.setdefault(key[len("hooks.") :], []).append(body)
    return assignments


def assert_injection_shape(arguments: list[str], context: str) -> None:
    """Activation flags, then nothing but ``-c hooks.<event>=...`` pairs."""
    assert arguments[: len(ACTIVATION_PREFIX)] == ACTIVATION_PREFIX, f"{context}: {arguments}"
    rest = arguments[len(ACTIVATION_PREFIX) :]
    assert len(rest) % 2 == 0, f"{context}: dangling argument: {rest}"
    for index in range(0, len(rest), 2):
        assert rest[index] == "-c", f"{context}: unexpected argument {rest[index]!r}: {rest}"
        assert rest[index + 1].startswith("hooks."), f"{context}: non-hook override: {rest[index + 1]!r}"


def assert_single_cmux_group(event: str, values: list[str], context: str) -> None:
    assert len(values) == 1, f"{context}: {event} assigned {len(values)} times: {values}"
    value = values[0]
    assert value.count("{hooks=") == 1, f"{context}: {event} carries more than one group: {value}"
    assert value.count('type="command"') == 1, f"{context}: {event} carries more than one handler: {value}"
    assert value.startswith("[{hooks=[{type=\"command\",command='''"), f"{context}: {event} shape changed: {value}"
    assert "cmux-codex-hook" in value or "hooks codex" in value, f"{context}: {event} is not cmux's handler: {value}"


def assert_no_user_handlers(arguments: list[str], context: str) -> None:
    joined = "\0".join(arguments)
    for event, command in USER_COMMANDS.items():
        token = command.split()[0]
        assert token not in joined, f"{context}: user {event} handler was re-declared in session flags: {joined}"


def baseline_events(cli_path: str, root: Path) -> set[str]:
    """The complete event set the CLI injects when no user hooks exist."""
    codex_home = root / "baseline-codex"
    codex_home.mkdir()
    (codex_home / "hooks.json").write_text(json.dumps({"hooks": {}}), encoding="utf-8")
    events = set(hook_assignments(run_inject_args(cli_path, codex_home, root / "home")))
    assert set(ISSUE_EVENTS) <= events, f"baseline injection lost issue events: {events}"
    return events


def test_injected_hooks_do_not_redeclare_user_hooks() -> None:
    cli_path = resolve_cmux_cli()
    with tempfile.TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        expected_events = baseline_events(cli_path, root)
        codex_home = root / "codex"
        codex_home.mkdir()
        hooks_path = codex_home / "hooks.json"
        hooks_path.write_text(json.dumps(user_hooks_json(USER_COMMANDS)), encoding="utf-8")
        original_bytes = hooks_path.read_bytes()

        arguments = run_inject_args(cli_path, codex_home, root / "home")
        assert_injection_shape(arguments, "inject-args")
        assignments = hook_assignments(arguments)
        # User hooks change nothing about which events cmux injects.
        assert set(assignments) == expected_events, (set(assignments), expected_events)
        for event, values in assignments.items():
            assert_single_cmux_group(event, values, "inject-args")
        assert_no_user_handlers(arguments, "inject-args")
        # The wrapper reads the user's file; it never rewrites it.
        assert hooks_path.read_bytes() == original_bytes, "inject-args rewrote hooks.json"


def test_persistent_cmux_hook_is_not_duplicated() -> None:
    cli_path = resolve_cmux_cli()
    with tempfile.TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        codex_home = root / "codex"
        codex_home.mkdir()
        (codex_home / "hooks.json").write_text(json.dumps({"hooks": {}}), encoding="utf-8")
        baseline = hook_assignments(run_inject_args(cli_path, codex_home, root / "home"))
        session_start = baseline["SessionStart"][0]
        prefix = "[{hooks=[{type=\"command\",command='''"
        cmux_command = session_start[len(prefix) :].split("'''", 1)[0]
        assert cmux_command, session_start

        # A persistent cmux SessionStart handler plus a user Stop handler: the
        # wrapper must skip SessionStart and still not copy the user's Stop.
        persistent = user_hooks_json({"Stop": USER_COMMANDS["Stop"]})
        persistent["hooks"]["SessionStart"] = [
            {"hooks": [{"type": "command", "command": cmux_command}]}
        ]
        hooks_path = codex_home / "hooks.json"
        hooks_path.write_text(json.dumps(persistent), encoding="utf-8")
        original_bytes = hooks_path.read_bytes()

        arguments = run_inject_args(cli_path, codex_home, root / "home")
        assert_injection_shape(arguments, "persistent")
        assignments = hook_assignments(arguments)
        assert "SessionStart" not in assignments, f"persistent SessionStart was duplicated: {assignments}"
        assert set(assignments) == set(baseline) - {"SessionStart"}, (set(assignments), set(baseline))
        for event, values in assignments.items():
            assert_single_cmux_group(event, values, "persistent")
        assert_no_user_handlers(arguments, "persistent")
        assert hooks_path.read_bytes() == original_bytes, "inject-args rewrote hooks.json"


class _FakeModelHandler(BaseHTTPRequestHandler):
    """Answers the Responses wire API with one canned assistant message."""

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        return

    def do_POST(self) -> None:  # noqa: N802
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        events = [
            ("response.created", {"type": "response.created", "response": {"id": "resp_1"}}),
            (
                "response.output_item.done",
                {
                    "type": "response.output_item.done",
                    "item": {
                        "type": "message",
                        "id": "msg_1",
                        "role": "assistant",
                        "content": [{"type": "output_text", "text": "ok"}],
                    },
                },
            ),
            (
                "response.completed",
                {
                    "type": "response.completed",
                    "response": {
                        "id": "resp_1",
                        "usage": {
                            "input_tokens": 1,
                            "output_tokens": 1,
                            "total_tokens": 2,
                            "input_tokens_details": {"cached_tokens": 0},
                            "output_tokens_details": {"reasoning_tokens": 0},
                        },
                    },
                },
            ),
        ]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for name, payload in events:
            self.wfile.write(f"event: {name}\ndata: {json.dumps(payload)}\n\n".encode("utf-8"))
        self.wfile.flush()


def resolve_real_codex() -> str | None:
    explicit = os.environ.get("CMUX_TEST_REAL_CODEX")
    if explicit and os.access(explicit, os.X_OK):
        return explicit
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        if not directory or "cmux-cli-shims" in directory or directory.endswith("/Resources/bin"):
            continue
        candidate = Path(directory) / "codex"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def write_marker_hook(path: Path, marker_log: Path, event: str) -> None:
    path.write_text(
        "#!/bin/sh\n"
        "cat >/dev/null\n"
        f"printf '%s\\n' '{event}' >> '{marker_log}'\n",
        encoding="utf-8",
    )
    path.chmod(0o755)


def wait_for(predicate, timeout_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.2)
    return predicate()


@contextmanager
def scratch_directory(prefix: str) -> Iterator[str]:
    """A temporary directory whose removal tolerates stragglers.

    cmux's fire-and-forget hooks keep writing payload files under TMPDIR for a
    moment after codex exits. Python 3.9 (the CI runner default) has no
    ``ignore_cleanup_errors``, so clean up by hand.
    """
    # Resolve the macOS `/var` -> `/private/var` symlink: Codex trusts a project
    # by its canonical path, so the trust entry must match the cwd it sees.
    path = str(Path(tempfile.mkdtemp(prefix=prefix)).resolve())
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


def write_logging_shim(path: Path, log: Path, target: str) -> None:
    """An executable that appends its arguments to ``log`` then execs ``target``."""
    path.write_text(
        "#!/usr/bin/env bash\n"
        f"printf '%s\\n' \"$*\" >> '{log}'\n"
        f"exec '{target}' \"$@\"\n",
        encoding="utf-8",
    )
    path.chmod(0o755)


def cmux_hook_calls(log: Path) -> dict[str, int]:
    """How many times each `cmux hooks codex <subcommand>` reached the CLI."""
    lines = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    counts: dict[str, int] = {}
    for line in lines:
        _, marker, subcommand = line.rpartition("hooks codex ")
        if marker:
            counts[subcommand] = counts.get(subcommand, 0) + 1
    return counts


def test_live_codex_runs_user_hooks_and_cmux_hook_once_each() -> None:
    real_codex = resolve_real_codex()
    if real_codex is None:
        # CI runners do not provision Codex. Where it is provisioned, set
        # CMUX_TEST_REQUIRE_REAL_CODEX=1 so a missing binary fails instead
        # of skipping.
        message = "no real codex binary on PATH; set CMUX_TEST_REAL_CODEX to run"
        assert os.environ.get("CMUX_TEST_REQUIRE_REAL_CODEX") != "1", message
        raise unittest.SkipTest(message)
    cli_path = resolve_cmux_cli()

    server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeModelHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    try:
        with scratch_directory("cmux-codex-live-") as temporary_directory:
            root = Path(temporary_directory)
            codex_home = root / "codex"
            home = root / "home"
            state_dir = root / "cmux-state"
            work = root / "work"
            hooks_dir = root / "user-hooks"
            for directory in (codex_home, home, state_dir, work, hooks_dir):
                directory.mkdir()
            marker_log = root / "user-hooks.log"
            commands = {}
            for marker in LIVE_USER_MARKERS:
                script = hooks_dir / (marker.replace(":", "-") + ".sh")
                write_marker_hook(script, marker_log, marker)
                commands[marker] = str(script)
            (codex_home / "hooks.json").write_text(
                json.dumps(user_hooks_json({event: commands[event] for event in LIVE_EVENTS})),
                encoding="utf-8",
            )
            # A trusted project layer: Codex discovers `.codex/hooks.json` at
            # the project root, which it locates through the git checkout.
            subprocess.run(["git", "init", "-q", str(work)], check=True, capture_output=True)
            (work / ".codex").mkdir()
            (work / ".codex" / "hooks.json").write_text(
                json.dumps(user_hooks_json({"SessionStart": commands["SessionStart:project"]})),
                encoding="utf-8",
            )
            port = server.server_address[1]
            (codex_home / "config.toml").write_text(
                "\n".join(
                    [
                        'model = "fake-model"',
                        'model_provider = "fake"',
                        "",
                        "[model_providers.fake]",
                        'name = "fake"',
                        f'base_url = "http://127.0.0.1:{port}/v1"',
                        'wire_api = "responses"',
                        "",
                        "[features]",
                        "hooks = true",
                        "",
                        f'[projects."{work}"]',
                        'trust_level = "trusted"',
                        "",
                        # The user layer's TOML representation of a hook.
                        "[[hooks.SessionStart]]",
                        "[[hooks.SessionStart.hooks]]",
                        'type = "command"',
                        f'command = "{commands["SessionStart:config.toml"]}"',
                        "",
                    ]
                ),
                encoding="utf-8",
            )

            argv_log = root / "codex-argv.log"
            argv_shim = root / "codex-argv-shim"
            argv_shim.write_text(
                "#!/usr/bin/env bash\n"
                f": > '{argv_log}'\n"
                f"for arg in \"$@\"; do printf '%s\\0' \"$arg\" >> '{argv_log}'; done\n"
                f"exec '{real_codex}' \"$@\"\n",
                encoding="utf-8",
            )
            argv_shim.chmod(0o755)
            # Every cmux CLI call (the wrapper's inject-args and each hook's
            # detached delivery) goes through this shim, so invocations can be
            # counted per subcommand.
            cli_calls = root / "cmux-cli-calls.log"
            cli_shim = root / "cmux-cli-shim"
            write_logging_shim(cli_shim, cli_calls, cli_path)

            with focused_cmux_server(root / "cmux.sock") as (socket_path, requests):
                environment = clean_environment(
                    HOME=str(home),
                    CODEX_HOME=str(codex_home),
                    TMPDIR=str(root),
                    CMUX_SURFACE_ID=FOCUSED_SURFACE_ID,
                    CMUX_WORKSPACE_ID=FOCUSED_WORKSPACE_ID,
                    CMUX_SOCKET_PATH=socket_path,
                    CMUX_BUNDLED_CLI_PATH=str(cli_shim),
                    CMUX_CUSTOM_CODEX_PATH=str(argv_shim),
                    CMUX_AGENT_HOOK_STATE_DIR=str(state_dir),
                    CMUX_COMPUTER_USE_MCP_DISABLED="1",
                )
                result = subprocess.run(
                    [
                        str(SOURCE_WRAPPER),
                        "exec",
                        "--skip-git-repo-check",
                        "-s",
                        "read-only",
                        "reply with the word ok",
                    ],
                    cwd=work,
                    env=environment,
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    timeout=240,
                )
                assert result.returncode == 0, result.stderr.decode("utf-8", "replace")

                arguments = [
                    argument.decode("utf-8")
                    for argument in argv_log.read_bytes().split(b"\0")
                    if argument
                ]
                assert_injection_shape(arguments[: arguments.index("exec")], "live argv")
                assignments = hook_assignments(arguments)
                assert set(ISSUE_EVENTS) <= set(assignments), (set(assignments), arguments)
                for event, values in assignments.items():
                    assert_single_cmux_group(event, values, "live argv")
                joined = "\0".join(arguments)
                for event, command in commands.items():
                    assert command not in joined, f"live argv re-declared the user {event} handler: {arguments}"

                fired = marker_log.read_text(encoding="utf-8").split() if marker_log.exists() else []
                for marker in LIVE_USER_MARKERS:
                    assert fired.count(marker) == 1, f"user {marker} handler ran {fired.count(marker)} times: {fired}"

                # cmux's handlers deliver through detached CLI calls, so give
                # them a moment, then require exactly one call per event.
                assert wait_for(
                    lambda: all(cmux_hook_calls(cli_calls).get(s, 0) >= 1 for s in LIVE_CMUX_SUBCOMMANDS), 30
                ), f"cmux hooks did not all reach the CLI: {cmux_hook_calls(cli_calls)}"
                assert wait_for(lambda: len(requests) > 0, 30), "cmux hook never reached the cmux socket"
                assert wait_for(lambda: (state_dir / "codex-hook-sessions.json").exists(), 30), (
                    f"cmux hook ledger was not written: {sorted(state_dir.iterdir())}"
                )
                # Let the detached hook runners finish with their payload files
                # before the directory goes away; this also settles any late
                # duplicate call that the exact counts below would catch.
                wait_for(lambda: not list(root.glob("cmux-codex-*")), 35)
                calls = cmux_hook_calls(cli_calls)
                assert calls.get("inject-args") == 1, f"wrapper injected {calls.get('inject-args')} times: {calls}"
                for subcommand in LIVE_CMUX_SUBCOMMANDS:
                    assert calls.get(subcommand) == 1, f"cmux {subcommand} hook ran {calls.get(subcommand)} times: {calls}"
                ledger = json.loads((state_dir / "codex-hook-sessions.json").read_text(encoding="utf-8"))
                assert ledger, "cmux hook ledger is empty"
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=2)


if __name__ == "__main__":
    test_injected_hooks_do_not_redeclare_user_hooks()
    print("PASS: injected Codex hooks carry one cmux group per event and no user handlers")
    test_persistent_cmux_hook_is_not_duplicated()
    print("PASS: persistent cmux hooks are not duplicated and user hooks are not copied")
    try:
        test_live_codex_runs_user_hooks_and_cmux_hook_once_each()
    except unittest.SkipTest as skipped:
        print(f"SKIP: live codex composition test ({skipped})")
    else:
        print("PASS: real codex ran user hooks and cmux's hook exactly once each")
