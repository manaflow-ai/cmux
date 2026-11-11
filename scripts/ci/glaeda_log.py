"""A failed Actions job's log from this host's glaeda-gh cache, with no API call.

glaeda-gh's daemon keeps the log of every failed job it sees (read once, compressed; `glaeda-gh log job OWNER/REPO
ID`). A classifier or replay that reads the log here first spends no API read on a log the mirror already saw:
replaying 200 base-red verdicts for cmux#41244 read every log again through the broker (about 150 reads, and it
stopped at 51 runs).

cached_job_log answers the text, or None for anything else (no glaeda-gh on this host or in CI, not kept, GitHub
expired it, an older glaeda-gh without `log`, a timeout), and the caller reads GitHub as before. CMUX_GLAEDA_GH
names the program (empty: never ask it; tests that fake gh set that).
"""

from __future__ import annotations

import os
import shutil
import subprocess

DEADLINE = 30  # seconds: a local read of a few MB; past it the caller reads GitHub
MAX_BYTES = 256 * 1024 * 1024  # as main_fix_evidence's MAX_OUTPUT: glaeda-gh keeps logs up to 64 MiB


def program() -> str | None:
    named = os.environ.get("CMUX_GLAEDA_GH")
    if named is not None:
        return named or None
    return shutil.which("glaeda-gh")


def cached_job_log(repo: str, job_id: object) -> str | None:
    """JOB_ID's log text as glaeda-gh kept it (the bytes of GET repos/REPO/actions/jobs/ID/logs), or None."""
    exe = program()
    try:
        job = int(job_id)  # type: ignore[call-overload]
    except (TypeError, ValueError):
        return None
    if exe is None or job <= 0 or "/" not in str(repo):
        return None
    try:
        done = subprocess.run([exe, "log", "job", str(repo), str(job)], stdin=subprocess.DEVNULL,
                              capture_output=True, timeout=DEADLINE, check=False)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    if done.returncode != 0 or len(done.stdout) > MAX_BYTES:
        return None
    return done.stdout.decode(errors="replace")
