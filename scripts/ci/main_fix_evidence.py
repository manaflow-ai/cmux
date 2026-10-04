#!/usr/bin/env python3
"""Evidence required before --main-fix may waive an existing Swift test failure.

Run via scripts/gh-merge-green. Missing, skipped, stale and unparseable evidence
refuses the merge. This exception currently has a contract only for cmux-next.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

RELEASE = "cmux-next Release compile (Xcode 26)"
DEBUG = "cmux app scheme compile (Debug)"
SWIFT = "cmux-next swift test"
BUILDS = {RELEASE: "Release compile", DEBUG: "Compile the cmux scheme", SWIFT: "Build package and tests"}
TEST_STEPS = {
    "Regenerate action surface export",
    "Run package tests (excluding control deadline and WebKit driver tests)",
    "Run package tests (excluding control deadline, WebKit driver and attach stress tests)",
    "Run control package tests", "Run WebKit driver package tests", "Run attach driver stress tests",
}
ISSUE = re.compile(r"✘ Test (.+?) recorded an issue at ([^:]+\.swift):\d+:\d+: (.+)")
SUMMARY = re.compile(r"✘ Test run with .* failed .* with (\d+) issues?\.")
MARKERS = re.compile(r"^\+(?:<<<<<<<|>>>>>>>|=======$)", re.MULTILINE)
MAX_OUTPUT = 32 * 1024 * 1024


class Refused(RuntimeError):
    """Evidence is insufficient to merge."""


class GitHub:
    def run(self, args: list[str]) -> str:
        # Disk and memory are bounded per command; neither logs nor receipts are
        # kept. A long API call has a deadline instead of an observation loop.
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(["gh", *args], stdout=output, stderr=errors)
            try:
                process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise Refused("GitHub evidence request exceeded 90 seconds") from None
            if output.tell() > MAX_OUTPUT or errors.tell() > MAX_OUTPUT:
                raise Refused("GitHub evidence exceeds the 32 MiB limit")
            output.seek(0)
            errors.seek(0)
            if process.returncode:
                raise Refused("GitHub evidence request failed: " + errors.read(2000).decode(errors="replace"))
            return output.read().decode(errors="replace")

    def json(self, route: str, *, paginate: bool = False):
        args = ["api", route]
        if paginate:
            args.extend(["--paginate", "--slurp"])
        return json.loads(self.run(args))

    def log(self, repo: str, job: dict) -> str:
        return self.run(["run", "view", str(job["run_id"]), "--repo", repo,
                         "--job", str(job["id"]), "--log"])


def latest_checks(repo: str, sha: str, github: GitHub) -> dict:
    checks = {}
    for page in github.json(f"repos/{repo}/commits/{sha}/check-runs?per_page=100", paginate=True):
        for check in page["check_runs"]:
            # A third-party app cannot provide compile or test evidence.
            if check.get("app", {}).get("slug") != "github-actions":
                continue
            previous = checks.get(check["name"], {})
            if check["id"] > previous.get("id", -1):
                checks[check["name"]] = check
    return checks


def completed_success(item: dict) -> bool:
    return item.get("status") == "completed" and item.get("conclusion") == "success"


def require_merge_gate(repo: str, sha: str, github: GitHub) -> None:
    gate = latest_checks(repo, sha, github).get("merge-gate")
    if gate is None:
        raise Refused(f"merge-gate has not reported for exact head {sha}")
    if not completed_success(gate):
        reason = (gate.get("output") or {}).get("summary", "")
        suffix = f": {reason}" if isinstance(reason, str) and reason else ""
        raise Refused(f"merge-gate is {gate.get('status')}/{gate.get('conclusion')} on exact head {sha}{suffix}")


def job_for(repo: str, check: dict, sha: str, github: GitHub) -> dict:
    url = check.get("details_url", "")
    match = re.fullmatch(r"https://github\.com/" + re.escape(repo) + r"/actions/runs/(\d+)/job/(\d+)", url)
    if not match:
        raise Refused(f"{check['name']}: missing GitHub Actions job evidence")
    job = github.json(f"repos/{repo}/actions/jobs/{match[2]}")
    if job.get("head_sha") != sha or job.get("run_id") != int(match[1]) or job.get("name") != check["name"]:
        raise Refused(f"{check['name']}: job is not for the exact SHA {sha}")
    if job.get("status") != "completed" or check.get("status") != "completed":
        raise Refused(f"{check['name']}: job has not completed on {sha}")
    return job


def require_build(job: dict, name: str) -> None:
    matches = [step for step in job.get("steps", []) if step["name"] == name]
    if len(matches) != 1 or not completed_success(matches[0]):
        raise Refused(f"{name}: build step must succeed on the PR's own head")


def step_log(log: str, name: str) -> str:
    return "\n".join(parts[2] for line in log.splitlines()
                     if len(parts := line.split("\t", 2)) == 3 and parts[1] == name)


def failures(log: str, step: str) -> set[tuple[str, str, str]]:
    text = step_log(log, step)
    records = [line for line in text.splitlines() if "recorded an issue" in line]
    matches = [ISSUE.search(line) for line in records]
    summaries = SUMMARY.findall(text)
    if not records or not summaries or any(match is None for match in matches) or int(summaries[-1]) != len(records):
        raise Refused(f"{step}: cannot parse every failed test issue; no waiver")
    return {tuple(match.groups()) for match in matches}


def validate(repo: str, number: int, github: GitHub) -> str:
    pr = github.json(f"repos/{repo}/pulls/{number}")
    if pr.get("state") != "open":
        raise Refused("PR is not open")
    if pr.get("mergeable") is False:
        raise Refused("PR has merge conflicts")
    head, base = pr["head"]["sha"], pr["base"]["sha"]
    if pr["base"]["ref"] != "feat-cmux-next":
        raise Refused("--main-fix compile evidence is defined for feat-cmux-next only; use normal green merging for other bases")
    checks = latest_checks(repo, head, github)
    jobs = {}
    audit = [f"--main-fix evidence for head `{head}`, base `{base}`:"]
    for name, build in BUILDS.items():
        if name not in checks:
            raise Refused(f"{name}: has not run on exact head {head}")
        job = jobs[name] = job_for(repo, checks[name], head, github)
        require_build(job, build)
        if name != SWIFT and not completed_success(job):
            raise Refused(f"{name}: compile job must succeed on the PR's own head")
        audit.append(f"- {build}: succeeded ([job]({checks[name]['details_url']})).")

    swift = jobs[SWIFT]
    failed_steps = [step for step in swift["steps"] if step.get("conclusion") != "success"
                    and step.get("conclusion") != "skipped"]
    matched = False
    if not completed_success(swift):
        if swift.get("conclusion") != "failure" or not failed_steps:
            raise Refused("Swift test job did not finish with identifiable test failures")
        for step in failed_steps:
            if step["name"] not in TEST_STEPS or step.get("status") != "completed" or step.get("conclusion") != "failure":
                raise Refused(f"{step['name']}: non-test failure cannot be waived")
        base_checks = latest_checks(repo, base, github)
        if SWIFT not in base_checks:
            raise Refused(f"Swift tests have not run on the exact base {base}")
        base_job = job_for(repo, base_checks[SWIFT], base, github)
        require_build(base_job, BUILDS[SWIFT])
        head_log = github.log(repo, swift)
        base_log = github.log(repo, base_job)
        for step in failed_steps:
            name = step["name"]
            base_step = next((step for step in base_job["steps"] if step["name"] == name), {})
            if base_step.get("conclusion") != "failure" or base_step.get("status") != "completed":
                raise Refused(f"{name}: failed tests not reproduced on exact base {base}")
            head_failures, base_failures = failures(head_log, name), failures(base_log, name)
            unmatched = head_failures - base_failures
            if unmatched:
                raise Refused(f"{name}: failures not reproduced on exact base {base}: {sorted(unmatched)!r}")
            for test, source, issue in sorted(head_failures):
                audit.append(f"- Matched base failure: `{source}` / `{test}`: {json.dumps(issue, ensure_ascii=False)} "
                             f"([head]({checks[SWIFT]['details_url']}), [base]({base_checks[SWIFT]['details_url']})).")
        matched = True
    # A completed ci-status failure may aggregate the proven Swift test red;
    # unrelated failures still refuse the exception.
    for name, check in checks.items():
        if check.get("conclusion") in {"failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"}:
            if name == SWIFT and matched:
                continue
            if name == "ci-status" and matched and check.get("conclusion") == "failure":
                continue
            raise Refused(f"{name}: failed check has no same-base test match")
    status = checks.get("ci-status", {})
    if not completed_success(status) and not (matched and status.get("status") == "completed" and status.get("conclusion") == "failure"):
        raise Refused("ci-status must complete on the exact head")
    for page in github.json(f"repos/{repo}/pulls/{number}/files?per_page=100", paginate=True):
        for file in page:
            if MARKERS.search(file.get("patch", "")):
                raise Refused(f"conflict markers in {file['filename']}")
    return "\n".join(audit)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ref", help="OWNER/REPO#NUMBER")
    parser.add_argument("--squash", action="store_true")
    parser.add_argument("--merge", action="store_true")
    parser.add_argument("--rebase", action="store_true")
    parser.add_argument("--check-only", action="store_true", help="print evidence without posting or merging")
    args = parser.parse_args(argv)
    match = re.fullmatch(r"([\w.-]+/[\w.-]+)#(\d+)", args.ref)
    if not match:
        parser.error("expected OWNER/REPO#NUMBER")
    repo, number = match[1], int(match[2])
    github = GitHub()
    try:
        before = github.json(f"repos/{repo}/pulls/{number}")
        audit = validate(repo, number, github)
        after = github.json(f"repos/{repo}/pulls/{number}")
        if before["head"]["sha"] != after["head"]["sha"] or before["base"]["sha"] != after["base"]["sha"] or after["state"] != "open":
            raise Refused("PR head or base moved while collecting evidence; retry")
        print(audit)
        if args.check_only:
            return 0
        with tempfile.TemporaryDirectory(prefix="merge-green-") as directory:
            body = Path(directory) / "audit.md"
            body.write_text(audit + "\n", encoding="utf-8")
            github.run(["pr", "comment", str(number), "--repo", repo, "--body-file", str(body)])
        posted = github.json(f"repos/{repo}/pulls/{number}")
        if posted.get("head", {}).get("sha") != after["head"]["sha"] or posted.get("state") != "open":
            raise Refused("PR head moved while posting the audit comment; retry")
        require_merge_gate(repo, posted["head"]["sha"], github)
        strategy = "--merge" if args.merge else "--rebase" if args.rebase else "--squash"
        github.run(["pr", "merge", str(number), "--repo", repo, "--match-head-commit", posted["head"]["sha"], strategy])
        return 0
    except (Refused, json.JSONDecodeError, KeyError) as error:
        print(f"not green: {error}\nrefusing to merge {args.ref}; wait with: glaeda-gh wait pr {args.ref}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
