#!/usr/bin/env python3
"""Regression checks for the wrapper-attested Subrouter claude resume marker.

`sr claude proxy` launches Claude with a private, per-launch `--settings` file
under `$TMPDIR/subrouter-claude-settings-<rand>/settings.json` (the proxy
token, account routing headers and base URL live only there; a guardian
deletes it when `sr` exits) and exports
`SUBROUTER_CLAUDE_RESUME_COMMAND="sr claude proxy --resume"` so a host can
resume through the same launcher once that file is gone.

That marker leaks to every descendant of the launched Claude, so it is not
proof on its own. The wrapper is the one process that still sees Subrouter's
private `--settings` argument (its settings merge drops user `--settings`
before the argv is captured for restore), so it binds the marker to THIS launch
as `CMUX_AGENT_LAUNCH_SUBROUTER_CLAUDE_RESUME_COMMAND` only when:

- the marker is one of the exact launcher commands, and
- the argv carries an existing `--settings` file inside a
  `subrouter-claude-settings-*` directory.

Anything else (an inherited marker under a plain `claude`, a stale bound copy
from an ancestor, a dead path from a replayed restore, non-exact marker text)
must leave the bound key unset, so restore keeps its existing behavior.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path

from node_runtime import ensure_node_on_path
from test_claude_wrapper_hooks import generated_claude_hook_settings


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"
MARKER_KEY = "SUBROUTER_CLAUDE_RESUME_COMMAND"
BOUND_KEY = "CMUX_AGENT_LAUNCH_SUBROUTER_CLAUDE_RESUME_COMMAND"
SR_MARKER = "sr claude proxy --resume"
SUBROUTER_MARKER = "subrouter claude proxy --resume"
SESSION_ID = "0198f073-0a5b-7000-8000-000000000059"
PRIVATE_SETTINGS_BODY = (
    '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:31415/v1",'
    '"ANTHROPIC_AUTH_TOKEN":"srt_test_only_not_a_real_token",'
    '"ANTHROPIC_CUSTOM_HEADERS":"X-Subrouter-Agent: claude"}}'
)


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_env_log(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    env: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if sep:
            env[key] = value
    return env


def run_wrapper(
    argv_builder,
    *,
    marker: str | None,
    inherited_bound: str | None = None,
) -> tuple[int, dict[str, str], list[str], str]:
    """Run the wrapper against a fake claude that records its environment.

    `argv_builder(tmp)` returns the argv, so a scenario can point --settings at
    a file it creates under the harness TMPDIR (or at one it deliberately does
    not create). Returns (exit code, claude env, claude argv, stderr).
    """
    with tempfile.TemporaryDirectory(prefix="cmux-claude-sr-marker-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "cmux.app" / "Contents" / "Resources" / "bin"
        real_dir = tmp / "real-bin"
        bundled_dir = tmp / "bundled cli"
        home = tmp / "home"
        tmpdir = tmp / "tmp"
        for directory in (wrapper_dir, real_dir, bundled_dir, home, tmpdir):
            directory.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "cmux-claude-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        env_log = tmp / "claude-env.log"
        args_log = tmp / "claude-args.log"
        socket_path = str(tmp / "cmux.sock")

        make_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_CLAUDE_ARGS_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_CLAUDE_ARGS_LOG"
done
env > "$FAKE_CLAUDE_ENV_LOG"
if [[ "${1:-}" == "--help" ]]; then
  printf 'Usage: claude [options] [command] [prompt]\\n'
fi
exit 0
""",
        )
        make_executable(
            wrapper_dir / "cmux",
            """#!/usr/bin/env bash
exit 0
""",
        )
        bundled_cli = bundled_dir / "cmux"
        make_executable(
            bundled_cli,
            """#!/usr/bin/env bash
if [[ "${1:-}" == "hooks" && "${2:-}" == "claude" && "${3:-}" == "inject-settings" ]]; then
  printf '%s' "$FAKE_GENERATED_CLAUDE_HOOK_SETTINGS"
  exit 0
fi
exit 0
""",
        )

        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        test_socket.bind(socket_path)

        node = ensure_node_on_path()
        assert node is not None
        env = {
            "PATH": f"{wrapper_dir}:{real_dir}:{Path(node).parent}:/usr/bin:/bin",
            "HOME": str(home),
            "TMPDIR": str(tmpdir),
            "CMUX_SURFACE_ID": "surface:test",
            "CMUX_SOCKET_PATH": socket_path,
            "CMUX_BUNDLED_CLI_PATH": str(bundled_cli),
            "FAKE_CLAUDE_ENV_LOG": str(env_log),
            "FAKE_CLAUDE_ARGS_LOG": str(args_log),
            "FAKE_GENERATED_CLAUDE_HOOK_SETTINGS": generated_claude_hook_settings(),
        }
        if marker is not None:
            env[MARKER_KEY] = marker
        if inherited_bound is not None:
            env[BOUND_KEY] = inherited_bound

        argv = argv_builder(tmpdir)
        try:
            proc = subprocess.run(
                [str(wrapper), *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
                timeout=60,
            )
        finally:
            test_socket.close()

        claude_args = args_log.read_text(encoding="utf-8").splitlines() if args_log.exists() else []
        return proc.returncode, read_env_log(env_log), claude_args, proc.stderr.strip()


def private_settings(tmpdir: Path, *, create: bool = True, suffix: str = "3294281412") -> Path:
    directory = tmpdir / f"subrouter-claude-settings-{suffix}"
    path = directory / "settings.json"
    if create:
        directory.mkdir(parents=True, exist_ok=True)
        path.write_text(PRIVATE_SETTINGS_BODY, encoding="utf-8")
    return path


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def expect_launched(label: str, code: int, env: dict[str, str], stderr: str, failures: list[str]) -> None:
    expect(code == 0, f"{label}: wrapper exited {code} (stderr: {stderr!r})", failures)
    expect(bool(env), f"{label}: the fake claude never ran (stderr: {stderr!r})", failures)


def test_sr_launch_binds_the_marker(failures: list[str]) -> None:
    code, env, args, stderr = run_wrapper(
        lambda tmpdir: ["--settings", str(private_settings(tmpdir)), "--model", "opus"],
        marker=SR_MARKER,
    )
    expect_launched("sr launch", code, env, stderr, failures)
    expect(env.get(BOUND_KEY) == SR_MARKER, f"sr launch: bound marker = {env.get(BOUND_KEY)!r}", failures)
    expect(env.get(MARKER_KEY) == SR_MARKER, f"sr launch: marker was dropped: {env.get(MARKER_KEY)!r}", failures)
    expect("--model" in args and "opus" in args, f"sr launch: claude argv lost user options: {args}", failures)


def test_equals_form_and_subrouter_program_bind(failures: list[str]) -> None:
    code, env, _, stderr = run_wrapper(
        lambda tmpdir: [f"--settings={private_settings(tmpdir)}"],
        marker=SUBROUTER_MARKER,
    )
    expect_launched("equals form", code, env, stderr, failures)
    expect(
        env.get(BOUND_KEY) == SUBROUTER_MARKER,
        f"equals form: bound marker = {env.get(BOUND_KEY)!r}",
        failures,
    )


def test_plain_claude_under_an_sr_session_is_not_bound(failures: list[str]) -> None:
    # A nested `claude` inherits the marker from the sr-launched ancestor but
    # was not launched by sr: no private settings file in its argv.
    code, env, _, stderr = run_wrapper(lambda tmpdir: ["--model", "opus"], marker=SR_MARKER)
    expect_launched("nested claude", code, env, stderr, failures)
    expect(BOUND_KEY not in env, f"nested claude: inherited marker was bound: {env.get(BOUND_KEY)!r}", failures)


def test_stale_inherited_binding_is_cleared(failures: list[str]) -> None:
    code, env, _, stderr = run_wrapper(
        lambda tmpdir: ["--model", "opus"],
        marker=SR_MARKER,
        inherited_bound=SR_MARKER,
    )
    expect_launched("stale binding", code, env, stderr, failures)
    expect(BOUND_KEY not in env, f"stale binding: ancestor's bound copy survived: {env.get(BOUND_KEY)!r}", failures)


def test_dead_private_settings_path_is_not_bound(failures: list[str]) -> None:
    # A replayed restore of an older record still carries the deleted path.
    code, env, _, stderr = run_wrapper(
        lambda tmpdir: ["--resume", SESSION_ID, "--settings", str(private_settings(tmpdir, create=False))],
        marker=SR_MARKER,
    )
    expect_launched("dead path", code, env, stderr, failures)
    expect(BOUND_KEY not in env, f"dead path: a deleted settings path was bound: {env.get(BOUND_KEY)!r}", failures)


def test_non_exact_marker_text_is_not_bound(failures: list[str]) -> None:
    for untrusted in (
        "sr claude proxy --restore",
        "sr claude proxy --resume --account evil",
        "/tmp/evil claude proxy --resume",
        "sr claude proxy --resume; rm -rf /",
        "cx claude proxy --resume",
        "",
    ):
        code, env, _, stderr = run_wrapper(
            lambda tmpdir: ["--settings", str(private_settings(tmpdir))],
            marker=untrusted,
        )
        expect_launched(f"marker {untrusted!r}", code, env, stderr, failures)
        expect(BOUND_KEY not in env, f"marker {untrusted!r} was bound: {env.get(BOUND_KEY)!r}", failures)


def test_private_settings_without_marker_is_not_bound(failures: list[str]) -> None:
    code, env, _, stderr = run_wrapper(
        lambda tmpdir: ["--settings", str(private_settings(tmpdir))],
        marker=None,
    )
    expect_launched("no marker", code, env, stderr, failures)
    expect(BOUND_KEY not in env, f"no marker: bound without a marker: {env.get(BOUND_KEY)!r}", failures)


def test_private_settings_after_option_terminator_is_not_bound(failures: list[str]) -> None:
    code, env, _, stderr = run_wrapper(
        lambda tmpdir: ["--", "--settings", str(private_settings(tmpdir))],
        marker=SR_MARKER,
    )
    expect_launched("after --", code, env, stderr, failures)
    expect(BOUND_KEY not in env, f"after --: a literal prompt token was bound: {env.get(BOUND_KEY)!r}", failures)


def main() -> int:
    if ensure_node_on_path() is None:
        print("SKIP: node runtime not found; the wrapper's settings merge needs node")
        return 0
    failures: list[str] = []
    test_sr_launch_binds_the_marker(failures)
    test_equals_form_and_subrouter_program_bind(failures)
    test_plain_claude_under_an_sr_session_is_not_bound(failures)
    test_stale_inherited_binding_is_cleared(failures)
    test_dead_private_settings_path_is_not_bound(failures)
    test_non_exact_marker_text_is_not_bound(failures)
    test_private_settings_without_marker_is_not_bound(failures)
    test_private_settings_after_option_terminator_is_not_bound(failures)
    if failures:
        print("FAIL: the claude wrapper does not bind the Subrouter resume marker to a proven sr launch")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: the Subrouter resume marker is bound only to a proven sr claude proxy launch")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
