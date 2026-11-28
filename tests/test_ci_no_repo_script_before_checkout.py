#!/usr/bin/env python3
"""No workflow step runs a repository script before the job's first actions/checkout.

On 2026-11-27 cmux-next base tier run 46083543129 went red in "cmux-next generated files (Mac fallback)": its first
step, "Log the Mac fallback", ran `bash scripts/ci/cmux-next-steps/generated-files-linux.sh fallback` before the job
checked the repository out, and a fresh runner workspace has no scripts/ yet (`No such file or directory`, exit 127).
A reused workspace hides this, since the previous job's tree is still there, so it only fails on a clean host.

A step before checkout must be inline shell, or `uses:` an action. This test reads every workflow and refuses a `run:`
before the first checkout that starts with or calls a repository path (scripts/, ./scripts/, tests/, tools/ ...).
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
# A repository path at a command position: line start, after `bash`/`sh`/`python3`/`source`/`.`, or after `&&`/`;`/`|`.
REPO_PATH = re.compile(
    r"(?:^|[;&|]\s*|\b(?:bash|sh|zsh|python3?|source|exec)\s+(?:-\S+\s+)*|^\.\s+)"
    r"(?:\./)?(scripts|tests|tools|cmux-tui|webviews|Packages)/[\w./-]+",
    re.MULTILINE,
)


def is_checkout(step: dict) -> bool:
    return str(step.get("uses", "")).startswith("actions/checkout@")


def offenders() -> list[str]:
    found: list[str] = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text()) or {}
        for job_id, job in (doc.get("jobs") or {}).items():
            steps = (job or {}).get("steps") or []
            if not any(is_checkout(s) for s in steps if isinstance(s, dict)):
                continue
            for step in steps:
                if not isinstance(step, dict):
                    continue
                if is_checkout(step):
                    break
                run = step.get("run")
                if isinstance(run, str) and (m := REPO_PATH.search(run)):
                    name = step.get("name") or run.splitlines()[0]
                    found.append(f"{path.name}: job {job_id}: step {name!r} runs {m.group(0).strip()!r} before checkout")
    return found


class NoRepoScriptBeforeCheckout(unittest.TestCase):
    def test_no_step_runs_a_repository_path_before_checkout(self) -> None:
        self.assertEqual(offenders(), [], "move these steps after actions/checkout, or inline them")

    def test_the_detector_finds_the_2026_11_27_case(self) -> None:
        self.assertTrue(REPO_PATH.search("bash scripts/ci/cmux-next-steps/generated-files-linux.sh fallback"))
        self.assertTrue(REPO_PATH.search("./scripts/select-ci-xcode.sh"))
        self.assertFalse(REPO_PATH.search('echo "CMUX_TEST_REQUIRE_GUI=1" >> "$GITHUB_ENV"'))
        self.assertFalse(REPO_PATH.search('rm -rf "$GITHUB_WORKSPACE/.git"'))


if __name__ == "__main__":
    unittest.main()
