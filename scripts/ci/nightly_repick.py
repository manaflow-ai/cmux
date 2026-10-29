#!/usr/bin/env python3
"""Print the id of a nightly attempt's runner-picker job when re-running it is useful and safe.

    nightly_repick.py NIGHTLY_YML JOBS_JSONL [UNSERVED_NAMES]

NIGHTLY_YML is nightly.yml at the run's head; JOBS_JSONL is the attempt's jobs, one JSON object a line
(`gh api --paginate .../attempts/N/jobs --jq '.jobs[]'`), the jobs it kept from earlier attempts
included. Prints the job id, or nothing, and why on stderr, and exits 0: a decision (nothing means the
caller, scripts/ci/nightly_next_rerun.sh, re-runs the attempt's failed jobs instead). A workflow that
cannot be read or parsed is no decision: it exits non-zero, and the caller sends nothing.
The safety rule is owned_pool_rescue.repick_job()'s, so the tick and the owned-pool rescue decide alike.

The picker is not a fixed job name: it is read from the workflow. UNSERVED_NAMES lists the jobs of the
attempt that ended with no runner, one name a line, and the pickers are the jobs whose outputs those
jobs' runs-on use as the label (`needs.<picker>.outputs.*`, not in a comparison). nightly.yml at the
run's head names it (nightly-next's file calls it pick-nightly-build-runner, main's
pick-nightly-app-runner), so a rename never turns the repick off silently. A job whose runs-on reads no picker (a Linux control job on
a runner variable or a literal label) gets nothing from a fresh pick, and a re-run of the failed jobs
evaluates its runs-on again anyway. Without UNSERVED_NAMES the picker is
owned_pool_rescue.NIGHTLY_BUILD_PICKER, as before.
"""
from __future__ import annotations

import json
import re
import sys
from collections.abc import Mapping
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import owned_pool_rescue  # noqa: E402
import owned_pool_sources  # noqa: E402

# An output a runs-on uses as its label (`needs.pick.outputs.cloud || ...`), not one it only compares
# (`needs.decide.outputs.fast_build != 'true'`): the job that makes it picks the runner.
NEEDS_OUTPUTS = re.compile(r"needs\.([A-Za-z0-9_-]+)\.outputs\.[A-Za-z0-9_-]+(?![A-Za-z0-9_-])(?!\s*[!=]=)")


def workflow_jobs(workflow: str) -> dict[str, Mapping]:
    """The workflow's jobs by key. Raises ValueError when the file is not a workflow with jobs."""
    document = owned_pool_sources._load(workflow)
    jobs = document.get("jobs")
    if not isinstance(jobs, Mapping) or not jobs:
        raise ValueError("not a workflow with jobs")
    return {str(key): job for key, job in jobs.items() if isinstance(job, Mapping)}


def pickers_of(workflow: str, names: list[str]) -> tuple[list[str], str]:
    """(the workflow jobs whose outputs the runs-on of any named job reads, in workflow order; why)."""
    spec = workflow_jobs(workflow)  # raises on an unreadable file: no decision, the caller sends nothing
    found: list[str] = []
    for key, job in spec.items():
        pattern = owned_pool_rescue._job_name_pattern(key, job)
        if not any(pattern.fullmatch(name) for name in names):
            continue
        for picker in NEEDS_OUTPUTS.findall(str(job.get("runs-on") or "")):
            if picker in spec and picker not in found:
                found.append(picker)
    if not found:
        return [], f"no job left without a runner ({', '.join(names)}) takes its runner from a picker job's outputs"
    return found, f"{', '.join(found)} picks the runner of a job left without one"


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    workflow = Path(argv[1]).read_text()
    jobs = [json.loads(line) for line in Path(argv[2]).read_text().splitlines() if line.strip()]
    candidates = [owned_pool_rescue.NIGHTLY_BUILD_PICKER]
    if len(argv) == 4:
        names = [line.strip() for line in Path(argv[3]).read_text().splitlines() if line.strip()]
        candidates, why = pickers_of(workflow, names)
        if not candidates:
            print(why, file=sys.stderr)
            return 0
    reasons = []
    for key in candidates:
        picker, why = owned_pool_rescue.repick_job(workflow, jobs, key)
        if picker is not None:
            print(why, file=sys.stderr)
            print(picker)
            return 0
        reasons.append(why)
    print("; ".join(reasons), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
