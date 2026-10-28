#!/usr/bin/env python3
"""Print the id of a nightly-next attempt's pick-nightly-build-runner job when re-running it is safe.

    nightly_repick.py NIGHTLY_YML JOBS_JSONL [UNSERVED_NAMES]

NIGHTLY_YML is nightly.yml at the run's head; JOBS_JSONL is the attempt's jobs, one JSON object a line
(`gh api --paginate .../attempts/N/jobs --jq '.jobs[]'`), the jobs it kept from earlier attempts
included. Prints the job id, or nothing, and why on stderr. Always exits 0 once its arguments read:
the caller (scripts/ci/nightly_next_rerun.sh) then re-runs the attempt's failed jobs instead.
The rule is owned_pool_rescue.repick_job()'s, so the tick and the owned-pool rescue decide alike.

UNSERVED_NAMES, when given, lists the jobs of the attempt that ended with no runner, one name a line.
The picker is then re-run only when one of them takes its runner from the picker's outputs: a job whose
runs-on does not read the picker (a Linux control job on a runner variable or a literal label) gets
nothing from a fresh pick, and a re-run of the failed jobs evaluates its runs-on again anyway.
"""
from __future__ import annotations

import json
import sys
from collections.abc import Mapping
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import owned_pool_rescue  # noqa: E402
import owned_pool_sources  # noqa: E402

PICKER_OUTPUTS = f"needs.{owned_pool_rescue.NIGHTLY_BUILD_PICKER}.outputs"


def picked_by_picker(workflow: str, names: list[str]) -> tuple[bool, str]:
    """(whether any of the named jobs takes its runs-on from the picker's outputs, why)."""
    try:
        document = owned_pool_sources._load(workflow)
    except Exception as error:  # noqa: BLE001 - an unreadable file keeps the re-run of failed jobs
        return False, f"the workflow file could not be read ({type(error).__name__})"
    spec = {str(key): job for key, job in (document.get("jobs") or {}).items() if isinstance(job, Mapping)}
    for key, job in spec.items():
        pattern = owned_pool_rescue._job_name_pattern(key, job)
        if PICKER_OUTPUTS in str(job.get("runs-on") or "") and any(pattern.fullmatch(name) for name in names):
            return True, f"{key} takes its runner from {owned_pool_rescue.NIGHTLY_BUILD_PICKER}"
    return False, (f"no job left without a runner ({', '.join(names)}) takes its runner from "
                   f"{owned_pool_rescue.NIGHTLY_BUILD_PICKER}")


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    workflow = Path(argv[1]).read_text()
    jobs = [json.loads(line) for line in Path(argv[2]).read_text().splitlines() if line.strip()]
    if len(argv) == 4:
        names = [line.strip() for line in Path(argv[3]).read_text().splitlines() if line.strip()]
        picked, why = picked_by_picker(workflow, names)
        if not picked:
            print(why, file=sys.stderr)
            return 0
    picker, why = owned_pool_rescue.repick_job(workflow, jobs)
    print(why, file=sys.stderr)
    if picker is not None:
        print(picker)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
