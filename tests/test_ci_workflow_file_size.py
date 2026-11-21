#!/usr/bin/env python3
"""Every workflow file stays under GitHub's 500 KB workflow file limit, with room to spare.

GitHub refuses a workflow file over 512,000 bytes before any job starts: the run is a startup
failure with no jobs, and a pull request gets no run at all, so the change that crosses the limit
never sees its own red. On 2026-11-10 #40348 took .github/workflows/cmux-next.yml from 511,983 to
512,883 bytes and every cmux-next run on every pull request and push stopped. This guard runs in
the CI guard group, a different workflow, so it still runs when the one that grew is refused, and
it fails a margin before the limit so the next author learns while the workflow still starts.

A failure names the file, its size, the limit and what to do: move long comments to
docs/ci/<workflow>-workflow-notes.md (cmux-next.yml keeps a `# Why: ...#note-N` line), or move a
job or a long script out of the file.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
# https://docs.github.com/actions/reference/limits#workflow-file-size: "500 KB".
LIMIT = 512_000
# The room every file keeps below the limit: about ten pull requests' worth of new steps (the three
# changes before the 2026-11-10 refusal added 286, 900 and 2,300 bytes), so the guard is red for many
# changes before GitHub refuses the file. 8,192 was one large change away from the limit.
MARGIN = 32_000


def oversized(paths: list[Path], limit: int = LIMIT, margin: int = MARGIN) -> list[str]:
    findings = []
    for path in sorted(paths):
        size = path.stat().st_size
        if size > limit - margin:
            rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
            state = ("over the limit: GitHub refuses it before any job starts"
                     if size > limit else f"within {margin:,} bytes of the limit")
            findings.append(
                f"{rel}: {size:,} bytes, {state} ({limit:,} bytes, GitHub's 500 KB workflow file limit). "
                f"Bring it under {limit - margin:,} bytes: move long comments to "
                f"docs/ci/{path.stem}-workflow-notes.md and leave a `# Why: ...#note-N` line, "
                f"or move a long script to scripts/ci/ or a job to its own workflow.")
    return findings


class WorkflowFileSize(unittest.TestCase):
    def test_every_workflow_is_under_the_limit_with_room(self) -> None:
        paths = [*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")]
        self.assertTrue(paths)
        findings = oversized(paths)
        self.assertEqual(findings, [], "\n" + "\n".join(findings))

    def test_a_file_near_or_over_the_limit_is_named_with_its_size(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            near = Path(tmp) / "near.yml"
            near.write_bytes(b"#" * (LIMIT - MARGIN + 1))
            over = Path(tmp) / "over.yml"
            over.write_bytes(b"#" * (LIMIT + 1))
            fine = Path(tmp) / "fine.yml"
            fine.write_bytes(b"#" * 10)
            findings = oversized([near, over, fine])
        self.assertEqual(len(findings), 2, findings)
        self.assertIn("near.yml: 480,001 bytes, within 32,000 bytes of the limit", findings[0])
        self.assertIn("over.yml: 512,001 bytes, over the limit", findings[1])
        self.assertIn("docs/ci/over-workflow-notes.md", findings[1])


if __name__ == "__main__":
    sys.exit(unittest.main())
