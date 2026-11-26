#!/usr/bin/env python3
"""Name the pull request behind a red iOS simulator run on feat-cmux-next.

The base's iOS simulator runs are already batched: `iOS simulator tests` (test-ios.yml) and
`cmux-next-ios kit tests` (cmux-next-ios-kit.yml) run on pushes to feat-cmux-next with one run in
flight and only the newest push waiting, so one red run covers every merge since the last green
one. Two pull requests that were each green alone can break the base together (RFD 0029 in
cmuxterm-hq: 3 of 13 iOS breaks that reached the base, cmux#42914, #46709, #43199), and no
per-PR check sees that. This script finds which merge it was.

Given the last green commit and the red one, it lists the first-parent merges between them
(oldest first), confirms the red with the fleet simulator step at the red commit, then bisects:
each probe re-runs the failing fleet step at one candidate,

    cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg MODE ...

and the first red candidate is the culprit. It prints the verdict and posts ONE comment on the
culprit's pull request naming the failing test and the red run (a marker keeps a second run from
commenting again). It never reverts and never blocks anything: a revert or a blocking check is a
new guard and waits for Leo's say-so (RFD 0029, step 3).

A probe that gives no verdict (the step never ran, the fleet was busy) stops the bisect: the
summary names the narrowed range instead of guessing.

The bisect itself (`candidates`, `bisect`) is pure and takes the pass/fail function as an
argument; tests/test_ci_ios_base_bisect.py drives it with a fake runner.

Usage: ios_base_bisect.py --repo OWNER/NAME --good SHA --red SHA [--mode test] [--arg A ...]
       [--run-url URL] [--failing-test NAME] [--summary FILE] [--dry-run]
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable, Sequence
from pathlib import Path

SIM_SCRIPT = "scripts/ci/cmux-next-ios-sim.sh"
MARKER = "<!-- ios-base-bisect:{red} -->"
# A squash merge's subject ends in "(#N)"; a merge commit says "Merge pull request #N".
PR_SUFFIX = re.compile(r"\(#(\d+)\)\s*$")
PR_MERGE = re.compile(r"^Merge pull request #(\d+)\b")
STEP_ID = re.compile(r"cmux-ci: step ([0-9a-f]{6,64})\b")
# XCTest's and Swift Testing's failure lines.
XCTEST_FAILED = re.compile(r"Test Case '-\[(\S+) (\S+)\]' failed")
SWIFT_TESTING_FAILED = re.compile(r"Test (\S+?)(?:\(\))? (?:recorded an issue|failed)")
# Past this many probes the range is too wide for one batched run to bisect on the fleet.
MAX_PROBES = 8

Verdict = bool | None  # True: green, False: red, None: no verdict.


@dataclasses.dataclass(frozen=True)
class Candidate:
    sha: str
    subject: str
    pr: int | None


@dataclasses.dataclass
class Result:
    status: str  # culprit, not-reproduced, unresolved, empty, too-many
    culprit: Candidate | None = None
    probes: list[tuple[str, Verdict]] = dataclasses.field(default_factory=list)
    # The narrowed range: last commit known green, first known red (both may be None).
    good: str | None = None
    bad: str | None = None


def parse_pr(subject: str) -> int | None:
    match = PR_SUFFIX.search(subject) or PR_MERGE.search(subject)
    return int(match.group(1)) if match else None


def candidates(log: str) -> list[Candidate]:
    """`git log --first-parent --format=%H%x09%s GOOD..RED` (newest first) -> oldest first."""
    out = []
    for line in log.splitlines():
        if not line.strip():
            continue
        sha, _, subject = line.partition("\t")
        out.append(Candidate(sha.strip(), subject.strip(), parse_pr(subject)))
    out.reverse()
    return out


def bisect(
    commits: Sequence[Candidate],
    passes: Callable[[str], Verdict],
    *,
    good: str,
    max_probes: int = MAX_PROBES,
) -> Result:
    """The first red commit in `commits` (oldest first; `good` is green, the last is the red head).

    The red head is probed first: a fleet step green there means the red run is not one this step
    reproduces (a flake, or a job the step does not run), and nothing is blamed.
    """
    result = Result(status="empty", good=good)
    if not commits:
        return result
    budget = max_probes

    def probe(index: int) -> Verdict:
        nonlocal budget
        budget -= 1
        verdict = passes(commits[index].sha)
        result.probes.append((commits[index].sha, verdict))
        return verdict

    head = probe(len(commits) - 1)
    if head is None:
        result.status = "unresolved"
        result.bad = None
        return result
    if head:
        result.status = "not-reproduced"
        return result
    lo, hi = -1, len(commits) - 1  # lo: green (or `good`), hi: red.
    result.bad = commits[hi].sha
    while hi - lo > 1:
        if budget <= 0:
            result.status = "too-many"
            return result
        mid = (lo + hi) // 2
        verdict = probe(mid)
        if verdict is None:
            result.status = "unresolved"
            return result
        if verdict:
            lo = mid
            result.good = commits[mid].sha
        else:
            hi = mid
            result.bad = commits[mid].sha
    result.status = "culprit"
    result.culprit = commits[hi]
    return result


def failing_tests(log: str) -> list[str]:
    """The failed test names in a step's log, first seen first."""
    names: list[str] = []
    for match in XCTEST_FAILED.finditer(log):
        name = f"{match.group(1)}/{match.group(2)}"
        if name not in names:
            names.append(name)
    for match in SWIFT_TESTING_FAILED.finditer(log):
        if match.group(1) not in names:
            names.append(match.group(1))
    return names


def comment_body(result: Result, *, red: str, run_url: str, failing: Sequence[str], mode: str) -> str:
    culprit = result.culprit
    assert culprit is not None
    tests = ", ".join(f"`{name}`" for name in failing[:5]) or "(no test name in the step log)"
    lines = [
        MARKER.format(red=red),
        f"The batched iOS simulator run on `feat-cmux-next` went red at `{red[:12]}`, and a bisect "
        f"over the merges since the last green run names this pull request (`{culprit.sha[:12]}`) as "
        "the first red one.",
        "",
        f"- Failing: {tests}",
        f"- Red run: {run_url or '(no run link)'}",
        f"- Fleet step: `cmux-ci run --class simulator --script {SIM_SCRIPT} --ref {culprit.sha} "
        f"--arg {mode}`",
        f"- Last green probe: `{(result.good or '')[:12]}`",
        "",
        "It may be this change together with another one merged just before it, each green alone. "
        "Nothing was reverted or blocked; this is a heads-up for the lane to fix forward "
        "(scripts/ci/ios_base_bisect.py, RFD 0029 step 3).",
    ]
    return "\n".join(lines)


def summary(result: Result, commits: Sequence[Candidate], *, red: str) -> str:
    lines = [f"### iOS base bisect at `{red[:12]}`", "", f"{len(commits)} first-parent merges since the last green run."]
    if result.status == "culprit" and result.culprit:
        pr = f"#{result.culprit.pr}" if result.culprit.pr else "(no PR number)"
        lines.append(f"Culprit: {pr} `{result.culprit.sha[:12]}` {result.culprit.subject}")
    elif result.status == "not-reproduced":
        lines.append("The fleet simulator step is green at the red commit: not reproduced, nothing named.")
    elif result.status == "empty":
        lines.append("No merge between the last green and the red commit: nothing to bisect.")
    else:
        lines.append(
            f"Stopped ({result.status}): first red at `{(result.bad or '?')[:12]}`, last green at "
            f"`{(result.good or '?')[:12]}`."
        )
    lines += ["", "| Probe | Verdict |", "|---|---|"]
    names = {True: "green", False: "red", None: "no verdict"}
    lines += [f"| `{sha[:12]}` | {names[verdict]} |" for sha, verdict in result.probes]
    return "\n".join(lines) + "\n"


# Side effects below: git, the fleet client and the GitHub API.


def git_log(good: str, red: str) -> str:
    return subprocess.run(
        ["git", "log", "--first-parent", "--format=%H%x09%s", f"{good}..{red}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


class FleetRunner:
    """One `cmux-ci run` of the simulator step per probe; keeps each log for the test names."""

    def __init__(self, client: str, mode: str, args: Sequence[str], timeout: int, log_dir: Path):
        self.client, self.mode, self.args, self.timeout, self.log_dir = client, mode, list(args), timeout, log_dir
        self.logs: dict[str, str] = {}

    def __call__(self, sha: str) -> Verdict:
        command = [self.client, "run", "--class", "simulator", "--script", SIM_SCRIPT, "--ref", sha,
                   "--timeout", str(self.timeout), "--arg", self.mode]
        for arg in self.args:
            command += ["--arg", arg]
        print("probe:", " ".join(command), flush=True)
        proc = subprocess.run(command, capture_output=True, text=True)
        log = proc.stdout + proc.stderr
        self.logs[sha] = log
        self.log_dir.mkdir(parents=True, exist_ok=True)
        (self.log_dir / f"probe-{sha[:12]}.log").write_text(log, encoding="utf-8")
        # No step id: the step never ran (client or controller refused it): no verdict.
        if not STEP_ID.search(log):
            return None
        return proc.returncode == 0


def gh(args: Sequence[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(["gh", *args], capture_output=True, text=True, **kwargs)


def already_commented(repo: str, pr: int, marker: str) -> bool:
    proc = gh(["api", f"repos/{repo}/issues/{pr}/comments?per_page=100", "--jq", ".[].body"])
    return proc.returncode == 0 and marker in proc.stdout


def post_comment(repo: str, pr: int, body: str) -> bool:
    proc = gh(["api", "--method", "POST", f"repos/{repo}/issues/{pr}/comments", "-f", f"body={body}"])
    if proc.returncode != 0:
        print(f"::warning title=iOS base bisect::comment on #{pr} failed: {proc.stderr.strip()}")
    return proc.returncode == 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    parser.add_argument("--good", required=True, help="the last commit a base iOS run passed at")
    parser.add_argument("--red", required=True, help="the commit the red base iOS run tested")
    parser.add_argument("--mode", default="test", help="cmux-next-ios-sim.sh MODE (default test)")
    parser.add_argument("--arg", action="append", default=[], help="further step arguments (only=..., ui=...)")
    parser.add_argument("--run-url", default="")
    parser.add_argument("--failing-test", action="append", default=[], help="failed test names, if known")
    parser.add_argument("--client", default=os.environ.get("CMUX_CI_CLIENT", str(Path.home() / ".local/bin/cmux-ci")))
    parser.add_argument("--timeout", type=int, default=3600, help="per-probe step timeout, seconds")
    parser.add_argument("--max-probes", type=int, default=MAX_PROBES)
    parser.add_argument("--log-dir", default=os.environ.get("RUNNER_TEMP", "/tmp") + "/ios-base-bisect")
    parser.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY", ""))
    parser.add_argument("--dry-run", action="store_true", help="print the comment instead of posting it")
    args = parser.parse_args(argv)

    commits = candidates(git_log(args.good, args.red))
    runner = FleetRunner(args.client, args.mode, args.arg, args.timeout, Path(args.log_dir))
    result = bisect(commits, runner, good=args.good, max_probes=args.max_probes)
    text = summary(result, commits, red=args.red)
    print(text)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write(text)
    print(json.dumps({"status": result.status, "culprit": result.culprit and dataclasses.asdict(result.culprit)}))
    if result.status != "culprit" or result.culprit is None or result.culprit.pr is None:
        return 0
    failing = list(args.failing_test) or failing_tests(runner.logs.get(result.culprit.sha, ""))
    body = comment_body(result, red=args.red, run_url=args.run_url, failing=failing, mode=args.mode)
    if args.dry_run:
        print(f"--- comment for #{result.culprit.pr} (dry run) ---\n{body}")
        return 0
    marker = MARKER.format(red=args.red)
    if already_commented(args.repo, result.culprit.pr, marker):
        print(f"#{result.culprit.pr} already has this bisect's comment")
        return 0
    post_comment(args.repo, result.culprit.pr, body)
    # Never red: the bisect reports, it does not gate.
    return 0


if __name__ == "__main__":
    sys.exit(main())
