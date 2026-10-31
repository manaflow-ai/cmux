#!/usr/bin/env python3
"""Admission hook for the owned nightly-ops runners (label `cmux-nightly-ops`).

Nightlies never use Blacksmith (Lawrence, 2026-10-30). The nightly jobs that used
to run on Blacksmith Linux (decide, pickers, feed reads and writes, publishers,
notarization polls) are small and frequent; on a glaeda PR runner each would be
billed as a compile (5 units plus the persistent-dd and root tokens) and wait
behind PR work. So a few runners outside glaeda's ledger, on two owned minis
(scripts/ci/nightly-ops-install.sh), take only them.

The runner's job-started hook runs `nightly_ops_runner.py admit`; exit 1 makes
the runner fail the job before its first step. It admits only merged workflow
code of this repository's nightly workflows, on a trusted branch, from a
trusted event, and never a pull request's payload:

  nightly_ops_runner.py admit
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import sys

REPO = "manaflow-ai/cmux"
# The workflows whose jobs may run here. A nightly workflow that is not listed is
# refused (fail closed); tests/test_ci_nightly_off_blacksmith.py keeps every
# workflow that names the label in this list.
WORKFLOWS = frozenset({
    "nightly.yml", "nightly-sign.yml", "nightly-tag-permission-probe.yml",
    "nightly-next-canary.yml", "nightly-next-feed-watch.yml", "nightly-next-launch-smoke.yml",
    "nightly-next-rollback.yml", "nightly-next-tick.yml", "nightly-next-train.yml",
    "nightly-next-verdict.yml", "cmux-tui-nightly.yml", "cmux-tui-build-package.yml",
    "auto-resume-nightly-notarization.yml", "resume-nightly-notarization.yml",
    "repair-nightly-appcast-content-types.yml", "ios-internal-nightly.yml",
    "ios-internal-nightly-trigger.yml",
})
REFS = frozenset({"refs/heads/main", "refs/heads/nightly-next", "refs/heads/feat-cmux-next"})
EVENTS = frozenset({"push", "schedule", "workflow_dispatch", "workflow_run"})
# A payload carrying one of these is (or was started by) untrusted code.
UNTRUSTED_PAYLOAD_KEYS = ("pull_request", "merge_group")
MIN_FREE_BYTES = 15 * 1024 ** 3


def _event(path: str | None) -> dict:
    if not path:
        return {}
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def admit(env: dict, event: dict, free_bytes: int, min_free: int = MIN_FREE_BYTES) -> tuple[bool, str]:
    """Whether this job may run on a nightly-ops runner, and why. Pure."""
    repo = env.get("GITHUB_REPOSITORY", "")
    ref = env.get("GITHUB_REF", "")
    name = env.get("GITHUB_EVENT_NAME", "")
    workflow_ref = env.get("GITHUB_WORKFLOW_REF", "")
    prefix = f"{REPO}/.github/workflows/"
    workflow, _, workflow_branch = workflow_ref.removeprefix(prefix).partition("@")
    run = event.get("workflow_run") if isinstance(event.get("workflow_run"), dict) else {}
    checks = [
        (repo == REPO, f"repository {repo or '<unset>'} is not {REPO}"),
        (workflow_ref.startswith(prefix), f"workflow {workflow_ref or '<unset>'} is not one of {REPO}'s"),
        (workflow in WORKFLOWS, f"workflow {workflow or '<unset>'} is not a nightly workflow"),
        (ref in REFS, f"ref {ref or '<unset>'} is not one of {', '.join(sorted(REFS))}"),
        # Merged code only: the workflow file comes from the branch the job runs on.
        (workflow_branch == ref, f"workflow ref {workflow_branch or '<unset>'} is not the job's ref {ref}"),
        (name in EVENTS, f"event {name or '<unset>'} is not one of {', '.join(sorted(EVENTS))}"),
        (not any(key in event for key in UNTRUSTED_PAYLOAD_KEYS), "the event payload carries a pull request"),
        (not run.get("pull_requests") and run.get("event") not in ("pull_request", "pull_request_target"),
         "the triggering run belongs to a pull request"),
        (free_bytes >= min_free, f"disk has {free_bytes / 1024 ** 3:.1f} GiB free, below {min_free / 1024 ** 3:.0f} GiB"),
    ]
    for ok, reason in checks:
        if not ok:
            return False, reason
    return True, f"admitted: {workflow} job {env.get('GITHUB_JOB', '?')} on {ref}"


def main(argv: list[str]) -> int:
    if argv[1:] != ["admit"]:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        free = shutil.disk_usage(os.environ.get("GITHUB_WORKSPACE") or Path.home()).free
        ok, reason = admit(dict(os.environ), _event(os.environ.get("GITHUB_EVENT_PATH")), free)
    except Exception as error:  # a crash refuses: fail closed
        ok, reason = False, f"admission crashed: {error!r}"
    print(f"nightly-ops: {reason}", flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
