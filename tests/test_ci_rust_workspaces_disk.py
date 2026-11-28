"""The rust workspaces matrix builds with line-tables debuginfo and no incremental state.

optchat-chief's 185 test binaries with full debuginfo filled the Linux pool VM's shared disk mid-link
("No space left on device", then rust-lld signal 7 [Bus error]) on 2026-11-27. This fails if the workspace
job's env loses the settings that keep its target dir small.
"""

import pathlib
import re
import unittest

WORKFLOW = pathlib.Path(__file__).resolve().parents[1] / ".github" / "workflows" / "rust-workspaces.yml"


def workspace_job_text() -> str:
    text = WORKFLOW.read_text()
    start = text.index("\n  workspace:\n")
    end = re.search(r"\n  [a-z][a-z0-9_-]*:\n", text[start + 1 :])
    return text[start : start + 1 + end.start()] if end else text[start:]


class RustWorkspacesDisk(unittest.TestCase):
    def test_workspace_job_keeps_debuginfo_small(self) -> None:
        job = workspace_job_text()
        self.assertRegex(job, r"\n\s+CARGO_PROFILE_DEV_DEBUG: line-tables-only\n")
        self.assertRegex(job, r"\n\s+CARGO_PROFILE_TEST_DEBUG: line-tables-only\n")
        self.assertRegex(job, r'\n\s+CARGO_INCREMENTAL: "0"\n')


if __name__ == "__main__":
    unittest.main()
