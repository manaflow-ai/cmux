#!/usr/bin/env python3
"""
Regression tests for Resources/bin/opencode wrapper plugin injection.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "opencode"
SOURCE_PLUGIN = ROOT / "Resources" / "bin" / "opencode-cmux-plugin.js"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.rstrip("\n") for line in path.read_text(encoding="utf-8").splitlines()]


def run_wrapper(*, socket_state: str, argv: list[str], existing_config: bool) -> tuple[int, list[str], list[str], str, str, list[str], str]:
    with tempfile.TemporaryDirectory(prefix="cmux-opencode-wrapper-test-") as td:
        tmp = Path(td)
        wrapper_dir = tmp / "wrapper-bin"
        real_dir = tmp / "real-bin"
        wrapper_dir.mkdir(parents=True, exist_ok=True)
        real_dir.mkdir(parents=True, exist_ok=True)

        wrapper = wrapper_dir / "opencode"
        plugin = wrapper_dir / "opencode-cmux-plugin.js"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        shutil.copy2(SOURCE_PLUGIN, plugin)
        wrapper.chmod(0o755)

        real_args_log = tmp / "real-args.log"
        cmux_log = tmp / "cmux.log"
        config_dir_log = tmp / "config-dir.log"
        overlay_log = tmp / "overlay.log"
        socket_path = str(tmp / "cmux.sock")
        existing_dir = tmp / "existing-config"

        if existing_config:
            (existing_dir / "plugins").mkdir(parents=True, exist_ok=True)
            (existing_dir / "opencode.json").write_text('{"model":"test/provider"}\n', encoding="utf-8")
            (existing_dir / "plugins" / "existing.js").write_text("module.exports = async () => ({})\n", encoding="utf-8")

        make_executable(
            real_dir / "opencode",
            """#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_REAL_ARGS_LOG"
printf '%s\n' "$@" > "$FAKE_REAL_ARGS_LOG"
printf '%s\n' "${OPENCODE_CONFIG_DIR-__UNSET__}" > "$FAKE_CONFIG_DIR_LOG"
: > "$FAKE_OVERLAY_LOG"
if [[ -n "${OPENCODE_CONFIG_DIR-}" && -d "$OPENCODE_CONFIG_DIR" ]]; then
  [[ -f "$OPENCODE_CONFIG_DIR/opencode.json" ]] && printf '%s\n' "config-json" >> "$FAKE_OVERLAY_LOG"
  [[ -f "$OPENCODE_CONFIG_DIR/plugins/existing.js" ]] && printf '%s\n' "existing-plugin" >> "$FAKE_OVERLAY_LOG"
  [[ -f "$OPENCODE_CONFIG_DIR/plugins/cmux-integration.js" ]] && printf '%s\n' "cmux-plugin" >> "$FAKE_OVERLAY_LOG"
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
        env["FAKE_CONFIG_DIR_LOG"] = str(config_dir_log)
        env["FAKE_OVERLAY_LOG"] = str(overlay_log)
        env["FAKE_CMUX_PING_OK"] = "1" if socket_state == "live" else "0"
        if existing_config:
            env["OPENCODE_CONFIG_DIR"] = str(existing_dir)

        try:
            proc = subprocess.run(
                ["opencode", *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            if test_socket is not None:
                test_socket.close()

        config_dir_lines = read_lines(config_dir_log)
        config_dir_value = config_dir_lines[0] if config_dir_lines else ""
        return (
            proc.returncode,
            read_lines(real_args_log),
            read_lines(cmux_log),
            proc.stderr.strip(),
            config_dir_value,
            read_lines(overlay_log),
            str(existing_dir),
        )


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def test_live_socket_injects_plugin_and_preserves_existing_config(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, config_dir_value, overlay, existing_dir = run_wrapper(
        socket_state="live",
        argv=["--version"],
        existing_config=True,
    )
    expect(code == 0, f"live socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["--version"], f"live socket: expected passthrough args, got {real_argv}", failures)
    expect(config_dir_value not in {"", "__UNSET__"}, "live socket: missing OPENCODE_CONFIG_DIR", failures)
    expect(config_dir_value != existing_dir, "live socket: expected overlay config dir, got original path", failures)
    expect("config-json" in overlay, f"live socket: missing overlaid opencode.json: {overlay}", failures)
    expect("existing-plugin" in overlay, f"live socket: missing existing plugin in overlay: {overlay}", failures)
    expect("cmux-plugin" in overlay, f"live socket: missing cmux integration plugin in overlay: {overlay}", failures)
    expect(any("ping" in line for line in cmux_log), f"live socket: expected cmux ping, got {cmux_log}", failures)
    expect(any(line == "clear-status opencode" for line in cmux_log), f"live socket: expected clear-status cleanup, got {cmux_log}", failures)
    expect(any(line == "clear-notifications" for line in cmux_log), f"live socket: expected clear-notifications cleanup, got {cmux_log}", failures)


def test_missing_socket_skips_plugin_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, config_dir_value, overlay, existing_dir = run_wrapper(
        socket_state="missing",
        argv=["--version"],
        existing_config=True,
    )
    expect(code == 0, f"missing socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["--version"], f"missing socket: expected passthrough args, got {real_argv}", failures)
    expect(cmux_log == [], f"missing socket: expected no cmux calls, got {cmux_log}", failures)
    expect(config_dir_value == existing_dir, f"missing socket: expected original config dir, got {config_dir_value!r}", failures)
    expect("cmux-plugin" not in overlay, f"missing socket: unexpected injected plugin overlay: {overlay}", failures)


def test_stale_socket_skips_plugin_injection(failures: list[str]) -> None:
    code, real_argv, cmux_log, stderr, config_dir_value, overlay, existing_dir = run_wrapper(
        socket_state="stale",
        argv=["--version"],
        existing_config=True,
    )
    expect(code == 0, f"stale socket: wrapper exited {code}: {stderr}", failures)
    expect(real_argv == ["--version"], f"stale socket: expected passthrough args, got {real_argv}", failures)
    expect(any("ping" in line for line in cmux_log), f"stale socket: expected cmux ping probe, got {cmux_log}", failures)
    expect(config_dir_value == existing_dir, f"stale socket: expected original config dir, got {config_dir_value!r}", failures)
    expect("cmux-plugin" not in overlay, f"stale socket: unexpected injected plugin overlay: {overlay}", failures)


def main() -> int:
    failures: list[str] = []
    test_live_socket_injects_plugin_and_preserves_existing_config(failures)
    test_missing_socket_skips_plugin_injection(failures)
    test_stale_socket_skips_plugin_injection(failures)

    if failures:
        print("FAIL: opencode wrapper regression checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: opencode wrapper injects cmux plugin only when the cmux socket is live")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
