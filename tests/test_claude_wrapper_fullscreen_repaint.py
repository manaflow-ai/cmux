#!/usr/bin/env python3
"""Regression: cmux Claude launches default to full alternate-screen repaints."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"
REPAINT_ENV = "CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT"


def _write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _run_wrapper(fake_claude: Path, *, in_cmux: bool, repaint: str | None) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["CMUX_CUSTOM_CLAUDE_PATH"] = str(fake_claude)
    env.pop("CMUX_SOCKET_PATH", None)
    if in_cmux:
        env["CMUX_SURFACE_ID"] = "surface-full-repaint-test"
    else:
        env.pop("CMUX_SURFACE_ID", None)
    if repaint is None:
        env.pop(REPAINT_ENV, None)
    else:
        env[REPAINT_ENV] = repaint

    return subprocess.run(
        [str(WRAPPER), "--version"],
        check=False,
        capture_output=True,
        env=env,
        text=True,
        timeout=10,
    )


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-claude-full-repaint-") as td:
        fake_claude = Path(td) / "claude"
        _write_executable(
            fake_claude,
            "#!/bin/sh\n"
            f'printf \'%s\\n\' "${{{REPAINT_ENV}-__unset__}}"\n',
        )

        default_result = _run_wrapper(fake_claude, in_cmux=True, repaint=None)
        if default_result.returncode != 0 or default_result.stdout.strip() != "1":
            failures.append(
                "cmux launch should default Claude fullscreen rendering to full repaints; "
                f"got rc={default_result.returncode}, stdout={default_result.stdout!r}, "
                f"stderr={default_result.stderr!r}"
            )

        override_result = _run_wrapper(fake_claude, in_cmux=True, repaint="0")
        if override_result.returncode != 0 or override_result.stdout.strip() != "0":
            failures.append(
                "cmux launch should preserve an explicit Claude repaint override; "
                f"got rc={override_result.returncode}, stdout={override_result.stdout!r}, "
                f"stderr={override_result.stderr!r}"
            )

        outside_result = _run_wrapper(fake_claude, in_cmux=False, repaint=None)
        if outside_result.returncode != 0 or outside_result.stdout.strip() != "__unset__":
            failures.append(
                "wrapper should not change Claude rendering outside cmux; "
                f"got rc={outside_result.returncode}, stdout={outside_result.stdout!r}, "
                f"stderr={outside_result.stderr!r}"
            )

    if failures:
        print("FAIL: Claude wrapper fullscreen repaint checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: cmux Claude launches default to full repaints and preserve overrides")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
