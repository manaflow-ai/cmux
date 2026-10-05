#!/usr/bin/env python3
"""nightly-next stops when the cmux-next source archive cannot be built.

The source archive step collects the Ghostty dependency licenses. Until every
Ghostty Zig package had a reviewed text the step ran with continue-on-error,
so a package with no license text gave a red step and an app with no Ghostty
license tree, and the build still shipped. Now the step is blocking: a missing
text fails the helper job, the sign job does not run, and the step tells the
maintainer to pin the text in pinned-licenses/MANIFEST.json. The sign job
downloads the tree without continue-on-error and always injects it.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
NEXT_FULL_BUILD = (
    "needs.decide.outputs.track == 'nightly-next' && needs.decide.outputs.fast_build != 'true'"
)


def step(name: str) -> str:
    """The text of the one step called `name` (dash line through the next step)."""
    text = WORKFLOW.read_text(encoding="utf-8")
    starts = [m.start() for m in re.finditer(r"^      - name: ", text, re.MULTILINE)]
    blocks = []
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(text)
        block = text[start:end]
        # A job header ends the step too.
        job = re.search(r"^  [A-Za-z0-9_-]+:\s*$", block, re.MULTILINE)
        if job:
            block = block[: job.start()]
        if block.splitlines()[0] == f"      - name: {name}":
            blocks.append(block)
    assert len(blocks) == 1, f"expected one step {name!r}, found {len(blocks)}"
    return blocks[0]


def field(block: str, key: str) -> str | None:
    match = re.search(rf"^        {key}: (.*)$", block, re.MULTILINE)
    return match.group(1).strip() if match else None


def test_source_archive_step_blocks() -> None:
    build = step("Build the cmux-next source archive")
    assert field(build, "continue-on-error") is None, "the source archive step must be blocking"
    assert field(build, "if") == NEXT_FULL_BUILD, field(build, "if")
    assert "pinned-licenses/MANIFEST.json" in build, (
        "a failed source archive step must say to pin the license in pinned-licenses/MANIFEST.json"
    )
    assert "::error" in build, "the pin instruction must be a workflow error annotation"


def test_upload_and_inject_do_not_depend_on_a_soft_outcome() -> None:
    upload = step("Upload the cmux-next source archive")
    assert field(upload, "continue-on-error") is None
    assert field(upload, "if") == NEXT_FULL_BUILD, field(upload, "if")
    download = step("Download the Ghostty dependency licenses (cmux-next)")
    assert field(download, "continue-on-error") is None, "a missing license tree must stop the sign job"
    assert field(download, "if") == NEXT_FULL_BUILD, field(download, "if")
    inject = step("Inject the Ghostty dependency licenses (cmux-next)")
    assert field(inject, "continue-on-error") is None
    assert field(inject, "if") == NEXT_FULL_BUILD, field(inject, "if")


def test_no_other_step_reads_the_soft_outcome() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "steps.source_archive.outcome" not in text
    assert "steps.ghostty_licenses.outcome" not in text


def main() -> int:
    test_source_archive_step_blocks()
    test_upload_and_inject_do_not_depend_on_a_soft_outcome()
    test_no_other_step_reads_the_soft_outcome()
    print("nightly-next source archive workflow tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
