#!/usr/bin/env python3
"""Pick the signer Mac a nightly-next loop run's nightly-next-one takes when two may build at once.

Two signer Macs carry glaeda-trusted-next-signing: ultra1 and cmux15 (hq#10366). With one push slot
(nightly-next-one-push) one loop run builds and every newer landing waits for the whole 31 min build, so the feed
lags a burst of landings by one or two builds (2026-11-21: three push runs queued behind run 44907462015). With
vars.NIGHTLY_NEXT_SIGNER_SLOTS=2 each Mac is its own slot: nightly-next-one-push-ultra1 and
nightly-next-one-push-cmux15, each pinned to one runner of that Mac by its glaeda-runner-<name> label (glaeda gives
a signing job the whole Mac, so two on one Mac would wait for each other). Publication stays latest-wins: inside
the publish lease a build that a newer one already published past is superseded and publishes nothing
(publish-recheck-recovered.sh), and the feed's compare-and-swap moves only to a descendant source.

The pick: the first Mac (ultra1, the faster compile, then cmux15) whose slot has no open nightly-next-one of another
loop run (main's nightly-next-tick starts the second build only once the first has run half a build, so the two
finish apart: nightly_next_rolling.py SIGNER_STAGGER_MINUTES). With both taken, the slot whose job waits pending
(a newer run replaces only a pending job, so the newest head builds there next), else the one whose build started first (it frees first). Empty, so the job keeps the one
shared slot and label exactly as before, when the variable is not 2, any read fails, or another run's
nightly-next-one waits unpinned (it may take either Mac).

It runs as `signing_runner.py next-slot`, the owned-Mac picker a signing job's runs-on may read
(tests/test_ci_signing_owned_mac.py): `owned` is one of the two JSON runs-on arrays in OWNED, or empty.

    GH_TOKEN=<actions: read> REPOSITORY=OWNER/NAME RUN_ID=<this run> SLOTS=<vars.NIGHTLY_NEXT_SIGNER_SLOTS> \\
        signing_runner.py next-slot   -> slot=ultra1|cmux15|, owned=<runs-on array>| in $GITHUB_OUTPUT
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Callable, Iterable, Mapping

ONE_JOB = "nightly-next-one"
# Mac -> the runner its slot pins (glaeda-runner-<runner name>). The order is the preference.
MACS = {"ultra1": "glaeda-runner-ultra1-glaeda", "cmux15": "glaeda-runner-cmux15-glaeda"}
SIGNER_LABEL = "glaeda-trusted-next-signing"  # signing_runner.SIGNER_LABEL
# The runs-on array each slot's nightly-next-one takes: the signer label and that Mac's pinned runner.
OWNED = {mac: json.dumps([SIGNER_LABEL, pin], separators=(",", ":")) for mac, pin in MACS.items()}
# Not "queued": a run is queued until its first job starts, so it has no nightly-next-one yet.
ACTIVE = ("in_progress", "waiting", "pending", "requested")
OPEN_JOB = ("queued", "in_progress", "waiting", "pending", "requested")
MAX_PAGES = 3
READ_SECONDS = 20


class Unknown(Exception):
    """A read that did not answer, or a job that may take either Mac: keep the one shared slot."""


def mac_of(job: Mapping) -> str:
    labels = {str(label) for label in job.get("labels") or []}
    for mac, pin in MACS.items():
        if pin in labels:
            return mac
    name = str(job.get("runner_name") or "")
    for mac in MACS:
        if name == f"{mac}-glaeda" or name.startswith(f"{mac}-glaeda-"):
            return mac
    raise Unknown(f"run {job.get('run_id')}'s {ONE_JOB} waits unpinned (labels {sorted(labels)}, runner {name!r})")


def pick(open_jobs: Iterable[Mapping]) -> str:
    """The Mac for this run, from every other loop run's open nightly-next-one."""
    taken: dict[str, list[Mapping]] = {mac: [] for mac in MACS}
    for job in open_jobs:
        taken[mac_of(job)].append(job)
    for mac, jobs in taken.items():
        if not jobs:
            return mac
    for mac, jobs in taken.items():
        if any(job.get("status") != "in_progress" for job in jobs):
            return mac
    return min(taken, key=lambda mac: min(str(job.get("started_at") or "") for job in taken[mac]))


def gh_read(path: str) -> Mapping:
    try:
        out = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=READ_SECONDS, check=True)
        return json.loads(out.stdout)
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        raise Unknown(f"GET {path}: {type(error).__name__}") from error


def pages(read: Callable[[str], Mapping], path: str, key: str) -> list:
    items: list = []
    for number in range(1, MAX_PAGES + 2):
        page = read(f"{path}&per_page=100&page={number}").get(key) or []
        if not page:
            return items
        if number > MAX_PAGES:
            break
        items.extend(page)
    raise Unknown(f"{path} lists more than {MAX_PAGES} pages")


def open_one_jobs(read: Callable[[str], Mapping], repository: str, run_id: str) -> list[Mapping]:
    jobs, seen = [], {str(run_id)}
    for status in ACTIVE:
        for run in pages(read, f"repos/{repository}/actions/workflows/nightly.yml/runs?branch=nightly-next&status={status}",
                         "workflow_runs"):
            if str(run.get("id")) in seen:
                continue
            seen.add(str(run.get("id")))
            for job in pages(read, f"repos/{repository}/actions/runs/{run['id']}/jobs?filter=latest", "jobs"):
                if job.get("name") == ONE_JOB and job.get("status") in OPEN_JOB:
                    jobs.append(job)
    return jobs


def main(env: Mapping[str, str] = os.environ, read: Callable[[str], Mapping] = gh_read) -> int:
    slot, why = "", "vars.NIGHTLY_NEXT_SIGNER_SLOTS is not 2: the one shared slot"
    if (env.get("SLOTS") or "").strip() == "2":
        try:
            slot = pick(open_one_jobs(read, env["REPOSITORY"], env.get("RUN_ID", "")))
            why = f"{slot}'s slot (nightly-next-one-push-{slot}, {MACS[slot]})"
        except Unknown as error:
            slot, why = "", f"{error}; the one shared slot, as before"
    print(f"signer slot: {why}")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"slot={slot}\nowned={OWNED.get(slot, '')}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
