#!/usr/bin/env python3
"""The console-session hop probes every sudo form it runs, not only `true`.

One Mac runner's sudoers allowed `sudo -n true` but asked for a password for
`sudo -n test`. The wrapper took the hop, and preparation failed on its first
check with "app-host isolation directory is unavailable", so every app-host
shard placed there failed before running a test. With a partial sudoers the
wrapper now runs in place when it is already the console user in Aqua, fails at
once naming the refused command on an isolated app-host run, and otherwise
falls back with a warning.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts/ci/run-in-console-session.sh"

FAKES = {
    "stat": 'printf "%s\\n" "$FAKE_CONSOLE_USER"',
    "id": (
        'case "$1" in -un) echo cmux;; '
        '-u) if [ "$#" = 2 ]; then echo 501; else echo "$FAKE_CURRENT_UID"; fi;; esac'
    ),
    # Passwordless for `true` only, like the runner's sudoers.
    "sudo": (
        'if [ "$1" = -n ] && [ "$2" = true ] && [ "$#" = 2 ]; then exit 0; fi\n'
        'echo "sudo: a password is required" >&2; exit 1'
    ),
    "launchctl": 'printf "%s\\n" "$FAKE_MANAGER"',
}


def run(bindir: Path, temp: str, uid: str, manager: str, required: str):
    env = dict(
        os.environ,
        PATH=f"{bindir}:{os.environ['PATH']}",
        FAKE_CONSOLE_USER="cmux",
        FAKE_CURRENT_UID=uid,
        FAKE_MANAGER=manager,
        CMUX_APP_HOST_HOME="",
        CMUX_CI_FILE_CAPTURE_ACTIVE="1",
        CMUX_CI_APP_HOST_ISOLATION_REQUIRED=required,
        RUNNER_TEMP=temp,
        RUNNER_NAME="probe-runner",
    )
    return subprocess.run(
        ["/bin/bash", str(WRAPPER), "/bin/bash", "-c", "printf ran; exit 37"],
        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )


def main() -> int:
    failures = []
    with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as temp:
        bindir = Path(directory)
        for name, body in FAKES.items():
            path = bindir / name
            path.write_text("#!/bin/bash\n" + body + "\n")
            path.chmod(0o755)

        # Already the console user in Aqua: no hop is needed, so run in place.
        result = run(bindir, temp, "501", "Aqua", "1")
        if (result.returncode != 37 or result.stdout != "ran"
                or "already running as console user" not in result.stderr):
            failures.append(f"in-Aqua partial sudoers must run in place: {result!r}")

        # Isolated app-host run outside Aqua: fail at once, naming the command.
        result = run(bindir, temp, "502", "Background", "1")
        if (result.returncode in (0, 37) or result.stdout
                or "sudo -n test -e /" not in result.stderr
                or "probe-runner" not in result.stderr
                or "isolation directory is unavailable" in result.stderr):
            failures.append(f"isolated partial sudoers must fail naming the refusal: {result!r}")

        # Not an isolated run: keep the documented fallback.
        result = run(bindir, temp, "502", "Background", "0")
        if (result.returncode != 37 or result.stdout != "ran"
                or "::warning::Cannot enter console user" not in result.stderr
                or "refused: sudo -n test -e /" not in result.stderr):
            failures.append(f"non-isolated partial sudoers must fall back: {result!r}")

        leftovers = [p.name for p in Path(temp).iterdir()]
        if leftovers:
            failures.append(f"probe left files behind: {leftovers}")

    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("PASS: console-session hop probes every sudo form it runs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
