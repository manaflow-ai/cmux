#!/usr/bin/env python3
"""
Regression tests for Resources/bin/cmux-codex-wrapper notify injection
(agent conversation live hook ingest, docs/agent-conversation-protocol.md).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-codex-wrapper"


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def run_wrapper(
    argv: list[str],
    *,
    in_cmux: bool = True,
    hooks_disabled: bool = False,
    agent_hook_emit: str | None = "executable",
    config_toml: str | None = None,
) -> tuple[int, list[str], str]:
    """Returns (exit code, argv the real codex received, stderr).

    agent_hook_emit: "executable" stages an executable emit relay,
    "missing" sets the env without the binary, None leaves the env unset.
    """
    with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        codex_home = tmp / "codex-home"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)
        codex_home.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "cmux-codex-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        make_executable(
            real_dir / "codex",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
for arg in "$@"; do
  printf '%s\\n' "$arg" >> "$FAKE_REAL_ARGS_LOG"
done
exit 0
""",
        )

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:{env.get('PATH', '/usr/bin:/bin')}"
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["CODEX_HOME"] = str(codex_home)
        env.pop("CMUX_AGENT_HOOK_EMIT_BIN", None)
        env.pop("CMUX_AGENT_HOOK_SOCKET", None)
        env.pop("CMUX_CODEX_HOOKS_DISABLED", None)
        if in_cmux:
            env["CMUX_SURFACE_ID"] = "surface:test"
        else:
            env.pop("CMUX_SURFACE_ID", None)
        if hooks_disabled:
            env["CMUX_CODEX_HOOKS_DISABLED"] = "1"
        if agent_hook_emit is not None:
            # Directory with a space mirrors real DerivedData staging paths.
            emit_dir = tmp / "remote daemons"
            emit_dir.mkdir(parents=True, exist_ok=True)
            emit_bin = emit_dir / "cmuxd-remote"
            if agent_hook_emit == "executable":
                make_executable(emit_bin, "#!/usr/bin/env bash\nexit 0\n")
            env["CMUX_AGENT_HOOK_EMIT_BIN"] = str(emit_bin)
            env["CMUX_AGENT_HOOK_SOCKET"] = str(tmp / "agentconv" / "ingest.sock")
        if config_toml is not None:
            (codex_home / "config.toml").write_text(config_toml, encoding="utf-8")

        proc = subprocess.run(
            [str(wrapper), *argv],
            cwd=tmp,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        real_argv = (
            [line for line in real_args_log.read_text(encoding="utf-8").splitlines()]
            if real_args_log.exists()
            else []
        )
        return proc.returncode, real_argv, proc.stderr.strip()


def injected_notify_values(real_argv: list[str]) -> list[str]:
    values: list[str] = []
    for index, arg in enumerate(real_argv):
        if arg == "-c" and index + 1 < len(real_argv) and real_argv[index + 1].startswith("notify="):
            values.append(real_argv[index + 1])
    return values


def test_injects_per_launch_notify_override(failures: list[str]) -> None:
    code, real_argv, stderr = run_wrapper(["resume", "thread-1"])
    expect(code == 0, f"inject: wrapper exited {code}: {stderr}", failures)
    notify = injected_notify_values(real_argv)
    expect(len(notify) == 1, f"inject: expected one notify override, got {real_argv}", failures)
    if notify:
        expect(
            '","agent-hook-emit","--socket","' in notify[0]
            and notify[0].endswith('","--provider","codex"]'),
            f"inject: notify argv shape mismatch: {notify[0]!r}",
            failures,
        )
        expect("cmuxd-remote" in notify[0], f"inject: notify should call the staged relay: {notify[0]!r}", failures)
        expect("ingest.sock" in notify[0], f"inject: notify should target the ingest socket: {notify[0]!r}", failures)
    expect(real_argv[:2] == ["-c", notify[0]] if notify else False,
           f"inject: -c override must precede the subcommand, got {real_argv}", failures)
    expect(real_argv[-2:] == ["resume", "thread-1"],
           f"inject: original args must pass through, got {real_argv}", failures)


def test_outside_cmux_passes_through(failures: list[str]) -> None:
    code, real_argv, stderr = run_wrapper(["resume"], in_cmux=False)
    expect(code == 0, f"outside cmux: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["resume"], f"outside cmux: expected passthrough, got {real_argv}", failures)


def test_disabled_integration_passes_through(failures: list[str]) -> None:
    code, real_argv, stderr = run_wrapper([], hooks_disabled=True)
    expect(code == 0, f"disabled: wrapper exited {code}: {stderr}", failures)
    expect(injected_notify_values(real_argv) == [], f"disabled: expected no notify override, got {real_argv}", failures)


def test_missing_env_passes_through(failures: list[str]) -> None:
    code, real_argv, stderr = run_wrapper([], agent_hook_emit=None)
    expect(code == 0, f"missing env: wrapper exited {code}: {stderr}", failures)
    expect(injected_notify_values(real_argv) == [], f"missing env: expected no notify override, got {real_argv}", failures)


def test_missing_emit_binary_passes_through(failures: list[str]) -> None:
    code, real_argv, stderr = run_wrapper([], agent_hook_emit="missing")
    expect(code == 0, f"missing binary: wrapper exited {code}: {stderr}", failures)
    expect(injected_notify_values(real_argv) == [], f"missing binary: expected no notify override, got {real_argv}", failures)


def test_user_cli_notify_override_wins(failures: list[str]) -> None:
    user_override = 'notify=["my-notifier"]'
    code, real_argv, stderr = run_wrapper(["-c", user_override])
    expect(code == 0, f"user -c notify: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["-c", user_override],
           f"user -c notify: expected untouched passthrough, got {real_argv}", failures)


def test_user_config_toml_notify_wins(failures: list[str]) -> None:
    code, real_argv, stderr = run_wrapper(
        [],
        config_toml='model = "gpt-5.1-codex"\nnotify = ["my-notifier"]\n',
    )
    expect(code == 0, f"config.toml notify: wrapper exited {code}: {stderr}", failures)
    expect(injected_notify_values(real_argv) == [],
           f"config.toml notify: expected no override of the user's notifier, got {real_argv}", failures)


def test_commented_config_toml_notify_does_not_block(failures: list[str]) -> None:
    code, real_argv, stderr = run_wrapper(
        [],
        config_toml='# notify = ["my-notifier"]\n',
    )
    expect(code == 0, f"commented notify: wrapper exited {code}: {stderr}", failures)
    expect(len(injected_notify_values(real_argv)) == 1,
           f"commented notify: expected injection, got {real_argv}", failures)


def test_help_passes_through(failures: list[str]) -> None:
    code, real_argv, stderr = run_wrapper(["--help"])
    expect(code == 0, f"--help: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["--help"], f"--help: expected untouched passthrough, got {real_argv}", failures)


def main() -> int:
    failures: list[str] = []
    test_injects_per_launch_notify_override(failures)
    test_outside_cmux_passes_through(failures)
    test_disabled_integration_passes_through(failures)
    test_missing_env_passes_through(failures)
    test_missing_emit_binary_passes_through(failures)
    test_user_cli_notify_override_wins(failures)
    test_user_config_toml_notify_wins(failures)
    test_commented_config_toml_notify_does_not_block(failures)
    test_help_passes_through(failures)

    if failures:
        print("FAIL: codex wrapper notify checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: codex wrapper injects the per-launch notify override and never clobbers user notify config")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
