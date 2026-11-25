#!/usr/bin/env python3
"""Run one CI command with a bounded retry for classified infrastructure faults.

The command's output is streamed unchanged. A failed attempt is classified with
the vendored ci-oops rules and one JSON record is appended to the job-local
ledger. Only an ``infra`` verdict earns a second attempt. Code, panic, unknown,
and a second infrastructure failure keep their original non-zero status.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import oops_core  # noqa: E402
import oops  # noqa: E402


def _context(job: str, output: list[str], attempt: int) -> dict:
    """Build the classifier context from the current GitHub job environment."""
    return {
        "repo": os.environ.get("GITHUB_REPOSITORY"),
        "workflow": os.environ.get("GITHUB_WORKFLOW"),
        "job": job,
        "run_id": os.environ.get("GITHUB_RUN_ID"),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
        "head_sha": os.environ.get("GITHUB_SHA"),
        "head_ref": os.environ.get("GITHUB_HEAD_REF") or os.environ.get("GITHUB_REF_NAME"),
        "own_branch": (os.environ.get("GITHUB_HEAD_REF") or os.environ.get("GITHUB_REF_NAME", "")).startswith("lane/"),
        "steps": [{"name": job, "conclusion": "failure"}],
        "log_tail": "\n".join(output[-oops_core.LOG_TAIL_LINES:]),
        "attempt": attempt,
    }


def _ledger_path() -> Path:
    configured = os.environ.get("CI_OOPS_LEDGER")
    if configured:
        return Path(configured)
    return Path(os.environ.get("RUNNER_TEMP") or ".") / "ci_oops.jsonl"


def _append(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")


def _summary(record: dict) -> None:
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary:
        return
    try:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(
                f"- `ci_oops` attempt {record['attempt']} `{record['class']}` "
                f"`{record['rule']}` -> **{record['outcome']}**"
                f" {record.get('evidence') or ''}\n"
            )
    except OSError:
        pass


def run(command: list[str], job: str, ledger: Path, rules: list[dict] | None = None) -> int:
    """Run COMMAND, retrying exactly once when its first failure is infrastructure."""
    rules = oops.load_rules() if rules is None else rules
    for attempt in (1, 2):
        output: list[str] = []
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, bufsize=1)
        assert process.stdout is not None
        try:
            for line in process.stdout:
                print(line, end="")
                output.append(line.rstrip("\n"))
        finally:
            # Popen does not close PIPE handles when the caller consumes the
            # iterator. Close it explicitly so repeated attempts do not leak a
            # descriptor in a long-lived runner process.
            process.stdout.close()
        status = process.wait()
        if status == 0:
            record = {"v": oops_core.CI_OOPS_VERSION, "job": job, "attempt": attempt,
                      "class": "none", "rule": "pass", "evidence": "", "outcome": "passed",
                      "exit_code": 0}
            _append(ledger, record)
            _summary(record)
            return 0

        verdict = oops_core.classify(_context(job, output, attempt), rules)
        retry = verdict.get("class") == "infra" and attempt == 1
        record = {"v": oops_core.CI_OOPS_VERSION, "job": job, "attempt": attempt,
                  "class": verdict.get("class"), "rule": verdict.get("rule"),
                  "evidence": verdict.get("evidence", ""),
                  "outcome": "retried" if retry else "gave_up", "exit_code": status,
                  "repo": os.environ.get("GITHUB_REPOSITORY"),
                  "run_id": os.environ.get("GITHUB_RUN_ID"),
                  "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
                  "head_sha": os.environ.get("GITHUB_SHA")}
        _append(ledger, record)
        _summary(record)
        if not retry:
            return status
        print(f"::warning::ci_oops classified attempt {attempt} as infrastructure; retrying once")
    return status


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--job", default=os.environ.get("GITHUB_JOB", "ci"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    return run(command, args.job, _ledger_path())


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
