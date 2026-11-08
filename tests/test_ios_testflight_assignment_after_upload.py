#!/usr/bin/env python3
"""Tester assignment must follow the IPA, not the rest of the upload job.

ios-testflight.yml archives, exports and uploads in a single step, then keeps
going: it writes a summary, persists build metadata, uploads the dSYM bundle as
a run artifact and pushes the dSYMs to Sentry. Every one of those runs after
Apple has accepted the build, and any of them can fail on something that has
nothing to do with the build -- an expired SENTRY_AUTH_TOKEN, a Sentry outage,
a GitHub artifact upload hiccup.

When one does, the `upload` job goes red. If assign-internal-group gates on
`needs.upload.result == 'success'` it is skipped, and the build sits in App
Store Connect assigned to nobody while the run reports failure. The testers do
not get it, and the red run points at the upload rather than at the step that
actually failed.

The job already draws this line internally: the two dSYM steps gate on
`steps.upload.outcome == 'success'`, with a comment saying symbols must be
persisted once the IPA reached TestFlight even if a later step failed.
Assignment is the same kind of obligation and needs the same predicate, which
means the upload step's outcome has to cross the job boundary as an output.

Parsed as text rather than with PyYAML, like the other release-ios guards: that
matrix group installs no Python packages.
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


def steps_after_upload(upload_job: str) -> list[str]:
    """Names of the steps that run once `id: upload` has delivered the IPA."""
    body = upload_job.split("\n        id: upload\n", 1)[1]
    return [
        line.split("- name:", 1)[1].strip()
        for line in body.splitlines()
        if line.startswith("      - name:")
    ]


def test_assignment_survives_a_post_upload_failure() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    upload = workflow_job(text, "upload")
    assign = workflow_job(text, "assign-internal-group")

    # The hazard this guard exists for: work that can fail the job after the
    # IPA has already been accepted. If every post-upload step ever leaves this
    # job the guard should be revisited rather than silently kept.
    after = steps_after_upload(upload)
    check(
        len(after) > 1,
        f"steps still run after the upload step ({len(after)}: {', '.join(after)})",
    )

    # Carry the upload step's own outcome -- what the dSYM steps below it
    # already use -- out of the job, so the next job can gate on the same fact.
    check(
        "      uploaded: ${{ github.event.inputs.prepare_only != 'true' && steps.upload.outcome || 'skipped' }}\n" in upload,
        "real uploads export the step outcome; prepared candidates cannot trigger assignment",
    )

    condition = "\n".join(
        line for line in assign.splitlines() if line.startswith("    if:")
    )
    check(
        "needs.upload.result" not in assign,
        "assign-internal-group does not gate on the upload job's result",
    )
    check(
        "needs.upload.outputs.uploaded == 'success'" in condition,
        "assign-internal-group gates on the upload step's outcome",
    )
    # Without this, a failed `needs` skips the job before the condition is
    # read, so the outputs gate above would never get the chance to be true.
    check(
        "!cancelled()" in condition,
        "assign-internal-group overrides the default skip-on-needs-failure",
    )
    check(
        "always()" not in condition,
        "a cancelled run still cancels assignment",
    )
    check(
        "github.ref == 'refs/heads/main'" in condition,
        "assignment still only happens for main",
    )

    # Assignment reads these out of the same job. They come from steps that ran
    # before the upload step, so a later failure leaves them populated.
    for name in ("final_build_number", "bundle_id", "assign_internal_group"):
        check(
            f"      {name}: " in upload,
            f"the upload job still exports `{name}` for assignment",
        )


if __name__ == "__main__":
    import sys

    test_assignment_survives_a_post_upload_failure()
    if failures:
        print(f"\n{len(failures)} failure(s)")
        sys.exit(1)
    print("\nall checks passed")
