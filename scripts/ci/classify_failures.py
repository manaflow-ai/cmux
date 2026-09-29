#!/usr/bin/env python3
"""Tell a CI failure the machine caused from one the pull request's code caused.

ci-failure-attribution.yml runs this on every completed pull request run of
CI (ci.yml), from main, under GITHUB_TOKEN. A PR's code never runs here: the
script reads the run's failed jobs, their logs and annotations, as data.

Each failed job gets a verdict from SIGNATURES, one table of log patterns:

  machine   the runner or its products failed: a runner hook refused the job,
            the compiled products did not restore, the CLI loaded package
            frameworks from another build, the runner went away, the runner
            lacks the Xcode the job pins. The job's
            test failures, if any, are not evidence about the code.
  code      a test recorded an issue, a compile or guard failed, and no
            machine signature matched.
  unknown   nothing in the table matched. The comment names the failed step.

Gate jobs (GATE_JOBS: ci-status and the other jobs that only read `needs`)
fail because another job did, so they are left out, as are cancelled jobs and
jobs whose log says they stopped for another job (verdict `derived`).

A machine signature counts only where the job failed: in a step that printed
an `##[error]`, or in a failure annotation. A cache save that warns about the
disk, or a script that spells a signature it never prints, does not count.

`act` writes the verdicts to the job summary and to one bot comment on the
pull request, edited in place, and re-runs the failed jobs when every failed
job is machine. GitHub's attempt counter bounds that: only a failed attempt 1
is re-run (or a later attempt a person started: that one ran on the minis, and
this re-run goes to Blacksmith), only while it is still the run's latest
attempt, the pull request is open and its head has not moved. owned_pool_rescue.py may re-run a refused
job first; the attempt check then skips, and GitHub refuses a second re-run of
a run in progress. A cancelled run is reported, never re-run: the rescue
cancels a stuck run before its own full re-run, and a re-run of failed jobs
here would pre-empt it.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import sys
from collections.abc import Iterable, Mapping
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from guard_attribution import (  # noqa: E402
    ANSI,
    TIMESTAMP,
    GitHub,
    Writer,
    code,
    fence,
    pr_number,
    upsert_comment,
)
import ui_tests_dispatch  # noqa: E402

MACHINE, CODE, DERIVED, UNKNOWN = "machine", "code", "derived", "unknown"
MARKER = "<!-- cmux-ci-failure-attribution -->"
BOT = "github-actions[bot]"
RED = {"failure", "timed_out"}
# Jobs that only read other jobs' results. Their names as the jobs API reports
# them; tests/test_ci_classify_failures.py derives each from its workflow.
GATE_JOBS = frozenset({
    "ci-status", "tests", "CI timing", "linux-preflight", "macOS admission gate",
    "macos / macOS status", "guards / Guard status", "web / Web status",
})
MAX_EVIDENCE_CHARS = 300
MAX_RENDERED_JOBS = 20


@dataclasses.dataclass(frozen=True)
class Signature:
    name: str
    verdict: str
    pattern: re.Pattern[str]
    why: str


def sig(name: str, verdict: str, pattern: str, why: str) -> Signature:
    return Signature(name, verdict, re.compile(pattern), why)


# First match per verdict is the evidence. A derived match decides the job,
# then a machine match (only in a failed step), then a code match.
SIGNATURES = (
    sig("admission-declined", DERIVED, r"macOS admission gate declined: ",
        "compile admission stopped because a Linux job failed"),
    sig("runner-hook-refused", MACHINE, r"glaeda-cmux-runner-hook: refused: ",
        "the owned runner refused the job (host busy or out of capacity)"),
    sig("product-restore-failed", MACHINE, r'^CMUX_TEST_PRODUCT_RESTORE \{.*"outcome": "failure"',
        "the compiled app-host products did not restore on this runner"),
    sig("app-host-preparation", MACHINE, r"Unexpected app-host preparation outcome",
        "the isolated app-host home was not prepared"),
    # The CLI and the package framework it links came from different builds:
    # the runner staged products from another job. Compiled together, they match.
    sig("mixed-products", MACHINE, r"dyld\[\d+\]: Symbol not found: ",
        "a binary loaded a framework from another build (stale products on the runner)"),
    sig("runner-lost", MACHINE,
        r"lost communication with the server|The runner has received a shutdown signal"
        r"|The hosted runner encountered an error",
        "the runner went away mid-job"),
    sig("disk-full", MACHINE, r"No space left on device", "the runner's disk is full"),
    # scripts/select-ci-xcode.sh on a Mac without the Xcode the job pins. The
    # marker is today's text; the anchored messages are what a pull request
    # branched before it prints (the classifier runs main's copy on any head).
    sig("xcode-pin-missing", MACHINE,
        r"\[cmux-ci machine: xcode-pin-missing\]|^Pinned Xcode developer dir (?:does not exist|has no usable macOS SDK): "
        r"|^This macOS \d+ runner has no Xcode \S+, the version scripts/ci/xcode-pins\.txt pins",
        "the runner does not have the Xcode this job pins (install it: scripts/ci/xcode_pin_audit.py)"),
    sig("swift-testing-issue", CODE, r"^✘ (?:Test|Suite) .+ (?:recorded an issue|failed after)", "a test failed"),
    sig("xctest-failure", CODE, r"\.swift:\d+: error: -\[", "a test failed"),
    sig("ratchet-new-failure", CODE, r"^RATCHET_NEW_FAILURE ", "a test failed that passes on main"),
    sig("compile-error", CODE, r"\S+\.(?:swift|m|mm|c|h|ts|tsx|js|py|rs|zig):\d+:\d+: error: ",
        "a compile error"),
    sig("guard-failed", CODE, r"^\s*FAIL\s+[\d.]+s\s", "a guard step failed"),
    sig("static-check-failed", CODE, r"^FAILED \S+ \(\d", "a static check failed"),
    sig("unittest-failure", CODE, r"^(?:FAIL|ERROR): test\w* \(", "a Python test failed"),
)


def log_steps(text: str) -> list[tuple[bool, list[str]]]:
    """The log's steps as (failed, output lines), without timestamps, colors or echoed scripts.

    A step starts with `##[group]Run <command>`, and GitHub prints its script
    (colored), or an action's `with:` inputs, inside that group, so a signature
    spelled in a script (an `echo "::error::..."` branch never taken) must not
    count. A group a step prints itself may also be titled "Run ..."; its first
    line is output, not script, and it stays. A step failed when it printed an
    `##[error]` line.
    """
    steps: list[tuple[bool, list[str]]] = [(False, [])]
    raw_lines = text.splitlines()
    in_header = False
    for index, raw in enumerate(raw_lines):
        line = ANSI.sub("", TIMESTAMP.sub("", raw.lstrip("\ufeff")))
        if line.startswith("##[group]Run "):
            following = raw_lines[index + 1] if index + 1 < len(raw_lines) else ""
            following_text = TIMESTAMP.sub("", following)
            if "\x1b[36;1m" in following or following_text.startswith("with:"):
                steps.append((False, []))
                in_header = True
                continue
        if in_header:
            if line.startswith("##[endgroup]"):
                in_header = False
            continue
        failed, lines = steps[-1]
        if line.startswith("##[error]"):
            steps[-1] = (True, lines)
        lines.append(line.removeprefix("##[error]"))
    return steps


def classify_text(text: str, annotations: Iterable[str] = ()) -> dict:
    """Verdict, signature and evidence for one job's log and its failure annotations."""
    sections = [*log_steps(text), (True, [a for note in annotations for a in str(note).splitlines()])]
    found: dict[str, tuple[Signature, str]] = {}
    for failed, lines in sections:
        for line in lines:
            for signature in SIGNATURES:
                if signature.verdict == MACHINE and not failed:
                    continue
                if signature.verdict not in found and signature.pattern.search(line):
                    found[signature.verdict] = (signature, line.strip())
    for verdict in (DERIVED, MACHINE, CODE):
        if verdict in found:
            signature, line = found[verdict]
            return {"verdict": verdict, "signature": signature.name, "why": signature.why,
                    "evidence": line[:MAX_EVIDENCE_CHARS]}
    return {"verdict": UNKNOWN, "signature": None, "why": "no known signature in the log", "evidence": ""}


def classify_jobs(jobs: Iterable[Mapping], texts: Mapping[int, tuple[str, list[str]]]) -> list[dict]:
    """Verdicts for the run's failed jobs, gates left out. `texts` holds each job's log and failure annotations."""
    out = []
    for job in jobs:
        if job.get("conclusion") not in RED or job.get("name") in GATE_JOBS:
            continue
        result = classify_text(*texts.get(int(job["id"]), ("", [])))
        if result["verdict"] == DERIVED:
            continue
        step = next((s.get("name") for s in job.get("steps") or [] if s.get("conclusion") in RED), None)
        if result["verdict"] == UNKNOWN:
            result["why"] = ("timed out" if job.get("conclusion") == "timed_out" else "no known signature") + (
                f"; failed step: {code(step, 80)}" if step else "")
        out.append({"id": int(job["id"]), "name": job.get("name"), "runner": job.get("runner_name"),
                    "url": job.get("html_url"), "conclusion": job.get("conclusion"), "step": step, **result})
    return out


def all_machine(jobs: list[dict]) -> bool:
    return bool(jobs) and all(job["verdict"] == MACHINE for job in jobs)


# ---------------------------------------------------------------- GitHub


def run_jobs(gh: GitHub, run_id: int, attempt: int) -> list[dict]:
    """The jobs of this attempt, not of a re-run that started since."""
    jobs: list[dict] = []
    for page in range(1, 5):
        body = gh.get(f"repos/{gh.repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")
        batch = list((body or {}).get("jobs", []))  # type: ignore[union-attr]
        jobs += batch
        if len(batch) < 100:
            break
    return jobs


def job_text(gh: GitHub, job_id: int) -> tuple[str, list[str]]:
    """The job's log and its failure annotations (a lost runner leaves only an annotation)."""
    log, notes = "", []
    try:
        log = str(gh.request("GET", f"repos/{gh.repo}/actions/jobs/{job_id}/logs", text=True))
    except RuntimeError as error:
        print(f"job {job_id}: no log: {error}", file=sys.stderr)
    try:
        for note in gh.get(f"repos/{gh.repo}/check-runs/{job_id}/annotations?per_page=50") or []:  # type: ignore[union-attr]
            if note.get("annotation_level") == "failure":
                notes.append(str(note.get("message") or ""))
    except RuntimeError as error:
        print(f"job {job_id}: no annotations: {error}", file=sys.stderr)
    return log, notes


def classify_run(gh: GitHub, run: Mapping) -> dict:
    attempt = int(run.get("run_attempt") or 1)
    jobs = run_jobs(gh, int(run["id"]), attempt)
    red = [j for j in jobs if j.get("conclusion") in RED and j.get("name") not in GATE_JOBS]
    texts = {int(j["id"]): job_text(gh, int(j["id"])) for j in red}
    return {"run_id": int(run["id"]), "attempt": attempt,
            "run_url": run.get("html_url"), "head_sha": run.get("head_sha"),
            "conclusion": run.get("conclusion"), "jobs": classify_jobs(jobs, texts)}


# ---------------------------------------------------------------- the comment


def render_comment(report: Mapping, rerun: str) -> str:
    sha = (report.get("head_sha") or "")[:10]
    run = f"[run {report['run_id']} attempt {report['attempt']}]({report.get('run_url')})"
    jobs = report["jobs"]
    out = [MARKER, "### CI failure attribution", ""]
    if report.get("conclusion") == "success":
        out.append(f"CI passes on `{sha}` ({run}).")
    else:
        counts = {v: sum(1 for j in jobs if j["verdict"] == v) for v in (MACHINE, CODE, UNKNOWN)}
        summary = ", ".join(f"{n} {v}" for v, n in counts.items() if n)
        verb = "stopped" if report.get("conclusion") == "cancelled" else "failed"
        out += [f"CI {verb} on `{sha}` ({run}): {summary or 'no failed job besides the gates'}.", ""]
        if jobs:
            out += ["| Job | Verdict | Why |", "| --- | --- | --- |"]
            for job in jobs[:MAX_RENDERED_JOBS]:
                name = f"[{job['name']}]({job['url']})" if job.get("url") else str(job["name"])
                where = f" (runner `{job['runner']}`)" if job.get("runner") and job["verdict"] == MACHINE else ""
                out.append(f"| {name.replace('|', '/')} | **{job['verdict']}** | {job['why']}{where} |")
            if len(jobs) > MAX_RENDERED_JOBS:
                out.append(f"| ... {len(jobs) - MAX_RENDERED_JOBS} more | | |")
            evidence = [f"{job['name']}: {job['evidence']}" for job in jobs[:MAX_RENDERED_JOBS] if job["evidence"]]
            if evidence:
                out += ["", "<details><summary>Matched log lines</summary>", "", fence("\n".join(evidence)),
                        "", "</details>"]
        out += ["", rerun]
    out += ["", "Written by `scripts/ci/classify_failures.py` (ci-failure-attribution.yml); signatures are its "
                "`SIGNATURES` table. A machine verdict is the runner's fault, not this PR's."]
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- acting


def rerun_decision(report: Mapping, latest: Mapping) -> tuple[bool, str]:
    """Whether to re-run the failed jobs, and the line that says so."""
    jobs = report["jobs"]
    if not jobs:
        return False, "Not re-run automatically: only gate jobs failed."
    if not all_machine(jobs):
        blockers = [j["name"] for j in jobs if j["verdict"] != MACHINE]
        return False, ("Not re-run automatically: " + ", ".join(f"`{n}`" for n in blockers[:5])
                       + (" is not a machine failure." if len(blockers) == 1 else " are not machine failures."))
    if report.get("conclusion") != "failure":
        return False, "Every failure is a machine failure; a cancelled run is not re-run automatically."
    if int(latest.get("run_attempt") or 0) != report["attempt"] or latest.get("status") != "completed":
        return False, "Every failure is a machine failure; the run has been re-run already."
    # Attempt 1, or a later attempt a person started: a person's re-run goes back to the minis
    # (pr_runner_pool.host_fault_retry()), and this bot's re-run takes Blacksmith, which ends it.
    if report["attempt"] != 1 and str((latest.get("triggering_actor") or {}).get("login") or "") == BOT:
        return False, (f"Every failure is a machine failure, but attempt {report['attempt']} was already an "
                       "automatic re-run. Re-run it by hand if it should go again.")
    return True, "Every failure is a machine failure: re-ran the failed jobs as attempt 2 (the checks show its result)."


def act(gh: GitHub, writer: Writer, run: Mapping, report: Mapping) -> dict:
    """Summary, comment and re-run for the run's pull request, when the run is still its latest word."""
    pr = pr_number(gh, run)
    pull = gh.pull(pr) if pr else {}
    if not pr or pull.get("state") != "open" or (pull.get("head") or {}).get("sha") != report.get("head_sha"):
        # A closed PR, or a run for a head the PR has moved past: nothing to say.
        return {"pr": pr, "rerun": False, "line": "skipped: no open pull request at this head"}
    if report.get("conclusion") == "cancelled" and not report["jobs"]:
        return {"pr": pr, "rerun": False, "line": "skipped: cancelled with no failed job"}
    # Only this workflow's own comment: anyone can post one carrying the marker.
    existing = [c for c in gh.comments(pr) if (c.get("user") or {}).get("login") == BOT]
    current = next((c for c in existing if MARKER in str(c.get("body") or "")), None)
    rerun, line = False, ""
    if report.get("conclusion") != "success":
        rerun, line = rerun_decision(report, gh.run(int(report["run_id"])))
    if rerun:
        try:
            writer.call("POST", f"repos/{gh.repo}/actions/runs/{report['run_id']}/rerun-failed-jobs", {})
        except RuntimeError as error:
            # GitHub refuses to re-run a run another re-run already started.
            rerun, line = False, f"Every failure is a machine failure; the re-run request failed: {code(error)}"
        else:
            # This token's re-run may emit no workflow_run event; start the UI
            # test dispatch the new attempt's ui-tests job waits for.
            path, body = ui_tests_dispatch.rerun_dispatch(report["run_id"], int(report.get("attempt") or 1) + 1)
            try:
                writer.call("POST", f"repos/{gh.repo}/{path}", body)
            except RuntimeError as error:
                print(f"::warning::could not start {ui_tests_dispatch.DISPATCH_WORKFLOW_FILE}: {code(error)}", flush=True)
    body = render_comment(report, line)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(body.replace(MARKER + "\n", ""))
    # A green run says so only where a failure was reported before.
    if report.get("conclusion") != "success" or current is not None:
        upsert_comment(writer, gh.repo, pr, MARKER, body, existing)
    return {"pr": pr, "rerun": rerun, "line": line}


# ---------------------------------------------------------------- commands


def load_run(gh: GitHub | None, run_id: int | None) -> dict:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if run_id is None and event_path and Path(event_path).is_file():
        event = json.loads(Path(event_path).read_text())
        if event.get("workflow_run"):
            return event["workflow_run"]
    if run_id is None or gh is None:
        raise SystemExit("no workflow_run event: pass --run-id with GH_TOKEN set")
    return gh.run(run_id)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    sub = parser.add_subparsers(dest="command", required=True)
    classify = sub.add_parser("classify", help="read-only: print each failed job's verdict as JSON")
    classify.add_argument("--run-id", type=int)
    classify.add_argument("--log", action="append", default=[],
                          help="classify these saved job logs instead of a run (repeatable)")
    run_act = sub.add_parser("act", help="classify, then write the summary and PR comment and re-run machine failures")
    run_act.add_argument("--run-id", type=int, help="default: the workflow_run event")
    run_act.add_argument("--dry-run", action="store_true", help="print the writes instead of making them")
    args = parser.parse_args(argv)

    if args.command == "classify" and args.log:
        for path in args.log:
            print(json.dumps({"log": path, **classify_text(Path(path).read_text(errors="replace"))}))
        return 0
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    gh = GitHub(args.repo, token) if token else None
    run = load_run(gh, args.run_id)
    if gh is None:
        raise SystemExit("set GH_TOKEN")
    if run.get("conclusion") not in ("success", "failure", "cancelled"):
        print(f"run {run.get('id')} concluded {run.get('conclusion')}; nothing to attribute")
        return 0
    report = classify_run(gh, run) if run.get("conclusion") != "success" else {
        "run_id": int(run["id"]), "attempt": int(run.get("run_attempt") or 1), "run_url": run.get("html_url"),
        "head_sha": run.get("head_sha"), "conclusion": "success", "jobs": []}
    if args.command == "classify":
        print(json.dumps(report, indent=2))
        return 0
    writer = Writer(gh, args.dry_run)
    result = act(gh, writer, run, report)
    for entry in writer.log:
        print(entry)
    print(json.dumps({**result, "jobs": [(j["name"], j["verdict"], j["signature"]) for j in report["jobs"]]}))
    print(f"api calls: {gh.calls}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
