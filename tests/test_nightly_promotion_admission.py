#!/usr/bin/env python3
"""Behavior of the nightly-next promote guard (scripts/ci/promote-nightly-next.mjs).

The guard runs from main in nightly.yml. Each case drives it against an
in-memory GitHub API (runs, jobs, refs, commits, pull requests, repository
activity, deployment approvals) and checks the decision the workflow acts on:

- G1: a SHA that is not on feat-cmux-next is refused.
- G2: only a cmux-next.yml push run of this repository proves the Release
  compile; a same-named job in another workflow does not. The lookup retries
  while GitHub's index lags.
- G3: a range that changes no release surface file is promoted; a range that
  changes one needs an approval.
- G4: the approval must come from someone who did not land the surface
  change (push actor, PR author or merger, commit author) and did not start
  the run; a missing push actor fails closed.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "scripts" / "ci" / "promote-nightly-next.mjs"
SURFACE = (ROOT / ".github" / "release-surface.txt").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "nightly.yml").read_text(encoding="utf-8")

CURRENT = "c" * 40
MID = "d" * 40
SHA = "a" * 40

HARNESS = r"""
const scenario = JSON.parse(process.env.SCENARIO);
const guard = await import(process.env.GUARD);
const calls = { runs: 0, jobs: 0, activityPages: 0, moves: 0 };
const pullsListCommits = Symbol('listCommits');
const notices = [];
const actions = { listWorkflowRuns: async () => ({ data: { workflow_runs: [] } }), listJobsForWorkflowRun: Symbol('jobs') };
const commits = Object.fromEntries(scenario.commits.map((c) => [c.sha, c]));
const github = {
  rest: {
    actions,
    git: {
      getRef: async ({ ref }) => {
        if (ref === 'heads/feat-cmux-next') return { data: { object: { sha: scenario.sourceHead } } };
        if (ref === 'heads/nightly-next') return { data: { object: { sha: scenario.current } } };
        throw Object.assign(new Error('missing'), { status: 404 });
      },
    },
    repos: {
      compareCommitsWithBasehead: async ({ basehead }) => {
        const [base, head] = basehead.split('...');
        if (base === scenario.current && head === scenario.sha) return { data: { status: 'ahead', files: scenario.rangeFiles } };
        if (head === scenario.sourceHead) return { data: { status: scenario.onSource[base] || 'diverged' } };
        throw new Error(`unexpected compare ${basehead}`);
      },
      getCommit: async ({ ref }) => {
        if (!commits[ref]) throw new Error(`unexpected commit ${ref}`);
        return { data: commits[ref] };
      },
    },
    pulls: { get: async ({ pull_number }) => ({ data: scenario.pulls[pull_number] }), listCommits: pullsListCommits },
  },
  paginate: Object.assign(async (method, params) => {
    if (method === pullsListCommits) return scenario.prCommits[params.pull_number] || [];
    if (method === actions.listWorkflowRuns) {
      calls.runs += 1;
      return calls.runs <= scenario.emptyRuns ? [] : scenario.runs;
    }
    if (method === actions.listJobsForWorkflowRun) {
      calls.jobs += 1;
      return scenario.jobs[params.run_id] || [];
    }
    throw new Error('unexpected paginate');
  }, {
    // The activity API pages with a cursor: one event per page here, so the
    // guard must follow the pages instead of re-reading the first one.
    iterator: (route, params) => {
      if (route !== 'GET /repos/{owner}/{repo}/activity' || params.ref !== 'refs/heads/feat-cmux-next') throw new Error(`unexpected iterator ${route}`);
      return (async function* () {
        for (const event of scenario.activity) { calls.activityPages += 1; yield { data: [event] }; }
      })();
    },
  }),
  request: async (route, params) => {
    if (route === 'GET /repos/{owner}/{repo}/commits/{commit_sha}/pulls') return { data: scenario.commitPulls[params.commit_sha] || [] };
    if (route === 'GET /repos/{owner}/{repo}/actions/runs/{run_id}/approvals') return { data: scenario.approvals };
    throw new Error(`unexpected request ${route}`);
  },
};
const core = { notice: (m) => notices.push(m) };
const decision = await guard.decide({
  github, core, owner: 'manaflow-ai', repo: 'cmux', sha: scenario.sha,
  surfaceText: scenario.surface, sleep: async () => {},
});
const approvers = await guard.approvedBy({ github, owner: 'manaflow-ai', repo: 'cmux', runId: 1 });
let policy = { require_non_lander_approver: true };
try { policy = guard.parsePolicy(scenario.surface); } catch (error) { /* decide() refused it */ }
const ack = guard.ackDecision({ decision, approvers, triggeringActor: scenario.triggeringActor, expectedCurrent: scenario.current, requireNonLander: policy.require_non_lander_approver });
let moveError = null;
if (scenario.movedTo !== undefined) {
  const moved = { rest: { git: {
    getRef: async () => ({ data: { object: { sha: scenario.movedTo } } }),
    updateRef: async () => { calls.moves += 1; },
    createRef: async () => { calls.moves += 1; },
  } } };
  try { await guard.move({ writer: moved, github: moved, owner: 'manaflow-ai', repo: 'cmux', decision }); }
  catch (error) { moveError = error.message; }
}
console.log(JSON.stringify({ decision, ack, calls, notices, moveError }));
"""


def gate_run(**overrides) -> dict:
    run = {
        "id": 7, "head_sha": SHA, "head_branch": "feat-cmux-next", "event": "push",
        "path": ".github/workflows/cmux-next.yml", "head_repository": {"full_name": "manaflow-ai/cmux"},
    }
    run.update(overrides)
    return run


GREEN = [{"name": "cmux-next Release compile (Xcode 26)", "status": "completed", "conclusion": "success"}]


def scenario(**overrides) -> dict:
    base = {
        "sha": SHA,
        "sourceHead": SHA,
        "current": CURRENT,
        "onSource": {SHA: "identical"},
        "emptyRuns": 0,
        "runs": [gate_run()],
        "jobs": {"7": GREEN},
        "rangeFiles": [{"filename": "Sources/App.swift"}],
        # SHA (Leo's PR merge) -> MID (Lawrence's safe-push) -> CURRENT
        "commits": [
            {"sha": SHA, "parents": [{"sha": MID}], "author": {"login": "teamleaderleo"},
             "committer": {"login": "web-flow"}, "files": [{"filename": "Sources/App.swift"}]},
            {"sha": MID, "parents": [{"sha": CURRENT}], "author": {"login": "lawrencecchen"},
             "committer": {"login": "lawrencecchen"}, "files": [{"filename": "README.md"}]},
        ],
        "activity": [
            {"before": MID, "after": SHA, "actor": {"login": "teamleaderleo"}},
            {"before": CURRENT, "after": MID, "actor": {"login": "lawrencecchen"}},
        ],
        "commitPulls": {SHA: [{"number": 5, "merged_at": "2026-10-15T00:00:00Z", "user": {"login": "teamleaderleo"}}]},
        "pulls": {"5": {"merged_by": {"login": "teamleaderleo"}}},
        "prCommits": {},
        "approvals": [],
        "triggeringActor": "github-actions[bot]",
        "surface": SURFACE,
    }
    base.update(overrides)
    base["jobs"] = {str(k): v for k, v in base["jobs"].items()}
    base["pulls"] = {str(k): v for k, v in base["pulls"].items()}
    base["prCommits"] = {str(k): v for k, v in base["prCommits"].items()}
    return base


def run(case: dict) -> dict:
    result = subprocess.run(
        ["node", "--input-type=module", "-e", HARNESS],
        cwd=ROOT,
        env={**os.environ, "SCENARIO": json.dumps(case), "GUARD": str(GUARD)},
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


LANDER_RULE_ON = SURFACE.replace("@require_non_lander_approver off", "@require_non_lander_approver on")


def surface_change(lander_rule: bool = True) -> dict:
    case = scenario(rangeFiles=[{"filename": ".github/workflows/nightly.yml"}],
                    surface=LANDER_RULE_ON if lander_rule else SURFACE)
    case["commits"][0]["files"] = [{"filename": ".github/workflows/nightly.yml"}]
    return case


def test_lander_rule_ships_off_and_a_lander_may_approve() -> None:
    assert "@require_non_lander_approver off" in SURFACE
    case = surface_change(lander_rule=False)
    case["approvals"] = [{"state": "approved", "user": {"login": "teamleaderleo"},
                          "environments": [{"name": "release-surface-ack"}]}]
    out = run(case)
    assert out["decision"]["action"] == "needs-ack"
    assert out["ack"]["ok"] and out["ack"]["approver"] == "teamleaderleo", out["ack"]


def test_an_unknown_policy_line_refuses_the_promotion() -> None:
    case = surface_change()
    case["surface"] = SURFACE.replace("@require_non_lander_approver off", "@require_non_lander_approver ON")
    out = run(case)
    assert out["decision"]["action"] == "refuse"
    assert "unknown policy line" in out["decision"]["reason"]


def test_with_the_lander_rule_off_an_unknown_push_actor_does_not_block() -> None:
    case = surface_change(lander_rule=False)
    case["activity"] = []
    case["approvals"] = [{"state": "approved", "user": {"login": "lawrencecchen"},
                          "environments": [{"name": "release-surface-ack"}]}]
    out = run(case)
    assert out["decision"]["action"] == "needs-ack", out["decision"]
    assert out["ack"]["ok"]


def test_with_the_lander_rule_off_an_approval_is_still_required() -> None:
    out = run(surface_change(lander_rule=False))
    assert not out["ack"]["ok"]


def test_non_surface_range_is_promoted() -> None:
    out = run(scenario())
    assert out["decision"]["action"] == "promote", out
    assert out["ack"]["ok"]


def test_sha_not_on_feat_cmux_next_is_refused() -> None:
    out = run(scenario(onSource={SHA: "diverged"}, sourceHead="e" * 40))
    assert out["decision"]["action"] == "refuse"
    assert "is not on feat-cmux-next" in out["decision"]["reason"]


def test_same_named_job_in_another_workflow_does_not_admit() -> None:
    out = run(scenario(runs=[gate_run(path=".github/workflows/other.yml")]))
    assert out["decision"]["action"] == "refuse"
    out = run(scenario(runs=[gate_run(head_repository={"full_name": "someone/cmux"})]))
    assert out["decision"]["action"] == "refuse"


def test_admission_retries_while_the_index_lags() -> None:
    out = run(scenario(emptyRuns=2))
    assert out["decision"]["action"] == "promote"
    assert out["calls"]["runs"] == 3
    assert any("retry" in notice for notice in out["notices"])


def test_in_progress_success_is_not_admission() -> None:
    out = run(scenario(jobs={7: [dict(GREEN[0], status="in_progress")]}))
    assert out["decision"]["action"] == "refuse"


def test_surface_change_needs_a_non_lander_approval() -> None:
    out = run(surface_change())
    decision = out["decision"]
    assert decision["action"] == "needs-ack", decision
    assert decision["surfaceFiles"] == [".github/workflows/nightly.yml"]
    assert decision["landers"] == ["teamleaderleo"]
    assert not out["ack"]["ok"]  # nobody approved yet


def test_lander_cannot_approve_their_own_surface_change() -> None:
    case = surface_change()
    case["approvals"] = [{"state": "approved", "user": {"login": "teamleaderleo"},
                          "environments": [{"name": "release-surface-ack"}]}]
    assert not run(case)["ack"]["ok"]


def test_other_release_approver_can_approve() -> None:
    case = surface_change()
    case["approvals"] = [{"state": "approved", "user": {"login": "austinywang"},
                          "environments": [{"name": "release-surface-ack"}]}]
    out = run(case)
    assert out["ack"]["ok"], out["ack"]
    assert out["ack"]["approver"] == "austinywang"


def test_approval_for_another_environment_does_not_count() -> None:
    case = surface_change()
    case["approvals"] = [{"state": "approved", "user": {"login": "austinywang"},
                          "environments": [{"name": "release"}]}]
    assert not run(case)["ack"]["ok"]


def test_push_actor_is_a_lander_even_with_a_spoofed_author() -> None:
    case = surface_change()
    # The commit claims Leo as author, but Lawrence's token pushed it.
    case["activity"][0]["actor"] = {"login": "lawrencecchen"}
    case["commitPulls"] = {}
    case["approvals"] = [{"state": "approved", "user": {"login": "lawrencecchen"},
                          "environments": [{"name": "release-surface-ack"}]}]
    out = run(case)
    assert "lawrencecchen" in out["decision"]["landers"]
    assert not out["ack"]["ok"]


def test_unknown_push_actor_fails_closed() -> None:
    case = surface_change()
    case["activity"] = []
    out = run(case)
    assert out["decision"]["action"] == "refuse"
    assert "push actor" in out["decision"]["reason"]


def test_activity_pages_are_followed_and_one_push_covers_its_commits() -> None:
    case = surface_change()
    # One push brought MID and SHA; an unrelated event comes first.
    case["activity"] = [
        {"before": "f" * 40, "after": "e" * 40, "actor": {"login": "austinywang"}},
        {"before": CURRENT, "after": SHA, "actor": {"login": "lawrencecchen"}},
    ]
    out = run(case)
    assert out["decision"]["action"] == "needs-ack", out["decision"]
    assert "lawrencecchen" in out["decision"]["landers"]
    assert out["calls"]["activityPages"] == 2


def test_a_pr_contributor_is_a_lander() -> None:
    case = surface_change()
    case["prCommits"] = {5: [{"author": {"login": "azooz2003-bit"}, "committer": {"login": "azooz2003-bit"}}]}
    case["approvals"] = [{"state": "approved", "user": {"login": "azooz2003-bit"},
                          "environments": [{"name": "release-surface-ack"}]}]
    out = run(case)
    assert "azooz2003-bit" in out["decision"]["landers"]
    assert not out["ack"]["ok"]


def test_move_refuses_when_nightly_next_moved_after_the_decision() -> None:
    out = run(scenario(movedTo="9" * 40))
    assert out["moveError"] and "request the promotion again" in out["moveError"]
    assert out["calls"]["moves"] == 0
    out = run(scenario(movedTo=CURRENT))
    assert out["moveError"] is None and out["calls"]["moves"] == 1


def test_already_promoted_is_a_quiet_no_op_after_approval() -> None:
    out = run(scenario(current=SHA))
    assert out["decision"]["action"] == "skip"
    assert out["ack"]["ok"] and not out["ack"]["move"]


def test_workflow_runs_the_guard_from_main_and_gates_the_move() -> None:
    assert "environment: nightly-next-promote" in WORKFLOW
    assert "environment: release-surface-ack" in WORKFLOW
    assert "requested.startsWith('dry-run:')" in WORKFLOW
    assert "ref: ${{ github.sha }}" in WORKFLOW
    assert "if: steps.decide.outputs.action == 'promote' && steps.decide.outputs.dry_run != 'true'" in WORKFLOW
    assert "if: needs.promote-nightly-next.outputs.action == 'needs-ack' && needs.promote-nightly-next.outputs.dry_run != 'true'" in WORKFLOW
    assert "group: nightly-next-promote-ack-${{ github.run_id }}" in WORKFLOW
    assert "requireNonLander: policy.require_non_lander_approver" in WORKFLOW


def main() -> None:
    tests = [value for name, value in globals().items() if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS: nightly-next promote guard ({len(tests)} cases)")


if __name__ == "__main__":
    main()
