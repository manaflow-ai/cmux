#!/usr/bin/env python3
"""Regression coverage for queued nightly-next promotion requests.

Main's promote-nightly-next job is dispatched once per request, and requests
for different feat-cmux-next commits can arrive out of order (an older
commit's Release compile or tree publication can finish after a newer one's).
GitHub keeps at most one waiting job per concurrency group and cancels the
waiting one when another arrives, so a shared group let a late request for an
older commit replace the waiting request for a newer one: nightly-next then
stopped at the older commit and the newer promotion was silently dropped.

The test evaluates the job's real concurrency group for each request, applies
GitHub's one-running/one-waiting rule, then runs the real promotion script for
every request that survives against a mocked branch that only fast-forwards.
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
BASE, RUNNING, OLDER, NEWER = ("1" * 40, "2" * 40, "3" * 40, "4" * 40)
HISTORY = [BASE, RUNNING, OLDER, NEWER]


HARNESS = r"""
const scenario = JSON.parse(process.env.SCENARIO);
const history = scenario.history;
const position = (sha) => {
  const index = history.indexOf(sha);
  if (index < 0) throw new Error(`unknown commit ${sha}`);
  return index;
};
const state = { target: scenario.target, staleReads: scenario.staleReads || 0 };
const failed = [];
const notices = [];
const writes = [];
const actions = {
  listWorkflowRuns: Symbol('listWorkflowRuns'),
  listJobsForWorkflowRun: Symbol('listJobsForWorkflowRun'),
};
const compareStatus = (base, head) => {
  const a = position(base);
  const b = position(head);
  return a === b ? 'identical' : a < b ? 'ahead' : 'behind';
};
const github = {
  rest: {
    actions,
    git: {
      getRef: async ({ ref }) => {
        if (ref === 'heads/feat-cmux-next') return { data: { object: { sha: history[history.length - 1] } } };
        if (ref !== 'heads/nightly-next') throw new Error(`unexpected ref ${ref}`);
        // A stale read models another promotion moving the branch between
        // this run's read and its write.
        if (state.staleReads > 0) {
          state.staleReads -= 1;
          return { data: { object: { sha: scenario.staleTarget } } };
        }
        return { data: { object: { sha: state.target } } };
      },
    },
    repos: {
      compareCommitsWithBasehead: async ({ basehead }) => {
        const [base, head] = basehead.split('...');
        return { data: { status: compareStatus(base, head) } };
      },
    },
  },
  paginate: async (method, params) => {
    if (method === actions.listWorkflowRuns) {
      return [{ id: 1, head_sha: params.head_sha, head_branch: 'feat-cmux-next', event: 'push' }];
    }
    if (method === actions.listJobsForWorkflowRun) {
      return [{ name: 'cmux-next Release compile (Xcode 26)', status: 'completed', conclusion: 'success' }];
    }
    throw new Error('unexpected pagination');
  },
};
const writer = {
  rest: {
    git: {
      // GitHub refuses a non-forced update that is not a fast-forward.
      updateRef: async ({ ref, sha, force }) => {
        if (ref !== 'heads/nightly-next') throw new Error(`unexpected write to ${ref}`);
        if (!force && position(sha) < position(state.target)) {
          const error = new Error('Update is not a fast forward');
          error.status = 422;
          throw error;
        }
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
const context = { repo: { owner: 'manaflow-ai', repo: 'cmux' } };
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


def promote_job() -> dict:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return workflow["jobs"]["promote-nightly-next"]


def promotion_script() -> str:
    steps = promote_job()["steps"]
    return next(step["with"]["script"] for step in steps if step.get("name") == "Move nightly-next")


def concurrency_group(sha: str) -> str:
    """Evaluate the job's concurrency group for a request of `sha`."""
    concurrency = promote_job().get("concurrency")
    if concurrency is None:
        return f"<no group {sha}>"
    group = concurrency["group"] if isinstance(concurrency, dict) else concurrency
    group = re.sub(r"\$\{\{\s*inputs\.promote_nightly_next_sha\s*\}\}", sha, group)
    group = re.sub(r"\$\{\{\s*github\.event\.inputs\.promote_nightly_next_sha\s*\}\}", sha, group)
    assert "${{" not in group, f"unsupported expression in the promote job's concurrency group: {group}"
    return group


def surviving_requests(running: str, arrivals: list[str]) -> list[str]:
    """Apply GitHub's concurrency rule to requests arriving while `running` runs.

    A group holds one running job and at most one waiting job; a new arrival
    replaces (cancels) the waiting one. A request in an idle group starts at
    once. Returns the requests that run, in start order.
    """
    running_groups = {concurrency_group(running): running}
    started = [running]
    waiting: dict[str, str] = {}
    for sha in arrivals:
        group = concurrency_group(sha)
        if group in running_groups:
            waiting[group] = sha
        else:
            running_groups[group] = sha
            started.append(sha)
    return started + list(waiting.values())


def run_promotions(requests: list[str], *, target: str = BASE,
                   stale_reads: int = 0, stale_target: str | None = None) -> dict:
    scenario = {
        "script": promotion_script(),
        "history": HISTORY,
        "target": target,
        "requests": requests,
        "staleReads": stale_reads,
        "staleTarget": stale_target,
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


def test_a_late_older_request_does_not_drop_a_waiting_newer_one() -> None:
    """NEWER arrives while a promotion runs, then OLDER arrives: NEWER must still land."""
    requests = surviving_requests(RUNNING, [NEWER, OLDER])
    assert NEWER in requests, (
        "the request for the newer commit was cancelled by a later request for an older one "
        f"(requests that run: {requests})"
    )
    result = run_promotions(requests)
    assert result["failed"] == [], result["failed"]
    assert result["target"] == NEWER, f"nightly-next stopped at {result['target']}, not {NEWER}"


def test_duplicate_requests_for_one_commit_still_share_a_group() -> None:
    """Requests for the same commit keep serializing, so a burst runs once at a time."""
    assert concurrency_group(NEWER) == concurrency_group(NEWER)
    assert concurrency_group(NEWER) != concurrency_group(OLDER)


def test_an_older_promotion_racing_a_newer_one_leaves_the_newer_one() -> None:
    """OLDER read nightly-next before NEWER moved it; its write must not fail the run."""
    result = run_promotions([OLDER], target=NEWER, stale_reads=1, stale_target=RUNNING)
    assert result["failed"] == [], result["failed"]
    assert result["target"] == NEWER
    assert result["writes"] == []
    assert any("nothing promoted" in notice for notice in result["notices"]), result["notices"]


def main() -> None:
    test_a_late_older_request_does_not_drop_a_waiting_newer_one()
    test_duplicate_requests_for_one_commit_still_share_a_group()
    test_an_older_promotion_racing_a_newer_one_leaves_the_newer_one()
    print("PASS: nightly-next promotion queue")


if __name__ == "__main__":
    main()
