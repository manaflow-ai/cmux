#!/usr/bin/env python3
"""
Regression: relay-backed shell integration must keep retrying report_tty until
the app returns an OK JSON-RPC response, not just a successful transport round
trip.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHELL_DIR = ROOT / "Resources" / "shell-integration"


def _write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def _run_shell(
    shell: str,
    shell_args: list[str],
    integration_path: Path,
    tty_name: str,
    bin_dir: Path,
    log_path: Path,
    state_path: Path,
) -> tuple[int, str]:
    env = dict(os.environ)
    env.update(
        {
            "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": "127.0.0.1:64011",
            "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
            "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
            "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            "CMUX_TEST_LOG": str(log_path),
            "CMUX_TEST_STATE": str(state_path),
            "CMUX_TEST_BIN_DIR": str(bin_dir),
        }
    )
    command = f"""
source "{integration_path}"
PATH="$CMUX_TEST_BIN_DIR:$PATH"
hash -r 2>/dev/null || true
: > "{log_path}"
rm -f "{state_path}"
_CMUX_TTY_NAME={tty_name}
_CMUX_TTY_REPORTED=0
_cmux_report_tty_once || true
first="${{_CMUX_TTY_REPORTED}}:$(wc -l < "{log_path}" | tr -d ' ')"
_cmux_report_tty_once || true
second="${{_CMUX_TTY_REPORTED}}:$(wc -l < "{log_path}" | tr -d ' ')"
printf '%s\\n' "$first|$second"
""".strip()
    result = subprocess.run(
        [shell, *shell_args, command],
        env=env,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    return result.returncode, ((result.stdout or "") + (result.stderr or "")).strip()


def main() -> int:
    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="cmux-ssh-relay-report-tty-retry-") as td:
        tmp = Path(td)
        bin_dir = tmp / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)
        log_path = tmp / "relay.log"
        state_path = tmp / "relay.state"

        _write_executable(
            bin_dir / "cmux",
            """#!/bin/sh
count=0
if [ -r "$CMUX_TEST_STATE" ]; then
    count=$(cat "$CMUX_TEST_STATE")
fi
count=$((count + 1))
printf '%s' "$count" > "$CMUX_TEST_STATE"
printf '%s\n' "$*" >> "$CMUX_TEST_LOG"
if [ "$count" -eq 1 ]; then
    printf '%s\n' '{"ok":false,"error":{"code":"not_found"}}'
else
    printf '%s\n' '{"ok":true,"result":{}}'
fi
""",
        )

        cases = [
            (
                "zsh",
                ["-f", "-c"],
                SHELL_DIR / "cmux-zsh-integration.zsh",
                "ttys777",
            ),
            (
                "bash",
                ["--noprofile", "--norc", "-c"],
                SHELL_DIR / "cmux-bash-integration.bash",
                "ttys888",
            ),
        ]

        for shell, shell_args, integration_path, tty_name in cases:
            code, output = _run_shell(
                shell=shell,
                shell_args=shell_args,
                integration_path=integration_path,
                tty_name=tty_name,
                bin_dir=bin_dir,
                log_path=log_path,
                state_path=state_path,
            )
            if code != 0:
                failures.append(f"{shell} exited {code}: {output}")
                continue
            if output != "0:1|1:2":
                failures.append(f"{shell} expected 0:1|1:2, got {output!r}")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print("PASS: relay report_tty retries until the app returns ok=true")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
