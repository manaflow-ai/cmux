#!/usr/bin/env python3
"""Regression coverage for queued nightly-next promotion requests.

Main's promote-nightly-next job is dispatched once per request and serializes
on one concurrency group, so only one job ever writes nightly-next. Requests
for different feat-cmux-next commits arrive out of order (an older commit's
Release compile or tree publication can finish after a newer one's), and
GitHub keeps at most one waiting job per group, cancelling it when another
arrives. A late request for an older commit therefore cancelled the waiting
request for a newer one, and nightly-next stopped at the older commit.

The test evaluates the job's real concurrency group and the workflow's real
run-name for each request, applies GitHub's one-running/one-waiting rule, then
runs the real promotion script for each surviving request in order against a
mocked Actions API whose cancelled dispatch runs carry the evaluated titles.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"

# Linear feat-cmux-next history, oldest first. nightly-next starts at BASE.
BASE, RUNNING, OLDER, NEWER, UNGREEN = ("1" * 40, "2" * 40, "3" * 40, "4" * 40, "5" * 40)
HISTORY = [BASE, RUNNING, OLDER, NEWER, UNGREEN]


HARNESS = r"""
const scenario = JSON.parse(process.env.SCENARIO);
const history = scenario.history;
const position = (sha) => {
  const index = history.indexOf(sha);
  if (index < 0) throw new Error(`unknown commit ${sha}`);
  return index;
};
const state = { target: scenario.target };
const failed = [];
const notices = [];
const writes = [];
const listJobs = (params) => {
  const sha = history[params.run_id - 1000];
  const green = !scenario.notGreen.includes(sha);
  return [{ name: 'cmux-next Release compile (Xcode 26)', status: 'completed', conclusion: green ? 'success' : 'failure' }];
};
const runsFor = (params) => {
  if (params.workflow_id === 'nightly.yml') {
    if (params.event !== 'workflow_dispatch' || params.branch !== 'main') {
      throw new Error(`unexpected nightly.yml lookup ${JSON.stringify(params)}`);
    }
    // Promotion requests on main, newest first.
    return scenario.dispatchRuns
      .filter((run) => !params.status || run.conclusion === params.status)
      .slice().reverse();
  }
  if (params.workflow_id !== 'cmux-next.yml' || params.event !== 'push' || params.branch !== 'feat-cmux-next') {
    throw new Error(`unexpected run lookup ${JSON.stringify(params)}`);
  }
  return [{ id: position(params.head_sha) + 1000, head_sha: params.head_sha, head_branch: 'feat-cmux-next', event: 'push' }];
};
const actions = {
  listWorkflowRuns: async (params) => ({ data: { workflow_runs: runsFor(params), total_count: runsFor(params).length } }),
  listJobsForWorkflowRun: async (params) => ({ data: { jobs: listJobs(params) } }),
};
const github = {
  rest: {
    actions,
    git: {
      getRef: async ({ ref }) => {
        if (ref === 'heads/feat-cmux-next') return { data: { object: { sha: history[history.length - 1] } } };
        if (ref !== 'heads/nightly-next') throw new Error(`unexpected ref ${ref}`);
        return { data: { object: { sha: state.target } } };
      },
    },
    repos: {
      compareCommitsWithBasehead: async ({ basehead }) => {
        const [base, head] = basehead.split('...');
        const a = position(base);
        const b = position(head);
        return { data: { status: a === b ? 'identical' : a < b ? 'ahead' : 'behind' } };
      },
    },
  },
  paginate: async (method, params) => {
    if (method === actions.listWorkflowRuns) return runsFor(params);
    if (method === actions.listJobsForWorkflowRun) return listJobs(params);
    throw new Error(`unexpected pagination for ${JSON.stringify(params)}`);
  },
};
const writer = {
  rest: {
    git: {
      updateRef: async ({ ref, sha }) => {
        if (ref !== 'heads/nightly-next') throw new Error(`unexpected write to ${ref}`);
        writes.push(sha);
        state.target = sha;
      },
      createRef: async () => { throw new Error('nightly-next exists in every scenario'); },
    },
  },
};
const core = {
  setFailed: (message) => failed.push(message),
  notice: (message) => notices.push(message),
};
const context = { repo: { owner: 'manaflow-ai', repo: 'cmux' }, runId: 1 };
const originalSetTimeout = global.setTimeout;
global.setTimeout = (callback) => { callback(); return 0; };
(async () => {
  for (const sha of scenario.requests) {
    const processForScript = {
      env: { REQUESTED_SHA: sha, DEBOUNCE: 'false', MIN_INTERVAL_HOURS: '0', APP_TOKEN: 'fixture' },
    };
    const run = new Function('github', 'context', 'core', 'process', 'getOctokit',
      `return (async () => {\n${scenario.script}\n})();`);
    await run(github, context, core, processForScript, () => writer);
  }
})().then(() => {
  global.setTimeout = originalSetTimeout;
  console.log(JSON.stringify({ target: state.target, writes, failed, notices }));
}).catch((error) => {
  global.setTimeout = originalSetTimeout;
  console.error(error);
  process.exit(1);
});
"""


def workflow() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def promote_job() -> dict:
    return workflow()["jobs"]["promote-nightly-next"]


def promotion_script() -> str:
    steps = promote_job()["steps"]
    return next(step["with"]["script"] for step in steps if step.get("name") == "Move nightly-next")


def substitute(text: str, sha: str) -> str:
    """Evaluate the expressions this test understands for a promotion request."""
    text = re.sub(
        r"\$\{\{\s*inputs\.promote_nightly_next_sha\s*!=\s*''\s*&&\s*format\('([^']*)',\s*inputs\.promote_nightly_next_sha\)\s*\|\|\s*''\s*\}\}",
        lambda match: match.group(1).replace("{0}", sha),
        text,
    )
    text = re.sub(r"\$\{\{\s*inputs\.promote_nightly_next_sha\s*\}\}", sha, text)
    assert "${{" not in text, f"unsupported expression: {text}"
    return text


def concurrency_group(sha: str) -> str:
    concurrency = promote_job()["concurrency"]
    group = concurrency["group"] if isinstance(concurrency, dict) else concurrency
    return substitute(group, sha)


def run_title(sha: str) -> str:
    """The display title GitHub gives the dispatch run requesting `sha`."""
    data = workflow()
    run_name = data.get("run-name")
    return substitute(run_name, sha).strip() if run_name else data["name"]


def queue(running: str, arrivals: list[str]) -> tuple[list[str], list[dict]]:
    """Apply GitHub's one-running/one-waiting rule to requests arriving while `running` runs.

    Returns the requests that run, in order, and every dispatch run with its
    title and conclusion (a replaced waiting request is cancelled).
    """
    group = concurrency_group(running)
    runs = [{"id": 1, "sha": running, "conclusion": "success"}]
    started = [running]
    waiting: dict | None = None
    for index, sha in enumerate(arrivals, start=2):
        run = {"id": index, "sha": sha, "conclusion": "success"}
        runs.append(run)
        if concurrency_group(sha) != group:
            started.append(sha)  # another group: it would run at once, as a second writer
            continue
        if waiting is not None:
            waiting["conclusion"] = "cancelled"
        waiting = run
    if waiting is not None:
        started.append(waiting["sha"])
    dispatch_runs = [
        {
            "id": run["id"],
            "display_title": run_title(run["sha"]),
            "event": "workflow_dispatch",
            "head_branch": "main",
            "status": "completed",
            "conclusion": run["conclusion"],
        }
        for run in runs
    ]
    return started, dispatch_runs


def run_promotions(requests: list[str], dispatch_runs: list[dict], *,
                   target: str = BASE, not_green: list[str] | None = None) -> dict:
    scenario = {
        "script": promotion_script(),
        "history": HISTORY,
        "target": target,
        "requests": requests,
        "dispatchRuns": dispatch_runs,
        "notGreen": not_green or [],
    }
    result = subprocess.run(
        ["node", "-e", HARNESS],
        cwd=ROOT,
        env={**os.environ, "SCENARIO": json.dumps(scenario)},
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def short(sha: str) -> str:
    return {BASE: "BASE", RUNNING: "RUNNING", OLDER: "OLDER", NEWER: "NEWER", UNGREEN: "UNGREEN"}[sha]


def test_one_writer_for_every_request() -> None:
    """Every request shares one group, so nightly-next never has two writers."""
    assert concurrency_group(OLDER) == concurrency_group(NEWER) == concurrency_group(RUNNING)


def test_a_late_older_request_does_not_drop_a_cancelled_newer_one() -> None:
    """NEWER waits behind a running promotion and OLDER replaces it: NEWER must still land."""
    requests, dispatch_runs = queue(RUNNING, [NEWER, OLDER])
    result = run_promotions(requests, dispatch_runs)
    assert result["failed"] == [], result["failed"]
    assert result["target"] == NEWER, (
        f"nightly-next stopped at {short(result['target'])}; the cancelled request for NEWER was "
        f"dropped (requests that ran: {[short(sha) for sha in requests]})"
    )


def test_a_cancelled_request_without_a_green_compile_is_not_promoted() -> None:
    """Recovered requests pass the same Release compile admission as the input."""
    requests, dispatch_runs = queue(RUNNING, [UNGREEN, OLDER])
    result = run_promotions(requests, dispatch_runs, not_green=[UNGREEN])
    assert result["failed"] == [], result["failed"]
    assert result["target"] == OLDER, short(result["target"])
    assert UNGREEN not in result["writes"]


def main() -> None:
    test_one_writer_for_every_request()
    test_a_late_older_request_does_not_drop_a_cancelled_newer_one()
    test_a_cancelled_request_without_a_green_compile_is_not_promoted()
    print("PASS: nightly-next promotion queue")


if __name__ == "__main__":
    main()
