#!/usr/bin/env python3
"""Print why a nightly.yml run's head does not compile, or nothing.

    nightly_compile_red.py REPO RUN_ID ATTEMPT [JOBS_JSONL]

JOBS_JSONL, when given, is ATTEMPT's jobs, one JSON object a line, as the caller already read them
(`gh api --paginate .../attempts/N/jobs --jq '.jobs[]'`). Reads the run's attempts from ATTEMPT down (their jobs, and the annotations of a build-nightly-app job that failed)
with `gh api`, and applies owned_pool_rescue.nightly_compile_red(), the owned-pool rescue's own rule, so the tick
and the rescue decide alike. A re-run of a commit whose Release compile failed on a swiftc error (xcodebuild exit
65) compiles the same source and fails the same way, so the caller (scripts/ci/nightly_next_cancelled_tip.sh)
leaves the run alone and the tick builds the next landing instead. Prints nothing for any other failure, and for any
read error: those stay retryable. Always exits 0 once its arguments read.
"""
from __future__ import annotations

import json
import subprocess
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import owned_pool_rescue  # noqa: E402


class GhReader:
    """The two reads nightly_compile_red() makes, through the gh CLI (GH_TOKEN, and gh_budget_wait.sh's wrapper
    when the tick installed it). A failed or malformed read raises OSError or ValueError (READ_ERRORS)."""

    def __init__(self, repo: str, attempt: int = 0, jobs: list | None = None) -> None:
        self.repo = repo
        # ATTEMPT's jobs as the caller read them, so they are not read again.
        self.known = {attempt: jobs} if jobs is not None else {}

    def _get(self, path: str, items: str) -> list:
        result = subprocess.run(["gh", "api", "--paginate", path, "--jq", items],
                                capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            raise OSError(f"gh api {path}: exit {result.returncode}: {result.stderr.strip()[:200]}")
        return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]

    def jobs(self, run_id: int, attempt: int) -> list:
        if attempt in self.known:
            return self.known[attempt]
        return self._get(f"repos/{self.repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100", ".jobs[]")

    def annotations(self, job_id: int) -> list:
        return self._get(f"repos/{self.repo}/check-runs/{job_id}/annotations?per_page=100", ".[]")


def main(argv: list[str]) -> int:
    if len(argv) not in (4, 5) or not argv[2].isdigit() or not argv[3].isdigit():
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    attempt = int(argv[3])
    jobs = None
    if len(argv) == 5:
        try:
            jobs = [json.loads(line) for line in Path(argv[4]).read_text().splitlines() if line.strip()]
        except (OSError, ValueError) as error:
            print(f"could not read {argv[4]} ({error}); reading attempt {attempt}'s jobs again", file=sys.stderr)
    target = types.SimpleNamespace(nightly=True, run_id=int(argv[2]), attempt=attempt)
    why = owned_pool_rescue.nightly_compile_red(GhReader(argv[1], attempt, jobs), target, sleep=lambda seconds: None,
                                                log=lambda text: print(text, file=sys.stderr))
    if why:
        print(why)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
