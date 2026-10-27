"""The delivery workflows: nightly, DEV and promote builds of classic and NEXT.

One declared list. tests/test_nightly_delivery_concurrency.py reads it to
forbid cancel-in-progress and evicting groups in these files, and
scripts/ci/queue_janitor.py reads it to never cancel one of their runs as an
orphan. Standing rule: "Never cancel a nightly, dev or promote build or its
Release compile once it has started, for classic and NEXT alike, unless it is
stuck past its timeout or certain to fail." A job waiting for a runner is not
stuck past its timeout; the answer to that is capacity, not a cancel (run
40428578701, a DEV publish, was cancelled as an orphan on 2026-10-27).

Promotion runs inside nightly.yml (promote-nightly-next), so the nightly glob
covers it. A glob picks up a new workflow on its own; REQUIRED names make a
rename or deletion fail the test instead of quietly dropping out.
"""

from __future__ import annotations

from fnmatch import fnmatch
from pathlib import PurePosixPath

DELIVERY_GLOBS = (
    "nightly*.yml",          # nightly.yml, nightly-sign.yml, nightly-next-*.yml
    "*-nightly*.yml",        # cmux-tui-nightly.yml, ios-internal-nightly*.yml, resume-nightly-notarization.yml
    "cmux-next-dev-*.yml",   # cmux-next-dev-daily.yml (DEV build/sign/publish), its dispatcher and kick
)
REQUIRED_DELIVERY_WORKFLOWS = ("nightly.yml", "cmux-next-dev-daily.yml")


def is_delivery_workflow(path: str | None) -> bool:
    """Whether a workflow path (`.github/workflows/x.yml`, or a bare file name) is a delivery workflow."""
    if not path:
        return False
    # A reusable call's path can carry `@ref`; the file name is what counts.
    name = PurePosixPath(str(path).split("@", 1)[0]).name.lower()
    return any(fnmatch(name, pattern) for pattern in DELIVERY_GLOBS)
