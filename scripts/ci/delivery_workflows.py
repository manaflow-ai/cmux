"""The delivery workflows: nightly, DEV and promote builds of classic and NEXT.

One declared list. tests/test_nightly_delivery_concurrency.py reads it to
forbid cancel-in-progress and evicting groups in these files, and
scripts/ci/queue_janitor.py reads it to never cancel one of their runs as an
orphan. Standing rule: "Never cancel a nightly, dev or promote build or its
Release compile once it has started, for classic and NEXT alike, unless it is
stuck past its timeout or certain to fail." A job waiting for a runner is not
stuck past its timeout; the answer to that is capacity, not a cancel (run
40428578701, a DEV publish, was cancelled as an orphan on 2026-10-27).

Nightly promotion runs inside nightly.yml (promote-nightly-next), so the
nightly glob covers it. A glob picks up a new workflow on its own; REQUIRED
names make a rename or deletion fail the test instead of quietly dropping out.
"""

from __future__ import annotations

from fnmatch import fnmatch
from pathlib import PurePosixPath

DELIVERY_GLOBS = (
    "nightly*.yml",          # nightly.yml, nightly-sign.yml, nightly-next-*.yml
    "*-nightly*.yml",        # cmux-tui-nightly.yml, ios-internal-nightly*.yml, resume-nightly-notarization.yml
    "cmux-next-dev-*.yml",   # cmux-next-dev-daily.yml (DEV build/sign/publish), its dispatcher and kick
    "*promote*.yml",         # cloud-vm-image-promote.yml (a VM image to the dev channel)
)
REQUIRED_DELIVERY_WORKFLOWS = ("nightly.yml", "cmux-next-dev-daily.yml")

# Delivery runs of a shared workflow, told apart by run name: the DEV source
# build is cmux-next.yml dispatched with dev_daily=true, which
# cmux-next-dev-daily-dispatch.yml names `cmux NEXT DEV daily · <sha>`.
DELIVERY_RUN_NAME_PREFIXES: dict[str, tuple[str, ...]] = {
    "cmux-next.yml": ("cmux NEXT DEV daily · ",),
}


def _file_name(path: str | None) -> str:
    # A reusable call's path can carry `@ref`; the file name is what counts.
    return PurePosixPath(str(path or "").split("@", 1)[0]).name.lower()


def is_delivery_workflow(path: str | None) -> bool:
    """Whether a workflow path (`.github/workflows/x.yml`, or a bare file name) is a delivery workflow."""
    name = _file_name(path)
    return bool(name) and any(fnmatch(name, pattern) for pattern in DELIVERY_GLOBS)


def is_delivery_run(path: str | None, *names: str | None) -> bool:
    """Whether a run is a nightly, DEV or promote build: a delivery workflow, or a named delivery run of a shared one.

    Pass every title the run carries (the API's `name` and `display_title`); any one matching counts,
    as the dispatcher itself checks both.
    """
    if is_delivery_workflow(path):
        return True
    prefixes = DELIVERY_RUN_NAME_PREFIXES.get(_file_name(path), ())
    return any(str(name or "").startswith(prefix) for name in names for prefix in prefixes)
