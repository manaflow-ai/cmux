#!/usr/bin/env python3
"""Regression checks for a captured `--settings <path>` that no longer exists.

Launchers such as subrouter (`sr claude`) hand Claude an ephemeral settings file
(`$TMPDIR/subrouter-claude-settings-<rand>/settings.json`) and delete it when
they exit. cmux captures the launch argv, so `cmux restore claude <id>` replays
`--settings <that path>` after the file is gone. The wrapper's settings merge
then fails on ENOENT and the dead path was still forwarded to Claude, which
hard-errors with `Settings file not found`, so the restored session never
starts.

The fake `claude` below reproduces that part of the real CLI: a `--settings`
path that does not exist is a fatal error. Every check asserts that exactly one
`--settings` reaches Claude and that it is cmux's own (readable) hook settings
file, so a dead user path degrades to a working launch with a warning instead
of a failed restore.
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

from node_runtime import ensure_node_on_path
from test_claude_wrapper_hooks import generated_claude_hook_settings


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"
SESSION_ID = "3d1d5a5a-6d36-4d3a-9a3c-1d4f0e6c2b7a"
DEAD_SETTINGS_PATH = "/var/folders/zz/T/subrouter-claude-settings-3294281412/settings.json"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def settings_values(argv: list[str]) -> list[str]:
    values: list[str] = []
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--settings" and index + 1 < len(argv):
            values.append(argv[index + 1])
            index += 2
            continue
        if arg.startswith("--settings="):
            values.append(arg[len("--settings="):])
        index += 1
    return values


def decode_launch_argv(encoded: str) -> list[str]:
    if not encoded or encoded == "__UNSET__":
        return []
    raw = base64.b64decode(encoded)
    return [part.decode("utf-8") for part in raw.split(b"\0") if part]


def run_wrapper(
    argv: list[str],
    *,
    with_node: bool = True,
    home_files: dict[str, str] | None = None,
) -> tuple[int, list[str], str, list[str], list[str]]:
    """Run the wrapper against a fake claude.

    Returns (exit code, claude argv, stderr, captured launch argv, settings
    documents as claude read them, in argv order).
    """
    with tempfile.TemporaryDirectory(prefix="cmux-claude-dead-settings-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "cmux.app" / "Contents" / "Resources" / "bin"
        real_dir = tmp / "real-bin"
        bundled_dir = tmp / "bundled cli"
        home = tmp / "home"
        for directory in (wrapper_dir, real_dir, bundled_dir, home):
            directory.mkdir(parents=True, exist_ok=True)
        for relative, content in (home_files or {}).items():
            target = home / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")

        wrapper = wrapper_dir / "cmux-claude-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        launch_argv_log = tmp / "launch-argv.log"
        settings_docs_log = tmp / "settings-docs.log"
        socket_path = str(tmp / "cmux.sock")

        # Mirrors the real CLI: a --settings path that cannot be read is fatal.
        make_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
printf '%s\\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-__UNSET__}" > "$FAKE_LAUNCH_ARGV_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"
done
if [[ "${1:-}" == "--help" ]]; then
  printf 'Usage: claude [options] [command] [prompt]\\n'
  exit 0
fi
expect_value=0
for arg in "$@"; do
  value=""
  if (( expect_value )); then
    value="$arg"
    expect_value=0
  elif [[ "$arg" == "--settings" ]]; then
    expect_value=1
    continue
  elif [[ "$arg" == --settings=* ]]; then
    value="${arg#--settings=}"
  else
    continue
  fi
  trimmed="${value#"${value%%[![:space:]]*}"}"
  if [[ "$trimmed" == \\{* || "$trimmed" == \\[* ]]; then
    printf '%s\\n' "$value" >> "$FAKE_SETTINGS_DOCS_LOG"
  elif [[ -r "$value" ]]; then
    # Snapshot the document Claude would read now; the wrapper's private
    # settings file lives under a TMPDIR the harness deletes afterwards.
    tr -d '\\n' < "$value" >> "$FAKE_SETTINGS_DOCS_LOG"
    printf '\\n' >> "$FAKE_SETTINGS_DOCS_LOG"
  else
    printf 'Error: Settings file not found: %s\\n' "$value" >&2
    exit 1
  fi
done
exit 0
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

        env = os.environ.copy()
        system_path = "/usr/bin:/bin"
        if with_node:
            node = ensure_node_on_path()
            assert node is not None
            system_path = f"{Path(node).parent}:{system_path}"
        env["PATH"] = f"{wrapper_dir}:{real_dir}:{system_path}"
        env["HOME"] = str(home)
        env["TMPDIR"] = str(tmp / "tmp")
        (tmp / "tmp").mkdir(exist_ok=True)
        env["CMUX_SURFACE_ID"] = "surface:test"
        env["CMUX_SOCKET_PATH"] = socket_path
        env["CMUX_BUNDLED_CLI_PATH"] = str(bundled_cli)
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_LAUNCH_ARGV_LOG"] = str(launch_argv_log)
        env["FAKE_SETTINGS_DOCS_LOG"] = str(settings_docs_log)
        env["FAKE_GENERATED_CLAUDE_HOOK_SETTINGS"] = generated_claude_hook_settings()
        for key in (
            "CMUX_CLAUDE_HOOKS_DISABLED",
            "CMUX_CLAUDE_HOOK_CMUX_BIN",
            "CMUX_AGENT_RESTORE_LAUNCH",
            "CMUX_AGENT_LAUNCH_ARGV_B64",
            "NODE_OPTIONS",
        ):
            env.pop(key, None)

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

        launch_argv_lines = read_lines(launch_argv_log)
        captured = decode_launch_argv(launch_argv_lines[0] if launch_argv_lines else "")
        return (
            proc.returncode,
            read_lines(real_args_log),
            proc.stderr.strip(),
            captured,
            read_lines(settings_docs_log),
        )


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def assert_single_cmux_hook_settings(
    label: str,
    code: int,
    real_argv: list[str],
    stderr: str,
    documents: list[str],
    failures: list[str],
) -> dict:
    expect(code == 0, f"{label}: claude exited {code} (stderr: {stderr!r}; argv: {real_argv})", failures)
    values = settings_values(real_argv)
    expect(len(values) == 1, f"{label}: expected exactly one --settings, got {values} in {real_argv}", failures)
    expect(
        DEAD_SETTINGS_PATH not in real_argv and f"--settings={DEAD_SETTINGS_PATH}" not in real_argv,
        f"{label}: dead settings path still reached claude: {real_argv}",
        failures,
    )
    if len(documents) != 1:
        failures.append(f"{label}: claude could read {len(documents)} settings documents, expected 1: {values}")
        return {}
    try:
        settings = json.loads(documents[0])
    except ValueError as exc:
        failures.append(f"{label}: the surviving --settings is not JSON: {documents[0]!r} ({exc})")
        return {}
    hook_text = json.dumps(settings.get("hooks", {}))
    expect(
        "hooks" in settings and ("hooks claude" in hook_text or "hooks feed" in hook_text),
        f"{label}: surviving --settings is not cmux's hook settings: {settings}",
        failures,
    )
    return settings


def test_restore_replay_with_dead_settings_path_launches(failures: list[str]) -> None:
    code, real_argv, stderr, captured, documents = run_wrapper(
        ["--resume", SESSION_ID, "--settings", DEAD_SETTINGS_PATH]
    )
    assert_single_cmux_hook_settings("restore replay", code, real_argv, stderr, documents, failures)
    expect(
        real_argv[:2] == ["--resume", SESSION_ID] or ["--resume", SESSION_ID] == real_argv[-2:],
        f"restore replay: --resume <id> was not preserved: {real_argv}",
        failures,
    )
    expect(
        DEAD_SETTINGS_PATH in stderr and "warning" in stderr,
        f"restore replay: expected a warning naming the dead path, got {stderr!r}",
        failures,
    )
    expect(
        DEAD_SETTINGS_PATH not in captured,
        f"restore replay: dead path was re-captured for the next restore: {captured}",
        failures,
    )


def test_dead_settings_equals_form_is_dropped(failures: list[str]) -> None:
    code, real_argv, stderr, captured, documents = run_wrapper([f"--settings={DEAD_SETTINGS_PATH}", "hello"])
    assert_single_cmux_hook_settings("equals form", code, real_argv, stderr, documents, failures)
    expect(real_argv[-1:] == ["hello"], f"equals form: positional prompt dropped: {real_argv}", failures)
    expect(DEAD_SETTINGS_PATH not in stderr or "warning" in stderr, f"equals form: {stderr!r}", failures)
    expect(
        not any(DEAD_SETTINGS_PATH in part for part in captured),
        f"equals form: dead path was re-captured: {captured}",
        failures,
    )


def test_dead_path_keeps_other_user_settings(failures: list[str]) -> None:
    code, real_argv, stderr, _, documents = run_wrapper(
        ["--settings", DEAD_SETTINGS_PATH, "--settings", '{"effortLevel":"max"}', "hi"]
    )
    settings = assert_single_cmux_hook_settings("mixed settings", code, real_argv, stderr, documents, failures)
    expect(
        settings.get("effortLevel") == "max",
        f"mixed settings: the readable user settings were lost with the dead one: {settings}",
        failures,
    )
    expect(real_argv[-1:] == ["hi"], f"mixed settings: positional prompt dropped: {real_argv}", failures)


def test_tilde_dead_path_is_dropped(failures: list[str]) -> None:
    code, real_argv, stderr, _, _ = run_wrapper(["--settings", "~/missing-settings.json", "hi"])
    expect(code == 0, f"tilde dead path: claude exited {code} (stderr: {stderr!r}; argv: {real_argv})", failures)
    values = settings_values(real_argv)
    expect(len(values) == 1, f"tilde dead path: expected exactly one --settings, got {values}", failures)
    expect("~/missing-settings.json" not in values, f"tilde dead path: still forwarded: {real_argv}", failures)


def test_existing_user_settings_file_is_still_merged(failures: list[str]) -> None:
    code, real_argv, stderr, _, documents = run_wrapper(
        ["--settings", "~/present-settings.json", "hi"],
        home_files={"present-settings.json": '{"ultracode": true}'},
    )
    settings = assert_single_cmux_hook_settings("existing file", code, real_argv, stderr, documents, failures)
    expect(settings.get("ultracode") is True, f"existing file: user settings were not merged: {settings}", failures)
    expect("warning" not in stderr, f"existing file: unexpected warning for a readable file: {stderr!r}", failures)


def test_dead_path_without_node_still_launches_with_cmux_hooks(failures: list[str]) -> None:
    code, real_argv, stderr, captured, documents = run_wrapper(
        ["--resume", SESSION_ID, "--settings", DEAD_SETTINGS_PATH],
        with_node=False,
    )
    assert_single_cmux_hook_settings("no node", code, real_argv, stderr, documents, failures)
    expect(
        DEAD_SETTINGS_PATH not in captured,
        f"no node: dead path was re-captured for the next restore: {captured}",
        failures,
    )


def main() -> int:
    if ensure_node_on_path() is None:
        print("SKIP: node runtime not found; the wrapper's settings merge needs node")
        return 0
    failures: list[str] = []
    test_restore_replay_with_dead_settings_path_launches(failures)
    test_dead_settings_equals_form_is_dropped(failures)
    test_dead_path_keeps_other_user_settings(failures)
    test_tilde_dead_path_is_dropped(failures)
    test_existing_user_settings_file_is_still_merged(failures)
    test_dead_path_without_node_still_launches_with_cmux_hooks(failures)
    if failures:
        print("FAIL: a dead --settings path still breaks the cmux claude wrapper launch")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: a dead --settings path is dropped and exactly one cmux hook --settings reaches claude")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
