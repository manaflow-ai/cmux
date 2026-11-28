"""A pull request path gate compares with its merge commit's first parent.

`github.event.pull_request.base.sha` is the base branch tip when the event fired; the
merge ref (refs/pull/N/merge) is built on whatever the base was when GitHub last
merged it. When base.sha is older, `git diff base.sha HEAD` lists every commit that
landed in between as this pull request's change, and path-gated jobs run on pull
requests that touch none of their paths (the App Store shelf ran its full build on
4 of 5 sampled pull requests that touched no shelf input). Any step that takes the
event's base.sha and diffs it against HEAD must read the first parent of HEAD first.
"""

from __future__ import annotations

import pathlib
import re
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
EVENT_BASE = "github.event.pull_request.base.sha"
DIFF_AGAINST_HEAD = re.compile(r'git\s+diff\b[^\n]*"\$\{?(\w+)\}?"\s+HEAD\b')
FIRST_PARENT = re.compile(r"/\^parent /|HEAD\^1|HEAD~1|HEAD\^\b")


def offenders() -> list[str]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text())
        for job_id, job in (doc.get("jobs") or {}).items():
            for step in job.get("steps") or []:
                run = step.get("run") or ""
                env = step.get("env") or {}
                for var in DIFF_AGAINST_HEAD.findall(run):
                    if EVENT_BASE in str(env.get(var, "")) and not FIRST_PARENT.search(run):
                        found.append(f"{path.name}:{job_id}:{step.get('name', '?')} ({var})")
    return found


class PullRequestDiffFirstParentTest(unittest.TestCase):
    def test_event_base_sha_diffs_read_the_first_parent(self) -> None:
        self.assertEqual(offenders(), [])

    def test_detector_catches_the_stale_form(self) -> None:
        run = 'git fetch --depth=1 origin "$BASE_SHA"\nchanged="$(git diff --name-only "$BASE_SHA" HEAD)"\n'
        self.assertEqual(DIFF_AGAINST_HEAD.findall(run), ["BASE_SHA"])
        self.assertIsNone(FIRST_PARENT.search(run))


if __name__ == "__main__":
    unittest.main()
