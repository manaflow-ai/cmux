#!/usr/bin/env python3
"""
Regression tests for Resources/bin/codex wrapper hook injection.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "codex"
SOURCE_NOTIFY = ROOT / "Resources" / "bin" / "codex-cmux-notify.sh"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def run_wrapper(
    *,
    socket_state: str,
    argv: list[str],
    existing_config: bool,
) -> tuple[int, list[str], list[str], str, list[str], str]:
    with tempfile.TemporaryDirectory(prefix="cmux-codex-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "codex"
        notify = wrapper_dir / "codex-cmux-notify.sh"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        shutil.copy2(SOURCE_NOTIFY, notify)
        wrapper.chmod(0o755)
        notify.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        cmux_log = tmp / "cmux.log"
        codex_home_log = tmp / "codex-home.log"
        overlay_log = tmp / "overlay.log"
        socket_path = str(tmp / "cmux.sock")
        existing_dir = tmp / "existing-codex-home"

        if existing_config:
            existing_dir.mkdir(parents=True, exist_ok=True)
            (existing_dir / "config.toml").write_text(
                'model = "gpt-5.4"\nnotify = ["echo", "old"]\n',
                encoding="utf-8",
            )
            (existing_dir / "sessions").mkdir(parents=True, exist_ok=True)
            (existing_dir / "sessions" / "test.json").write_text("{}\n", encoding="utf-8")

        make_executable(
            real_dir / "codex",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
printf '%s\n' "$@" > "$FAKE_REAL_ARGS_LOG"
printf '%s\n' "${CODEX_HOME-__UNSET__}" > "$FAKE_CODEX_HOME_LOG"
: > "$FAKE_OVERLAY_LOG"
if [[ -n "${CODEX_HOME-}" && -d "$CODEX_HOME" ]]; then
  [[ -f "$CODEX_HOME/config.toml" ]] && printf '%s\n' "config-toml" >> "$FAKE_OVERLAY_LOG"
  [[ -f "$CODEX_HOME/hooks.json" ]] && printf '%s\n' "hooks-json" >> "$FAKE_OVERLAY_LOG"
  [[ -L "$CODEX_HOME/sessions" ]] && printf '%s\n' "sessions-symlink" >> "$FAKE_OVERLAY_LOG"
  # Check that existing notify was stripped and ours injected
  if grep -q 'codex-cmux-notify' "$CODEX_HOME/config.toml" 2>/dev/null; then
    printf '%s\n' "cmux-notify-injected" >> "$FAKE_OVERLAY_LOG"
  fi
  if grep -q 'model = "gpt-5.4"' "$CODEX_HOME/config.toml" 2>/dev/null; then
    printf '%s\n' "user-model-preserved" >> "$FAKE_OVERLAY_LOG"
  fi
  if grep -q '^notify = \\["echo"' "$CODEX_HOME/config.toml" 2>/dev/null; then
    printf '%s\n' "old-notify-leaked" >> "$FAKE_OVERLAY_LOG"
  fi
fi
true
""",
        )

        make_executable(
            wrapper_dir / "cmux",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CMUX_LOG"
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
            test_socket.bind(socket_path)

        env = os.environ.copy()
        env["PATH"] = f"{wrapper_dir}:{real_dir}:/usr/bin:/bin"
        env["CMUX_SURFACE_ID"] = "surface:test"
        env["CMUX_SOCKET_PATH"] = socket_path
        env["FAKE_REAL_ARGS_LOG"] = str(real_args_log)
        env["FAKE_CMUX_LOG"] = str(cmux_log)
        env["FAKE_CODEX_HOME_LOG"] = str(codex_home_log)
        env["FAKE_OVERLAY_LOG"] = str(overlay_log)
        env["FAKE_CMUX_PING_OK"] = "1" if socket_state == "live" else "0"
        if existing_config:
            env["CODEX_HOME"] = str(existing_dir)
        else:
            env.pop("CODEX_HOME", None)

        try:
            proc = subprocess.run(
                ["codex", *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            if test_socket is not None:
                test_socket.close()

        codex_home_lines = read_lines(codex_home_log)
        codex_home_value = codex_home_lines[0] if codex_home_lines else ""
        return (
            proc.returncode,
            read_lines(real_args_log),
            read_lines(cmux_log),
            codex_home_value,
            read_lines(overlay_log),
            str(existing_dir),
        )


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def test_live_socket_injects_hooks_and_preserves_config(failures: list[str]) -> None:
    code, real_argv, cmux_log, codex_home, overlay, existing_dir = run_wrapper(
        socket_state="live",
        argv=["--version"],
        existing_config=True,
    )
    expect(code == 0, f"live socket: wrapper exited {code}", failures)
    expect(real_argv == ["--version"], f"live socket: expected passthrough args, got {real_argv}", failures)
    expect(codex_home not in {"", "__UNSET__"}, "live socket: missing CODEX_HOME", failures)
    expect(codex_home != existing_dir, "live socket: expected overlay CODEX_HOME, got original path", failures)
    expect("config-toml" in overlay, f"live socket: missing config.toml in overlay: {overlay}", failures)
    expect("hooks-json" in overlay, f"live socket: missing hooks.json in overlay: {overlay}", failures)
    expect("sessions-symlink" in overlay, f"live socket: missing sessions symlink in overlay: {overlay}", failures)
    expect("cmux-notify-injected" in overlay, f"live socket: cmux notify not injected in config.toml: {overlay}", failures)
    expect("user-model-preserved" in overlay, f"live socket: user model setting lost: {overlay}", failures)
    expect("old-notify-leaked" not in overlay, f"live socket: old notify command leaked through: {overlay}", failures)
    expect(any("ping" in line for line in cmux_log), f"live socket: expected cmux ping, got {cmux_log}", failures)
    expect(any(line == "clear-status codex" for line in cmux_log), f"live socket: expected clear-status cleanup, got {cmux_log}", failures)
    # clear-notifications is intentionally omitted — it is workspace-global and
    # would wipe notifications from other agents/sessions in the same surface.
    expect(not any(line == "clear-notifications" for line in cmux_log), f"live socket: clear-notifications should NOT be called (workspace-global), got {cmux_log}", failures)


def test_missing_socket_skips_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, codex_home, overlay, existing_dir = run_wrapper(
        socket_state="missing",
        argv=["--version"],
        existing_config=True,
    )
    expect(code == 0, f"missing socket: wrapper exited {code}", failures)
    expect(real_argv == ["--version"], f"missing socket: expected passthrough args, got {real_argv}", failures)
    expect(cmux_log == [], f"missing socket: expected no cmux calls, got {cmux_log}", failures)
    expect(codex_home == existing_dir, f"missing socket: expected original CODEX_HOME, got {codex_home!r}", failures)
    expect("hooks-json" not in overlay, f"missing socket: unexpected hooks.json in overlay: {overlay}", failures)


def test_stale_socket_skips_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, codex_home, overlay, existing_dir = run_wrapper(
        socket_state="stale",
        argv=["--version"],
        existing_config=True,
    )
    expect(code == 0, f"stale socket: wrapper exited {code}", failures)
    expect(real_argv == ["--version"], f"stale socket: expected passthrough args, got {real_argv}", failures)
    expect(any("ping" in line for line in cmux_log), f"stale socket: expected cmux ping probe, got {cmux_log}", failures)
    expect(codex_home == existing_dir, f"stale socket: expected original CODEX_HOME, got {codex_home!r}", failures)
    expect("hooks-json" not in overlay, f"stale socket: unexpected hooks.json in overlay: {overlay}", failures)


def test_no_existing_config_creates_fresh_overlay(failures: list[str]) -> None:
    code, _, _, codex_home, overlay, _ = run_wrapper(
        socket_state="live",
        argv=[],
        existing_config=False,
    )
    expect(code == 0, f"no config: wrapper exited {code}", failures)
    expect(codex_home not in {"", "__UNSET__"}, "no config: missing CODEX_HOME", failures)
    expect("config-toml" in overlay, f"no config: missing config.toml: {overlay}", failures)
    expect("hooks-json" in overlay, f"no config: missing hooks.json: {overlay}", failures)
    expect("cmux-notify-injected" in overlay, f"no config: cmux notify not injected: {overlay}", failures)


def main() -> int:
    failures: list[str] = []
    test_live_socket_injects_hooks_and_preserves_config(failures)
    test_missing_socket_skips_injection(failures)
    test_stale_socket_skips_injection(failures)
    test_no_existing_config_creates_fresh_overlay(failures)

    if failures:
        print("FAIL: codex wrapper regression checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: codex wrapper injects hooks and notify only when the cmux socket is live")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
