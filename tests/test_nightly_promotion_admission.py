#!/usr/bin/env python3
"""Regression coverage for the nightly-next promotion admission lookup.

The source cmux-next push requests promotion immediately after its Release
compile job succeeds. GitHub can briefly omit that just-finished run from the
head-SHA workflow list, so the admission check must retry before rejecting an
otherwise valid promotion.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
SHA = "a" * 40


HARNESS = r"""
const scenario = JSON.parse(process.env.SCENARIO);
const calls = { runs: 0, jobs: 0, updates: 0 };
const failed = [];
const notices = [];
const sourceRun = {
  id: 123,
  head_sha: scenario.sha,
  head_branch: 'feat-cmux-next',
  event: 'push',
  conclusion: 'failure',
};
const actions = {
  listWorkflowRuns: Symbol('listWorkflowRuns'),
  listJobsForWorkflowRun: Symbol('listJobsForWorkflowRun'),
};
const github = {
  rest: {
    actions,
    git: {
      getRef: async ({ ref }) => ({ data: { object: { sha: ref === 'heads/feat-cmux-next' ? scenario.sha : 'b'.repeat(40) } } }),
    },
    repos: {
      compareCommitsWithBasehead: async () => ({ data: { status: 'ahead' } }),
    },
  },
  paginate: async (method, params) => {
    if (method === actions.listWorkflowRuns) {
      if (params.workflow_id !== 'cmux-next.yml' || params.event !== 'push' ||
          params.branch !== 'feat-cmux-next' || params.head_sha !== scenario.sha) {
        throw new Error(`workflow lookup was not exact: ${JSON.stringify(params)}`);
      }
      calls.runs += 1;
      if (calls.runs <= scenario.emptyRuns) return [];
      return [sourceRun];
    }
    if (method === actions.listJobsForWorkflowRun) {
      if (params.run_id !== sourceRun.id || params.filter !== 'latest') {
        throw new Error(`job lookup was not exact: ${JSON.stringify(params)}`);
      }
      calls.jobs += 1;
      if (calls.jobs <= scenario.emptyJobs) return [];
      return [{
        name: scenario.jobName,
        status: scenario.jobStatus,
        conclusion: scenario.jobConclusion,
      }];
    }
    throw new Error(`unexpected pagination method for ${JSON.stringify(params)}`);
  },
};
const writer = {
  rest: {
    git: {
      updateRef: async () => { calls.updates += 1; },
      createRef: async () => { calls.updates += 1; },
    },
  },
};
const core = {
  setFailed: (message) => failed.push(message),
  notice: (message) => notices.push(message),
};
const processForScript = {
  env: {
    REQUESTED_SHA: scenario.sha,
    DEBOUNCE: 'false',
    MIN_INTERVAL_HOURS: '0',
    APP_TOKEN: 'fixture',
  },
};
const context = { repo: { owner: 'manaflow-ai', repo: 'cmux' } };
const run = new Function('github', 'context', 'core', 'process', 'getOctokit',
  `return (async () => {\n${scenario.script}\n})();`);
const originalSetTimeout = global.setTimeout;
global.setTimeout = (callback) => { callback(); return 0; };
run(github, context, core, processForScript, () => writer).then(() => {
  global.setTimeout = originalSetTimeout;
  console.log(JSON.stringify({ calls, failed, notices }));
}).catch((error) => {
  global.setTimeout = originalSetTimeout;
  console.error(error);
  process.exit(1);
});
"""


def promotion_script() -> str:
    """Extract the live promotion script from nightly.yml."""
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    steps = workflow["jobs"]["promote-nightly-next"]["steps"]
    return next(step["with"]["script"] for step in steps if step.get("name") == "Move nightly-next")


def run_admission(*, empty_runs: int, job_name: str, job_conclusion: str,
                  job_status: str = "completed", empty_jobs: int = 0) -> dict:
    """Run the promotion script against a deterministic mocked Actions API."""
    scenario = {
        "script": promotion_script(),
        "sha": SHA,
        "emptyRuns": empty_runs,
        "emptyJobs": empty_jobs,
        "jobName": job_name,
        "jobConclusion": job_conclusion,
        "jobStatus": job_status,
    }
    env = {**os.environ, "SCENARIO": json.dumps(scenario)}
    result = subprocess.run(
        ["node", "-e", HARNESS],
        cwd=ROOT,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def test_admission_retries_a_temporarily_missing_source_run() -> None:
    """A delayed workflow index must not reject an otherwise green compile."""
    result = run_admission(
        empty_runs=1,
        job_name="cmux-next Release compile (Xcode 26)",
        job_conclusion="success",
    )
    assert result["failed"] == []
    assert result["calls"]["runs"] >= 2
    assert result["calls"]["updates"] == 1
    assert any("retry" in notice.lower() for notice in result["notices"])


def test_admission_still_rejects_a_missing_successful_release_compile() -> None:
    """A matching SHA without the required Release compile must fail closed."""
    result = run_admission(
        empty_runs=0,
        job_name="cmux-next checks",
        job_conclusion="success",
    )
    assert result["calls"]["updates"] == 0
    assert result["failed"]
    assert "no cmux-next.yml push run" in result["failed"][0]


def test_admission_rejects_a_success_conclusion_from_an_in_progress_job() -> None:
    """A success conclusion on an unfinished job is not admission evidence."""
    result = run_admission(
        empty_runs=0,
        job_name="cmux-next Release compile (Xcode 26)",
        job_conclusion="success",
        job_status="in_progress",
    )
    assert result["calls"]["updates"] == 0
    assert result["failed"]


def test_admission_retries_a_source_run_until_its_release_compile_is_visible() -> None:
    """A run may be indexed before its completed Release job is queryable."""
    result = run_admission(
        empty_runs=0,
        empty_jobs=1,
        job_name="cmux-next Release compile (Xcode 26)",
        job_conclusion="success",
    )
    assert result["failed"] == []
    assert result["calls"]["jobs"] >= 2
    assert result["calls"]["updates"] == 1


def main() -> None:
    """Run the focused regression suite without requiring a test runner."""
    test_admission_retries_a_temporarily_missing_source_run()
    test_admission_still_rejects_a_missing_successful_release_compile()
    test_admission_rejects_a_success_conclusion_from_an_in_progress_job()
    test_admission_retries_a_source_run_until_its_release_compile_is_visible()
    print("PASS: nightly promotion admission")


if __name__ == "__main__":
    main()
