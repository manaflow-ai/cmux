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
runs the job's real "Decide the promotion" and "Move nightly-next" step
scripts (which load scripts/ci/promote-nightly-next.mjs from this checkout)
for each surviving request in order, against a mocked API whose cancelled
dispatch runs carry the evaluated titles and GitHub's cancel annotations.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"

# Linear feat-cmux-next history, oldest first. nightly-next starts at BASE.
BASE, RUNNING, OLDER, NEWER, UNGREEN = ("1" * 40, "2" * 40, "3" * 40, "4" * 40, "5" * 40)
HISTORY = [BASE, RUNNING, OLDER, NEWER, UNGREEN]


HARNESS = r"""
import { createRequire } from 'node:module';
const require = createRequire(`${process.env.GITHUB_WORKSPACE}/`);
const scenario = JSON.parse(process.env.SCENARIO);
const history = scenario.history;
const position = (sha) => {
  const index = history.indexOf(sha);
  if (index < 0) throw new Error(`unknown commit ${sha}`);
  return index;
};
const state = { target: scenario.target };
let active = { arrived: 0 };
const failed = [];
const notices = [];
const writes = [];
const warnings = [];
const EVICTED = 'Canceling since a higher priority waiting request for nightly-next-promote exists';
const dispatchRun = (id) => scenario.dispatchRuns.find((run) => run.id === id);
const listJobs = (params) => {
  if (params.run_id < 1000) {
    // A promotion request's own jobs; the promote job's id is its check run id.
    const run = dispatchRun(params.run_id);
    return [{ id: 5000 + run.id, name: 'promote-nightly-next', status: 'completed', conclusion: run.conclusion }];
  }
  const sha = history[params.run_id - 1000];
  const green = !scenario.notGreen.includes(sha);
  return [{ name: 'cmux-next Release compile (Xcode 26)', status: 'completed', conclusion: green ? 'success' : 'failure' }];
};
const runsFor = (params) => {
  if (params.workflow_id === 'nightly.yml') {
    if (scenario.listThrows) throw Object.assign(new Error('Service Unavailable'), { status: 503 });
    if (params.event !== 'workflow_dispatch' || params.branch !== 'main') {
      throw new Error(`unexpected nightly.yml lookup ${JSON.stringify(params)}`);
    }
    // Only a "cancelled" lookup finds runs here: the requests cancelled before
    // the current request started (the cancelling request had arrived), newest first.
    return scenario.dispatchRuns
      .filter((run) => run.conclusion === params.status && run.cancelledAt <= active.arrived)
      .slice().reverse();
  }
  if (params.workflow_id !== 'cmux-next.yml' || params.event !== 'push' || params.branch !== 'feat-cmux-next') {
    throw new Error(`unexpected run lookup ${JSON.stringify(params)}`);
  }
  return [{
    id: position(params.head_sha) + 1000, head_sha: params.head_sha, head_branch: 'feat-cmux-next', event: 'push',
    path: '.github/workflows/cmux-next.yml', head_repository: { full_name: 'manaflow-ai/cmux' },
  }];
};
const actions = {
  listWorkflowRuns: async (params) => ({ data: { workflow_runs: runsFor(params), total_count: runsFor(params).length } }),
  listJobsForWorkflowRun: async (params) => ({ data: { jobs: listJobs(params) } }),
};
const github = {
  rest: {
    actions,
    checks: {
      listAnnotations: async ({ check_run_id }) => {
        if (scenario.annotationsThrow) throw Object.assign(new Error('Forbidden'), { status: 403 });
        if ((scenario.annotationsThrowFor || []).includes(check_run_id - 5000)) {
          throw Object.assign(new Error('Not Found'), { status: 404 });
        }
        const run = dispatchRun(check_run_id - 5000);
        const message = run.cancelledBy === 'queue' ? EVICTED : 'The run was canceled by @teamleaderleo.';
        return { data: [{ annotation_level: 'failure', message }] };
      },
    },
    git: {
      getRef: async ({ ref }) => {
        if (ref === 'heads/feat-cmux-next') return { data: { object: { sha: history[history.length - 1] } } };
        if (ref !== 'heads/nightly-next') throw new Error(`unexpected ref ${ref}`);
        return { data: { object: { sha: state.target } } };
      },
      // No commit changes a release surface file, so every admitted range promotes.
      getCommit: async ({ commit_sha }) => ({ data: { sha: commit_sha, tree: { sha: `tree-${commit_sha}` } } }),
      getTree: async () => ({ data: { truncated: false, tree: [] } }),
    },
    repos: {
      compareCommitsWithBasehead: async ({ basehead }) => {
        const [base, head] = basehead.split('...');
        const a = position(base);
        const b = position(head);
        const commits = a < b ? history.slice(a + 1, b + 1).map((sha) => ({ sha, parents: [] })) : [];
        return { data: { status: a === b ? 'identical' : a < b ? 'ahead' : 'behind', total_commits: commits.length, commits } };
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
      updateRef: async ({ ref, sha, force }) => {
        if (ref !== 'heads/nightly-next' || force) throw new Error(`unexpected write to ${ref} (force ${force})`);
        writes.push(sha);
        state.target = sha;
      },
      createRef: async () => { throw new Error('nightly-next exists in every scenario'); },
    },
  },
};
const runStep = async (script, env, runId, outputs) => {
  const summary = { addRaw: () => summary, write: async () => {} };
  const core = {
    summary,
    setOutput: (name, value) => { outputs[name] = String(value); },
    setFailed: (message) => failed.push(message),
    notice: (message) => notices.push(message),
    warning: (message) => warnings.push(message),
  };
  const context = { repo: { owner: 'manaflow-ai', repo: 'cmux' }, runId, payload: {} };
  const processForScript = { env: { ...env, GITHUB_WORKSPACE: process.env.GITHUB_WORKSPACE } };
  const run = new Function('github', 'context', 'core', 'process', 'getOctokit', 'require',
    `return (async () => {\n${script}\n})();`);
  await run(github, context, core, processForScript, () => writer, require);
};
// G5's tree-commit marker (fetchTreeMarker's default fetch): every commit is ready.
globalThis.fetch = async (url) => {
  const sha = String(url).match(/tree-commits\/([0-9a-f]{40})\.json/)[1];
  return { status: 200, json: async () => ({ commit: sha, key: 'f'.repeat(40), publishedBy: 'e'.repeat(40), markedBy: 'https://github.com/manaflow-ai/cmux/actions/runs/1' }) };
};
// The admission retry sleeps between lookups; run it without waiting.
global.setTimeout = (callback) => { callback(); return 0; };
for (const request of scenario.requests) {
  active = request;
  const decided = {};
  await runStep(scenario.decide, {
    REQUESTED_SHA: request.sha, DEBOUNCE: 'false', MIN_INTERVAL_HOURS: '0',
  }, request.runId, decided);
  const moveIf = new Function('o', `return ${scenario.moveIf};`);
  if (moveIf(decided)) {
    await runStep(scenario.move, { APP_TOKEN: 'fixture', DECISION: decided.decision }, request.runId, {});
  }
}
console.log(JSON.stringify({ target: state.target, writes, failed, notices, warnings }));
"""


def workflow() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def promote_job() -> dict:
    return workflow()["jobs"]["promote-nightly-next"]


def step(name: str) -> dict:
    return next(entry for entry in promote_job()["steps"] if entry.get("name") == name)


def move_condition() -> str:
    """The Move step's `if:` as a JavaScript expression over the decide step's outputs."""
    condition = step("Move nightly-next")["if"]
    expression = re.sub(r"steps\.decide\.outputs\.(\w+)", r"o.\1", condition)
    expression = expression.replace("==", "===").replace("!===", "!==")
    assert "${{" not in expression and "steps." not in expression, expression
    return expression


def substitute(text: str, sha: str) -> str:
    """Evaluate the expressions this test understands for a promotion request."""
    text = re.sub(
        r"\$\{\{\s*inputs\.promote_nightly_next_sha\s*&&\s*format\('([^']*)',\s*inputs\.promote_nightly_next_sha\)\s*(?:\|\|\s*github\.event_name\s*==\s*'schedule'\s*&&\s*format\('[^']*',\s*github\.event\.schedule\)\s*)?\|\|\s*''\s*\}\}",
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


def queue(running: str, arrivals: list[str]) -> tuple[list[dict], list[dict]]:
    """Apply GitHub's one-running/one-waiting rule to requests arriving while `running` runs.

    Returns the requests that run, in order ({sha, runId, arrived}: how many
    requests had arrived when it started), and every dispatch run with its
    title and conclusion (a replaced waiting request is cancelled when the
    request that replaces it arrives).
    """
    group = concurrency_group(running)
    runs = [{"id": 1, "sha": running, "conclusion": "success", "arrived": 1}]
    started = [runs[0]]
    waiting: dict | None = None
    for index, sha in enumerate(arrivals, start=2):
        run = {"id": index, "sha": sha, "conclusion": "success", "arrived": index}
        runs.append(run)
        if concurrency_group(sha) != group:
            started.append(run)  # another group: it would run at once, as a second writer
            continue
        if waiting is not None:
            waiting["conclusion"] = "cancelled"
            waiting["cancelledBy"] = "queue"
            waiting["cancelledAt"] = index
        waiting = run
    if waiting is not None:
        # It starts once the running request finishes, after every arrival.
        started.append(dict(waiting, arrived=len(runs)))
    dispatch_runs = [
        {
            "id": run["id"],
            "display_title": run_title(run["sha"]),
            "event": "workflow_dispatch",
            "head_branch": "main",
            "status": "completed",
            "conclusion": run["conclusion"],
            "cancelledBy": run.get("cancelledBy"),
            "cancelledAt": run.get("cancelledAt"),
            "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        for run in runs
    ]
    return [{"sha": run["sha"], "runId": run["id"], "arrived": run["arrived"]} for run in started], dispatch_runs


def run_promotions(requests: list[dict], dispatch_runs: list[dict], *,
                   target: str = BASE, not_green: list[str] | None = None,
                   list_throws: bool = False, annotations_throw: bool = False,
                   annotations_throw_for: list[int] | None = None) -> dict:
    scenario = {
        "decide": step("Decide the promotion")["with"]["script"],
        "move": step("Move nightly-next")["with"]["script"],
        "moveIf": move_condition(),
        "history": HISTORY,
        "target": target,
        "requests": requests,
        "dispatchRuns": dispatch_runs,
        "notGreen": not_green or [],
        "listThrows": list_throws,
        "annotationsThrow": annotations_throw,
        "annotationsThrowFor": annotations_throw_for or [],
    }
    result = subprocess.run(
        ["node", "--input-type=module", "-e", HARNESS],
        cwd=ROOT,
        env={**os.environ, "SCENARIO": json.dumps(scenario), "GITHUB_WORKSPACE": str(ROOT)},
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def short(sha: str) -> str:
    return {BASE: "BASE", RUNNING: "RUNNING", OLDER: "OLDER", NEWER: "NEWER", UNGREEN: "UNGREEN"}[sha]


def ran(requests: list[dict]) -> list[str]:
    return [short(request["sha"]) for request in requests]


def test_one_writer_for_every_request() -> None:
    """Every request shares one group, so nightly-next never has two writers."""
    assert concurrency_group(OLDER) == concurrency_group(NEWER) == concurrency_group(RUNNING)
    assert promote_job()["concurrency"]["cancel-in-progress"] is False


def test_a_late_older_request_does_not_drop_a_cancelled_newer_one() -> None:
    """NEWER waits behind a running promotion and OLDER replaces it: NEWER must still land."""
    requests, dispatch_runs = queue(RUNNING, [NEWER, OLDER])
    assert ran(requests) == ["RUNNING", "OLDER"], ran(requests)
    result = run_promotions(requests, dispatch_runs)
    assert result["failed"] == [], result["failed"]
    assert result["target"] == NEWER, (
        f"nightly-next stopped at {short(result['target'])}; the cancelled request for NEWER was "
        f"dropped (requests that ran: {ran(requests)})"
    )
    assert result["writes"] == [RUNNING, NEWER], [short(sha) for sha in result["writes"]]


def test_a_newer_request_after_an_older_one_still_wins() -> None:
    """The ordinary order: the evicted OLDER request is not newer, so NEWER lands."""
    requests, dispatch_runs = queue(RUNNING, [OLDER, NEWER])
    result = run_promotions(requests, dispatch_runs)
    assert result["failed"] == [], result["failed"]
    assert result["target"] == NEWER, short(result["target"])
    assert result["writes"] == [RUNNING, NEWER], [short(sha) for sha in result["writes"]]


def test_a_cancelled_request_without_a_green_compile_is_still_promoted() -> None:
    """Recovered requests pass the same guard as the input. With G2 off (#25786)
    a missing Release compile no longer refuses: the promoted commit's own
    nightly build is the compile gate, so the newest evicted commit wins."""
    requests, dispatch_runs = queue(RUNNING, [UNGREEN, OLDER])
    result = run_promotions(requests, dispatch_runs, not_green=[UNGREEN])
    assert result["failed"] == [], result["failed"]
    assert result["target"] == UNGREEN, short(result["target"])
    assert OLDER not in result["writes"], [short(sha) for sha in result["writes"]]


def test_a_request_cancelled_by_a_person_is_not_promoted() -> None:
    """Only requests GitHub cancelled in the queue are recovered, not deliberate cancels."""
    requests, dispatch_runs = queue(RUNNING, [OLDER])
    manual = dict(dispatch_runs[-1], id=len(dispatch_runs) + 1, conclusion="cancelled",
                  cancelledBy="person", cancelledAt=0, display_title=run_title(NEWER))
    result = run_promotions(requests, dispatch_runs + [manual])
    assert result["failed"] == [], result["failed"]
    assert result["target"] == OLDER, (
        f"nightly-next moved to {short(result['target'])}, a request a person cancelled"
    )


def test_a_failed_recovery_scan_still_promotes_the_admitted_commit() -> None:
    """An API error while listing the other requests must not drop this request."""
    requests, dispatch_runs = queue(RUNNING, [NEWER, OLDER])
    result = run_promotions(requests, dispatch_runs, list_throws=True)
    assert result["failed"] == [], result["failed"]
    assert result["target"] == OLDER, short(result["target"])
    assert result["warnings"], "the failed scan should leave a warning"


def test_an_unreadable_cancel_annotation_still_promotes_the_admitted_commit() -> None:
    """Without checks: read (or on any annotation error) the request decides its own commit."""
    requests, dispatch_runs = queue(RUNNING, [NEWER, OLDER])
    result = run_promotions(requests, dispatch_runs, annotations_throw=True)
    assert result["failed"] == [], result["failed"]
    assert result["target"] == OLDER, short(result["target"])
    assert any("cancelled in the promote queue" in warning for warning in result["warnings"]), result["warnings"]


def test_one_unreadable_cancel_annotation_keeps_the_other_evicted_requests() -> None:
    """A 403 or 404 on one cancelled run skips that run; NEWER, evicted, still lands."""
    requests, dispatch_runs = queue(RUNNING, [NEWER, OLDER])
    broken = dict(dispatch_runs[-1], id=len(dispatch_runs) + 1, conclusion="cancelled",
                  cancelledBy="queue", cancelledAt=0, display_title=run_title(UNGREEN))
    result = run_promotions(requests, dispatch_runs + [broken], annotations_throw_for=[broken["id"]])
    assert result["failed"] == [], result["failed"]
    assert result["target"] == NEWER, (
        f"nightly-next stopped at {short(result['target'])}; one unreadable annotation dropped every evicted request"
    )
    assert any(str(broken["id"]) in warning for warning in result["warnings"]), result["warnings"]


def test_the_promote_job_can_read_the_cancel_annotation() -> None:
    assert promote_job()["permissions"].get("checks") == "read", promote_job()["permissions"]


def main() -> None:
    # Every test_ function runs: a hand-kept list dropped the ungreen case
    # without anyone noticing (#24590).
    tests = [value for name, value in globals().items() if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS: nightly-next promotion queue ({len(tests)} cases)")

if __name__ == "__main__":
    main()
