#!/usr/bin/env python3
"""A failed TestFlight archive must leave a log behind.

ios-testflight.yml's archive/export/upload step runs xcodebuild for fifteen to
twenty minutes and writes every line straight to the step log. GitHub truncates
a step log that long, and it truncates the *end* -- which is where the error is.

Run 35776199844 is the shape of the problem: the job started 19:49:27, failed
20:07:03, and the retrievable log stops at 20:06:31 mid-compile with no error in
it. The run produced no artifacts at all, because the only two upload-artifact
steps in the workflow are gated on the upload having succeeded. So a failed
TestFlight build leaves nothing to diagnose it with, and three of the nine runs
after 18:24 on 2026-09-22 failed exactly there.

Teeing the build to a file and uploading it when the step fails costs nothing on
the success path and is the difference between "the archive failed" and knowing
why.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-testflight.yml"

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"ok: {message}")
    else:
        failures.append(message)
        print(f"FAIL: {message}")


def workflow_job(text: str, name: str) -> str:
    marker = f"\n  {name}:\n"
    start = text.index(marker) + 1
    next_job = text.find("\n  ", start + len(marker))
    while next_job != -1:
        line_end = text.find("\n", next_job + 1)
        if line_end == -1:
            break
        candidate = text[next_job + 3 : line_end]
        if candidate.endswith(":") and " " not in candidate:
            return text[start:next_job]
        next_job = text.find("\n  ", line_end)
    return text[start:]


def test_failed_archive_keeps_its_log() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    upload = workflow_job(text, "upload")

    # Both entry points into the build must be captured, not just the common
    # one: the marketing-version override path is the rarer of the two and so
    # the more expensive to debug without a log.
    # Join backslash continuations first: cloud-testflight.sh is invoked across
    # five lines, so the redirect does not sit on the line naming the script.
    joined: list[str] = []
    for line in upload.splitlines():
        if joined and joined[-1].rstrip().endswith("\\"):
            joined[-1] = joined[-1].rstrip()[:-1] + " " + line.strip()
        else:
            joined.append(line)

    for script in ("upload-testflight.sh", "cloud-testflight.sh"):
        invocation = [
            line for line in joined if script in line and "./ios/scripts/" in line
        ]
        check(
            bool(invocation) and all("tee" in line for line in invocation),
            f"{script} output is teed to a file (found {len(invocation)} invocation(s))",
        )

    check(
        "set -euo pipefail" in upload,
        "pipefail is set, so teeing does not swallow the build's exit status",
    )

    # The artifact step has to run when the step it documents failed, which
    # `if: success()` and a bare `steps.upload.outcome == 'success'` gate both
    # prevent.
    # Matched by the step's own name, not by any mention of "archive": the
    # dSYM step's comment says "the archive's dSYMs" and would match that.
    log_steps = [
        block
        for block in upload.split("      - name: ")
        if block.startswith("Upload the archive log") and "upload-artifact" in block
    ]
    check(bool(log_steps), "an artifact step exists for the archive log")
    if log_steps:
        step = log_steps[0]
        check(
            "failure()" in step or "steps.upload.outcome == 'failure'" in step,
            "the archive log uploads on failure",
        )
        check(
            "if-no-files-found: warn" in step,
            "a missing log warns rather than failing the job a second time",
        )


if __name__ == "__main__":
    import sys

    test_failed_archive_keeps_its_log()
    if failures:
        print(f"\n{len(failures)} failure(s)")
        sys.exit(1)
    print("\nall checks passed")
