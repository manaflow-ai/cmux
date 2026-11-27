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

import os
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github" / "workflows").glob("*.y*ml"))
ENSURE = re.compile(r"ensure-gh-attestation\.sh\b")


def calls_gh_attestation(run: str) -> bool:
    return any(re.search(r"\bgh\s+attestation\b", line.split("#", 1)[0]) for line in run.splitlines())


def exempt(runs_on: str) -> bool:
    # A provenance job reads RUNNER_POOLS.provenance, or names GitHub-hosted Ubuntu itself since
    # scripts/ci/one_linux_label.py froze that read to the label it resolved to.
    return ("provenance" in runs_on or re.fullmatch(r"ubuntu-[a-z0-9.-]+", runs_on.strip()) is not None
            or re.search(r"macos", runs_on, re.I) is not None)


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
            "hosted-label": {"runs-on": "ubuntu-latest", "steps": [verify]},
            "ensured": {"runs-on": "${{ vars.LINUX_RUNNER }}",
                        "steps": [{"run": "source scripts/ci/ensure-gh-attestation.sh\n" + verify["run"]}]},
            "too-late": {"runs-on": "${{ vars.LINUX_RUNNER }}",
                         "steps": [verify, {"run": "source scripts/ci/ensure-gh-attestation.sh"}]},
        }
        self.assertEqual([v.split(":")[0] for v in violations(jobs)], ["fleet", "too-late"])


FAKE_GH = """#!/usr/bin/env bash
# A gh whose `attestation verify` is refused for rate limit the first $REFUSALS times.
if [[ "$1 $2 ${3:-}" == "attestation verify --help" ]]; then exit 0; fi
if [[ "$1 $2" == "api rate_limit" ]]; then echo "$RESET_AT"; exit 0; fi
n=$(cat "$COUNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$COUNT"
if [[ "$1" == "attestation" && "$n" -lt "$REFUSALS" ]]; then
  echo partial; echo "HTTP 403: API rate limit exceeded for installation." >&2; exit 1
fi
if [[ "$1" == "broken" ]]; then echo "HTTP 404: Not Found" >&2; exit 1; fi
echo verified
"""


def run_wrapper(refusals: int, reset_in: int, budget: int, *args: str) -> tuple[subprocess.CompletedProcess, int]:
    with tempfile.TemporaryDirectory() as tmp:
        fake = Path(tmp) / "gh"
        fake.write_text(FAKE_GH)
        fake.chmod(0o755)
        env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "COUNT": f"{tmp}/count",
               "REFUSALS": str(refusals), "RESET_AT": str(int(time.time()) + reset_in),
               "CMUX_GH_RATE_LIMIT_WAIT_S": str(budget), "RUNNER_TEMP": tmp}
        env.pop("GITHUB_PATH", None)
        script = (f"set -euo pipefail; source {ROOT}/scripts/ci/ensure-gh-attestation.sh; "
                  "gh_waiting_out_rate_limit \"$@\"")
        done = subprocess.run(["bash", "-c", script, "_", *args], env=env, capture_output=True, text=True,
                              timeout=60)
        calls = int((Path(tmp) / "count").read_text()) if (Path(tmp) / "count").exists() else 0
        return done, calls


class WaitsOutRateLimit(unittest.TestCase):
    """Runs 45682713296 and 45683201692: the installer job's verify was refused for the shared token budget."""

    def test_a_refused_verify_runs_again_after_the_reset(self) -> None:
        done, calls = run_wrapper(1, 1, 120, "attestation", "verify", "x")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout, "verified\n", "only the successful attempt's stdout")
        self.assertEqual(calls, 2)
        self.assertIn("rate limit", done.stderr)

    def test_a_reset_past_the_budget_fails_without_waiting(self) -> None:
        started = time.monotonic()
        done, calls = run_wrapper(5, 3600, 60, "attestation", "verify", "x")
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(calls, 1)
        self.assertLess(time.monotonic() - started, 30)
        self.assertIn("CMUX_GH_RATE_LIMIT_WAIT_S", done.stderr)

    def test_another_error_is_not_retried(self) -> None:
        done, calls = run_wrapper(0, 0, 120, "broken")
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(calls, 1)


if __name__ == "__main__":
    unittest.main()
