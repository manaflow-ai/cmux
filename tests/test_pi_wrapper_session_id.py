#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-pi-wrapper"


def write_fake_pi(directory: Path, version: str) -> Path:
    executable = directory / "pi"
    executable.write_text(
        f"""#!/bin/sh
if [ "${{1:-}}" = "--version" ]; then
  printf '%s\\n' '{version}'
  exit 0
fi
printf '%s\\n' "$@"
""",
        encoding="utf-8",
    )
    executable.chmod(0o755)
    return executable


def run_wrapper(
    fake_bin: Path,
    arguments: list[str],
    *,
    surface_id: str | None,
) -> subprocess.CompletedProcess[str]:
    environment = {
        "HOME": os.environ.get("HOME", str(ROOT)),
        "PATH": f"{fake_bin}:/usr/bin:/bin",
    }
    if surface_id is not None:
        environment["CMUX_SURFACE_ID"] = surface_id
    return subprocess.run(
        [str(WRAPPER), *arguments],
        env=environment,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )


def output_lines(result: subprocess.CompletedProcess[str]) -> list[str]:
    assert result.returncode == 0, result.stderr
    return result.stdout.splitlines()


def test_assigns_stable_surface_session_id() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-pi-wrapper-") as temporary:
        fake_bin = Path(temporary)
        write_fake_pi(fake_bin, "0.84.0")

        first = run_wrapper(fake_bin, ["hello"], surface_id="ABCD-1234")
        second = run_wrapper(fake_bin, ["again"], surface_id="ABCD-1234")

        assert output_lines(first) == ["--session-id", "cmux-ABCD-1234", "hello"]
        assert output_lines(second) == ["--session-id", "cmux-ABCD-1234", "again"]


def test_preserves_explicit_session_choices() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-pi-wrapper-") as temporary:
        fake_bin = Path(temporary)
        write_fake_pi(fake_bin, "0.84.0")

        resumed = run_wrapper(
            fake_bin,
            ["--session", "known-session"],
            surface_id="ABCD-1234",
        )
        custom = run_wrapper(
            fake_bin,
            ["--session-id=custom-session", "hello"],
            surface_id="ABCD-1234",
        )

        assert output_lines(resumed) == ["--session", "known-session"]
        assert output_lines(custom) == ["--session-id=custom-session", "hello"]


def test_degrades_for_older_pi_and_non_cmux_shells() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-pi-wrapper-") as temporary:
        fake_bin = Path(temporary)
        write_fake_pi(fake_bin, "0.83.2")
        old_pi = run_wrapper(fake_bin, ["hello"], surface_id="ABCD-1234")

        write_fake_pi(fake_bin, "0.84.0")
        outside_cmux = run_wrapper(fake_bin, ["hello"], surface_id=None)

        assert output_lines(old_pi) == ["hello"]
        assert output_lines(outside_cmux) == ["hello"]
