#!/usr/bin/env python3
"""A scheduled workflow's GitHub API calls wait through rate limits and 5xx, under a cap.

On 2026-11-20 three main runs went red with no code fault: billing-nightly.yml's storekit job
(run 44713030518) on `gh api` "HTTP 403: API rate limit exceeded for installation", the
resource budget dispatcher (run 44710255073) on an octokit "API rate limit exceeded for
installation", and the cmux NEXT Stable tick (job 136340624244) on `gh workflow run`
"HTTP 500: Failed to run workflow dispatch".

The rule this test keeps: in every workflow with a `schedule` trigger, a job with a step that
runs `gh` or uses actions/github-script first checks out this commit's
scripts/ci/gh_budget_wait.sh (and .cjs) and runs `gh_budget_wait.sh --install`, which puts a
retrying gh first on PATH; each github-script step installs the octokit half
(`if (process.env.GH_BUDGET_WAIT_JS) require(...).install({ github, core })`); and the job's timeout
leaves room for its wait cap (GH_BUDGET_WAIT_MAX_SECONDS, default 3600) so a wait ends in the
wrapper's own loud failure, not a job timeout. A new scheduled workflow with a bare call
fails here. The wrappers themselves are tested in tests/test_gh_budget_wait.py.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# `gh` as a command: line start or after a shell separator, `$(` or `!`. A `gh` inside
# backticks or prose (an error message telling a person what to run) is not a call.
GH_CALL = re.compile(
    r"(?:^|[;&|(!{]|\$\(|\b(?:if|then|else|do|in)\s)\s*"
    r"(?:(?:[A-Za-z_]\w*=(?:\"[^\"]*\"|'[^']*'|[^\s;]+)|env|command)\s+)*"
    r"gh(?:\s|$)"
)
INSTALL = re.compile(r"^bash\s+(?:(\S+)/)?scripts/ci/gh_budget_wait\.sh\s+--install$")
JS_INSTALL = "if (process.env.GH_BUDGET_WAIT_JS) require(process.env.GH_BUDGET_WAIT_JS).install({ github, core })"
DEFAULT_CAP = 3600
# Room in the job's timeout beyond the wait cap, for the calls and steps themselves.
MARGIN_SECONDS = 300
# GitHub's API budget resets hourly. A nightly delivery job (it decides, promotes or moves
# nightly-next) waits through one whole reset rather than lose that night's build: on
# 2026-11-21 promote-nightly-next failed twice under a 900 s cap (job 136673914596: "resets in
# 1693s, past GH_BUDGET_WAIT_MAX_SECONDS=900"; job 136744434336: "resets in 791s, past this
# job's 85s left to wait") and nothing moved nightly-next for hours.
ONE_RESET_SECONDS = 3600
DELIVERY_JOBS = {"nightly.yml": ("decide", "promote-nightly-next", "promote-nightly-next-acked")}


def triggers(doc: dict) -> dict:
    on = doc.get("on", doc.get(True))
    if isinstance(on, dict):
        return on
    if isinstance(on, str):
        return {on: None}
    return {name: None for name in on or []}


def scheduled_workflows() -> list[Path]:
    found = []
    for path in sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")]):
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        if "schedule" in triggers(doc):
            found.append(path)
    return found


def norm(path: object) -> str:
    text = str(path or "")
    while text.startswith("./"):
        text = text[2:]
    text = text.rstrip("/")
    return "" if text == "." else text


def calls_gh(step: dict) -> bool:
    if str(step.get("uses", "")).startswith("actions/github-script@"):
        return True
    run = step.get("run")
    if not isinstance(run, str):
        return False
    lines = [line for line in run.splitlines() if not line.lstrip().startswith("#")]
    return any(GH_CALL.search(line) for line in lines)


def job_problems(name: str, job: dict) -> list[str]:
    steps = job.get("steps") or []
    using = [i for i, step in enumerate(steps) if calls_gh(step)]
    if not using:
        return []
    problems = []
    installs = [(i, INSTALL.match(str(step.get("run", "")).strip())) for i, step in enumerate(steps)]
    installs = [(i, m) for i, m in installs if m]
    if not installs or installs[0][0] > using[0]:
        return [f"{name}: step {using[0]} calls the GitHub API before `bash <path>/scripts/ci/gh_budget_wait.sh --install`"]
    at, match = installs[0]
    prefix = norm(match.group(1))
    tooling = None
    for step in steps[:at]:
        if not str(step.get("uses", "")).startswith("actions/checkout@"):
            continue
        with_ = step.get("with") or {}
        if norm(with_.get("path")) == prefix:
            tooling = with_
    if tooling is None:
        problems.append(f"{name}: no checkout into '{prefix or '.'}' before the wrapper's install")
    else:
        if tooling.get("ref") not in (None, "${{ github.sha }}"):
            problems.append(f"{name}: the wrapper's checkout must be this commit (ref: ${{{{ github.sha }}}})")
        sparse = tooling.get("sparse-checkout")
        if sparse is not None:
            listed = str(sparse).split()
            for need in ("scripts/ci/gh_budget_wait.sh", "scripts/ci/gh_budget_wait.cjs"):
                if need not in listed:
                    problems.append(f"{name}: the wrapper's sparse checkout lacks {need}")
    for i, step in enumerate(steps):
        if str(step.get("uses", "")).startswith("actions/github-script@"):
            script = str((step.get("with") or {}).get("script", ""))
            if JS_INSTALL not in script:
                problems.append(f"{name}: github-script step {i} ({step.get('name')}) lacks `{JS_INSTALL};`")
            for client in re.findall(r"\b(?:const|let|var)\s+(\w+)\s*=\s*getOctokit\(", script):
                if f"install({{ github: {client}, core }})" not in script:
                    problems.append(f"{name}: github-script step {i} leaves its {client} client without retries")
    cap = int((job.get("env") or {}).get("GH_BUDGET_WAIT_MAX_SECONDS", DEFAULT_CAP))
    timeout = job.get("timeout-minutes", 360)
    if isinstance(timeout, int) and timeout * 60 < cap + MARGIN_SECONDS:
        problems.append(f"{name}: timeout-minutes {timeout} leaves no room for a {cap}s wait cap plus {MARGIN_SECONDS}s")
    return problems


def workflow_problems(path: Path) -> list[str]:
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    problems = []
    for name, job in (doc.get("jobs") or {}).items():
        problems += [f"{path.name}:{p}" for p in job_problems(name, job or {})]
    return problems


class ScheduledWorkflowGhRetryTests(unittest.TestCase):
    def test_every_scheduled_github_api_call_waits_through_limits(self) -> None:
        found = scheduled_workflows()
        self.assertGreater(len(found), 20)
        problems = [p for path in found for p in workflow_problems(path)]
        self.assertEqual(problems, [], "\n" + "\n".join(problems))

    def test_the_three_reds_of_2026_11_20_are_covered(self) -> None:
        for workflow, job in (("billing-nightly.yml", "storekit"),
                              ("cmux-next-resource-budget-dispatch.yml", "dispatch"),
                              ("stable-next.yml", "tick")):
            doc = yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8"))
            steps = doc["jobs"][job]["steps"]
            self.assertTrue(any(calls_gh(s) for s in steps), workflow)
            self.assertTrue(any(INSTALL.match(str(s.get("run", "")).strip()) for s in steps), workflow)

    def test_nightly_delivery_jobs_wait_through_one_whole_reset(self) -> None:
        for workflow, names in DELIVERY_JOBS.items():
            jobs = yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8"))["jobs"]
            for name in names:
                cap = int((jobs[name].get("env") or {}).get("GH_BUDGET_WAIT_MAX_SECONDS", DEFAULT_CAP))
                self.assertGreaterEqual(cap, ONE_RESET_SECONDS + MARGIN_SECONDS, f"{workflow}:{name}")

    def test_the_lint_flags_a_bare_call(self) -> None:
        bare = {"timeout-minutes": 5, "steps": [{"run": 'x="$(gh api repos/o/r)"'}]}
        self.assertTrue(job_problems("j", bare))
        for command in ('gh "${query[@]}"', 'GH_TOKEN="$TOKEN" gh api x',
                        'env GH_TOKEN="$TOKEN" gh api x', 'command gh --repo o/r api x'):
            self.assertTrue(job_problems("j", {"steps": [{"run": command}]}), command)
        script = {"timeout-minutes": 5, "steps": [{"uses": "actions/github-script@abc", "with": {"script": "await github.rest.x()"}}]}
        self.assertTrue(job_problems("j", script))
        # Prose that names a command for a person is not a call.
        prose = {"steps": [{"run": 'echo "Roll it back: `gh workflow run x.yml`"\n# gh api in a comment'}]}
        self.assertEqual(job_problems("j", prose), [])

    def test_the_lint_accepts_a_wrapped_job_and_checks_its_timeout(self) -> None:
        def job(timeout: int) -> dict:
            return {
                "timeout-minutes": timeout,
                "env": {"GH_BUDGET_WAIT_MAX_SECONDS": "600"},
                "steps": [
                    {"uses": "actions/checkout@abc", "with": {
                        "ref": "${{ github.sha }}", "path": ".gh-budget-tooling",
                        "sparse-checkout": "scripts/ci/gh_budget_wait.sh\nscripts/ci/gh_budget_wait.cjs\n"}},
                    {"run": "bash .gh-budget-tooling/scripts/ci/gh_budget_wait.sh --install"},
                    {"run": "gh workflow run x.yml"},
                    {"uses": "actions/github-script@abc", "with": {"script": JS_INSTALL + ";\nawait github.rest.x()"}},
                ],
            }
        self.assertEqual(job_problems("j", job(15)), [])
        self.assertTrue(job_problems("j", job(10)))

        writer_job = job(15)
        script_step = writer_job["steps"][-1]["with"]
        script_step["script"] += "\nconst writer = getOctokit(process.env.APP_TOKEN);"
        self.assertTrue(job_problems("j", writer_job))
        script_step["script"] += "\nrequire(process.env.GH_BUDGET_WAIT_JS).install({ github: writer, core });"
        self.assertEqual(job_problems("j", writer_job), [])


if __name__ == "__main__":
    unittest.main()
