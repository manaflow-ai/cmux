#!/usr/bin/env python3
"""Print the id of a nightly-next attempt's pick-nightly-build-runner job when re-running it is safe.

    nightly_repick.py NIGHTLY_YML JOBS_JSONL

NIGHTLY_YML is nightly.yml at the run's head; JOBS_JSONL is the attempt's jobs, one JSON object a line
(`gh api --paginate .../attempts/N/jobs --jq '.jobs[]'`), the jobs it kept from earlier attempts
included. Prints the job id, or nothing, and why on stderr. Always exits 0 once its arguments read:
the caller (scripts/ci/nightly_next_cancelled_tip.sh) then re-runs the attempt's failed jobs instead.
The rule is owned_pool_rescue.repick_job()'s, so the tick and the owned-pool rescue decide alike.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import owned_pool_rescue  # noqa: E402


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    workflow = Path(argv[1]).read_text()
    jobs = [json.loads(line) for line in Path(argv[2]).read_text().splitlines() if line.strip()]
    picker, why = owned_pool_rescue.repick_job(workflow, jobs)
    print(why, file=sys.stderr)
    if picker is not None:
        print(picker)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
