#!/usr/bin/env python3
"""Name the one merge to revert when a feat-cmux-next push's Mac Release compile fails.

Pull requests get the fleet compile check (-Onone, no Xcode project); -O codegen and the final app link
are first compiled by the base push's Mac Release compile. When that compile fails (the
compiler failed, not the runner), this finds the newest earlier push where it passed and
the pull requests merged since. With exactly one, that merge is the culprit and the
workflow opens its revert pull request (the base-break rule: restore base first). With
none or several it names the range and opens nothing; cmux-next push attribution has
already commented on each.

The run's code never executes here; it reads the Actions and pulls APIs.

Usage: cmux_next_compile_revert.py --repo OWNER/NAME --run-id ID --sha SHA
       [--github-output FILE] [--summary FILE]
Outputs: pr (the culprit's number), merge_sha (its commit on the branch), good (the last pass);
empty pr when there is nothing to revert.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cmux_next_push_attribution import SCANNED_RUNS, gh_api, pull_requests  # noqa: E402

GATE = "cmux-next Release compile (Xcode 26)"
# The step whose failure is the compiler's verdict, per job carrying the gate name: the Mac
# compile, and the admission of the fleet fast check (it fails only on a fleet compile error).
VERDICT_STEPS = ("Release compile", "Record the Release compile admission")
BRANCH = "feat-cmux-next"
WORKFLOW = "cmux-next.yml"


def gate_jobs(repo: str, run_id: int) -> list[dict]:
    jobs = gh_api(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")["jobs"]
    return [job for job in jobs if job.get("name") == GATE]


def compiler_failed(jobs: list[dict]) -> bool:
    """A gate job failed in its verdict step: a compile error, not a runner loss or a timeout."""
    return any(
        job.get("conclusion") == "failure"
        and any(step.get("name") in VERDICT_STEPS and step.get("conclusion") == "failure" for step in job.get("steps") or [])
        for job in jobs
    )


def gate_conclusion(jobs: list[dict]) -> str:
    """success when a gate job passed; otherwise the first other conclusion (skipped says nothing)."""
    conclusions = [job.get("conclusion") or "" for job in jobs]
    if "success" in conclusions:
        return "success"
    return next((c for c in conclusions if c != "skipped"), "")


def culprit(numbers: list[int]) -> int | None:
    return numbers[0] if len(numbers) == 1 else None


def merge_commit(repo: str, number: int) -> str:
    pull = gh_api(f"repos/{repo}/pulls/{number}")
    if pull.get("base", {}).get("ref") != BRANCH or not pull.get("merged_at"):
        return ""
    return pull.get("merge_commit_sha") or ""


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args(argv)

    def report(text: str) -> None:
        print(text)
        if args.summary:
            with args.summary.open("a", encoding="utf-8") as stream:
                stream.write(text + "\n")

    def output(**values: str) -> None:
        if args.github_output:
            with args.github_output.open("a", encoding="utf-8") as stream:
                stream.write("".join(f"{key}={value}\n" for key, value in values.items()))

    output(pr="", merge_sha="", good="")
    if not compiler_failed(gate_jobs(args.repo, args.run_id)):
        report(f"{GATE} did not fail in its compile step at {args.sha[:10]}: nothing to revert.")
        return 0
    runs = gh_api(f"repos/{args.repo}/actions/workflows/{WORKFLOW}/runs"
                  f"?branch={BRANCH}&event=push&status=completed&per_page={SCANNED_RUNS}")["workflow_runs"]
    # Newest first, one jobs read per run until the first pass (a red is rare; a pass is usually close).
    good = next((run["head_sha"] for run in sorted(runs, key=lambda run: run["id"], reverse=True)
                 if run["id"] < args.run_id and run["head_sha"] != args.sha
                 and gate_conclusion(gate_jobs(args.repo, run["id"])) == "success"), None)
    if good is None:
        report(f"{GATE} did not pass in the last {SCANNED_RUNS} push runs: no culprit range, no revert.")
        return 0
    numbers = pull_requests(args.repo, good, args.sha, BRANCH)
    number = culprit(numbers)
    if number is None:
        report(f"{GATE} last passed at {good[:10]}; {len(numbers)} pull requests merged since "
               f"({', '.join(f'#{n}' for n in numbers) or 'none'}): no single culprit, no automatic revert.")
        return 0
    sha = merge_commit(args.repo, number)
    if not sha:
        report(f"#{number} has no merge commit on {BRANCH}: no revert.")
        return 0
    report(f"{GATE} failed at {args.sha[:10]} and last passed at {good[:10]}; the one merge since is #{number} ({sha[:10]}).")
    output(pr=str(number), merge_sha=sha, good=good)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
