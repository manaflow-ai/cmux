#!/usr/bin/env python3
"""Every job that runs `gh attestation` on a Linux runner that may be self-hosted first takes a gh that has it.

The fleet's self-hosted Linux runners (vars.LINUX_RUNNER, RUNNER_POOLS linux_*) carry a gh older than
2.49, which has no `gh attestation`: cmux-tui-artifacts.yml's adopt-commit-manifest failed
`unknown command "attestation" for "gh"` in runs 44750222506, 44760559576 and 44782231694 on
2026-11-20, so no commit manifest was written and verify-cdn-publication went red.
`source scripts/ci/ensure-gh-attestation.sh` (#48350) keeps the PATH gh only when it has the command,
else puts the pinned, sha256-checked release first on PATH for this step and later ones. This checks that
every such job sources it in the gh step or an earlier one.

GitHub-hosted jobs (RUNNER_POOLS.provenance) and macOS jobs have a current gh and are exempt.
"""

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github" / "workflows").glob("*.y*ml"))
ENSURE = re.compile(r"ensure-gh-attestation\.sh\b")


def calls_gh_attestation(run: str) -> bool:
    return any(re.search(r"\bgh\s+attestation\b", line.split("#", 1)[0]) for line in run.splitlines())


def exempt(runs_on: str) -> bool:
    return "provenance" in runs_on or re.search(r"macos", runs_on, re.I) is not None


def violations(jobs: dict) -> list[str]:
    found = []
    for name, job in jobs.items():
        if not isinstance(job, dict) or exempt(str(job.get("runs-on") or "")):
            continue
        ensured = False
        for step in job.get("steps") or []:
            for line in str(step.get("run") or "").splitlines():
                code = line.split("#", 1)[0]
                if ENSURE.search(code):
                    ensured = True
                elif calls_gh_attestation(code) and not ensured:
                    found.append(f"{name}: step {step.get('name') or step.get('id')!r} runs gh attestation "
                                 f"before sourcing scripts/ci/ensure-gh-attestation.sh")
                    break
    return found


class GhAttestationHasGh(unittest.TestCase):
    def test_every_workflow(self) -> None:
        problems = []
        for path in WORKFLOWS:
            workflow = yaml.load(path.read_text(), Loader=yaml.BaseLoader) or {}
            problems += [f"{path.name}: {v}" for v in violations(workflow.get("jobs") or {})]
        self.assertEqual(problems, [], "\n".join(problems))

    def test_detector_catches_a_fleet_job(self) -> None:
        verify = {"name": "verify", "run": "gh attestation verify x --repo r"}
        jobs = {
            "fleet": {"runs-on": "${{ vars.LINUX_RUNNER }}", "steps": [verify]},
            "hosted": {"runs-on": "${{ fromJSON(vars.RUNNER_POOLS).provenance }}", "steps": [verify]},
            "ensured": {"runs-on": "${{ vars.LINUX_RUNNER }}",
                        "steps": [{"run": "source scripts/ci/ensure-gh-attestation.sh\n" + verify["run"]}]},
            "too-late": {"runs-on": "${{ vars.LINUX_RUNNER }}",
                         "steps": [verify, {"run": "source scripts/ci/ensure-gh-attestation.sh"}]},
        }
        self.assertEqual([v.split(":")[0] for v in violations(jobs)], ["fleet", "too-late"])


if __name__ == "__main__":
    unittest.main()
