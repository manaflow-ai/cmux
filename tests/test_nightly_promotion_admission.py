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
const calls = { runs: 0, jobs: 0, activityPages: 0, moves: 0, comparePages: 0, trees: 0 };
const pullsListCommits = Symbol('listCommits');
const notices = [];
const actions = { listWorkflowRuns: async () => ({ data: { workflow_runs: [] } }), listJobsForWorkflowRun: Symbol('jobs') };
const commits = Object.fromEntries(scenario.commits.map((c) => [c.sha, c]));
const trees = new Map();
function treeOf(sha) {
  if (trees.has(sha)) return trees.get(sha);
  const c = commits[sha];
  if (!c) throw new Error(`no tree for ${sha}`);
  let tree;
  if (c.tree) tree = { ...c.tree };
  else {
    tree = c.parents?.length ? { ...treeOf(c.parents[0].sha) } : {};
    for (const f of c.files || []) tree[f.filename] = sha;
  }
  trees.set(sha, tree);
  return tree;
}
const github = {
  rest: {
    actions,
    git: {
      getRef: async ({ ref }) => {
        if (ref === 'heads/feat-cmux-next') return { data: { object: { sha: scenario.sourceHead } } };
        if (ref === 'heads/nightly-next') return { data: { object: { sha: scenario.current } } };
        throw Object.assign(new Error('missing'), { status: 404 });
      },
      // Git trees: each commit's tree is its first parent's tree plus its own
      // files (blob = the commit that wrote it), unless the scenario gives an
      // explicit tree (a merge that resolves a conflict).
      getCommit: async ({ commit_sha }) => ({ data: { sha: commit_sha, tree: { sha: `T|${commit_sha}|` } } }),
      getTree: async ({ tree_sha, recursive }) => {
        const [, commitSha, dir] = tree_sha.split('|');
        calls.trees += 1;
        if (scenario.truncatedTree) return { data: { truncated: true, tree: [] } };
        const tree = treeOf(commitSha);
        const prefix = dir ? `${dir}/` : '';
        const entries = [];
        const subdirs = new Set();
        for (const [path, blob] of Object.entries(tree)) {
          if (!path.startsWith(prefix)) continue;
          const rel = path.slice(prefix.length);
          if (recursive || !rel.includes('/')) entries.push({ path: rel, type: 'blob', mode: '100644', sha: blob });
          else subdirs.add(rel.split('/')[0]);
        }
        for (const sub of subdirs) entries.push({ path: sub, type: 'tree', mode: '040000', sha: `T|${commitSha}|${prefix}${sub}` });
        return { data: { truncated: false, tree: entries } };
      },
    },
    repos: {
      // A small commit graph: compare(base...head) lists every commit reachable
      // from head and not from base (all parents), paginated, with the range's
      // files capped as GitHub caps them.
      compareCommitsWithBasehead: async ({ basehead, per_page = 250, page = 1 }) => {
        const [base, head] = basehead.split('...');
        // G1 asks sha...feat-cmux-next; the scenario states that answer.
        if (base === scenario.sha && head === scenario.sourceHead && base !== head) {
          return { data: { status: scenario.onSource[base] || 'diverged' } };
        }
        if (!(head in commits) && head !== scenario.current) throw new Error(`unexpected compare ${basehead}`);
        const reach = (from) => {
          const seen = new Set(); const stack = [from];
          while (stack.length) {
            const c = stack.pop();
            if (!c || seen.has(c)) continue;
            seen.add(c);
            for (const parent of (commits[c]?.parents || [])) stack.push(parent.sha);
          }
          return seen;
        };
        const fromHead = reach(head), fromBase = reach(base);
        const inRange = scenario.commits.filter((c) => fromHead.has(c.sha) && !fromBase.has(c.sha));
        let status = base === head ? 'identical' : fromHead.has(base) ? 'ahead' : fromBase.has(head) ? 'behind' : 'diverged';
        if (base === scenario.current && head === scenario.sha && scenario.rangeStatus) status = scenario.rangeStatus;
        const files = [];
        const names = new Set();
        for (const c of inRange) for (const f of c.files || []) if (!names.has(f.filename)) { names.add(f.filename); files.push(f); }
        const cap = scenario.compareFileCap ?? 300;
        const pageCommits = inRange.slice((page - 1) * per_page, page * per_page).map((c) => ({ sha: c.sha }));
        calls.comparePages += 1;
        return { data: { status, total_commits: scenario.totalCommitsOverride ?? inRange.length, commits: pageCommits, files: files.slice(0, cap) } };
      },
      getCommit: async ({ ref, per_page = 300, page = 1 }) => {
        const c = commits[ref];
        if (!c) throw new Error(`unexpected commit ${ref}`);
        const all = c.files || [];
        return { data: { ...c, files: all.slice((page - 1) * per_page, page * per_page) } };
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
            {"sha": CURRENT, "parents": [], "author": {"login": "lawrencecchen"},
             "committer": {"login": "lawrencecchen"}, "files": []},
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


def commit(sha, parents, files, who="lawrencecchen"):
    return {"sha": sha, "parents": [{"sha": p} for p in parents], "author": {"login": who},
            "committer": {"login": who}, "files": [{"filename": f} for f in files]}


def merge_shaped(touch_surface: bool) -> dict:
    # A lane merged origin/feat-cmux-next (the current nightly-next tip) into
    # its own branch: the tip is the SECOND parent of M, and M's first-parent
    # line never reaches it (run 38871179244 refused this as "cannot walk").
    base0, y, x, m = "0" * 39 + "1", "e" * 40, "f" * 40, "9" * 40
    changed = [".github/workflows/nightly.yml"] if touch_surface else ["Sources/Lane.swift"]
    case = scenario(commits=[
        commit(SHA, [m], ["Sources/App.swift"], "teamleaderleo"),
        commit(m, [x, CURRENT], changed),
        commit(x, [y], changed),
        commit(y, [base0], ["Sources/Old.swift"]),
        commit(CURRENT, [base0], ["Sources/Tip.swift"]),
        commit(base0, [], []),
    ], activity=[{"before": CURRENT, "after": SHA, "actor": {"login": "lawrencecchen"}}],
        commitPulls={}, surface=SURFACE)
    return case


def test_a_tip_on_the_second_parent_of_a_merge_promotes() -> None:
    out = run(merge_shaped(touch_surface=False))
    assert out["decision"]["action"] == "promote", out["decision"]


def test_a_tip_on_the_second_parent_of_a_merge_asks_for_an_ack() -> None:
    out = run(merge_shaped(touch_surface=True))
    assert out["decision"]["action"] == "needs-ack", out["decision"]
    assert out["decision"]["surfaceFiles"] == [".github/workflows/nightly.yml"]
    assert "lawrencecchen" in out["decision"]["landers"]


def long_range(count, surface_at=None) -> dict:
    shas = [f"{i:040x}" for i in range(1, count + 1)]
    chain = []
    for i, sha in enumerate(shas):
        parent = CURRENT if i == 0 else shas[i - 1]
        files = [".github/workflows/nightly.yml"] if i == surface_at else [f"Sources/F{i}.swift"]
        chain.append(commit(sha, [parent], files))
    chain.reverse()
    head = shas[-1]
    return scenario(sha=head, sourceHead=head, onSource={head: "identical"},
                    runs=[gate_run(head_sha=head)], commits=chain + [commit(CURRENT, [], [])],
                    activity=[{"before": CURRENT, "after": head, "actor": {"login": "teamleaderleo"}}],
                    commitPulls={}, surface=SURFACE)


def test_a_range_over_200_commits_promotes() -> None:
    out = run(long_range(250))
    assert out["decision"]["action"] == "promote", out["decision"]
    assert out["calls"]["comparePages"] >= 3  # the commit list was paged


def test_a_range_over_200_commits_with_a_surface_change_asks_for_an_ack() -> None:
    out = run(long_range(250, surface_at=7))
    assert out["decision"]["action"] == "needs-ack", out["decision"]
    assert out["decision"]["landers"] == ["lawrencecchen", "teamleaderleo"]


def test_a_diverged_or_behind_range_is_refused() -> None:
    for status in ("diverged", "behind"):
        out = run(scenario(rangeStatus=status))
        assert out["decision"]["action"] == "refuse", (status, out["decision"])
        assert "is not an ancestor" in out["decision"]["reason"]


def test_a_truncated_surface_tree_is_refused() -> None:
    out = run(scenario(truncatedTree=True))
    assert out["decision"]["action"] == "refuse", out["decision"]
    assert "truncated" in out["decision"]["reason"]


def test_a_large_commit_outside_the_surface_still_promotes() -> None:
    big = [f"Sources/G{i}.swift" for i in range(3000)]
    case = scenario(commits=[commit(SHA, [CURRENT], big), commit(CURRENT, [], [])],
                    activity=[{"before": CURRENT, "after": SHA, "actor": {"login": "lawrencecchen"}}],
                    commitPulls={})
    out = run(case)
    assert out["decision"]["action"] == "promote", out["decision"]


def test_a_merge_that_drops_the_old_tips_surface_change_asks_for_an_ack() -> None:
    # The old tip C changed nightly.yml; merge S (first parent M, second parent
    # C) kept M's version. No commit's own diff lists nightly.yml, but the
    # tree from C to the target differs there: it must not promote silently.
    base0, mline, merge = "0" * 39 + "1", "e" * 40, "9" * 40
    nightly = ".github/workflows/nightly.yml"
    case = scenario(commits=[
        commit(SHA, [merge], ["Sources/App.swift"], "teamleaderleo"),
        dict(commit(merge, [mline, CURRENT], []), tree={nightly: base0, "Sources/M.swift": mline}),
        commit(mline, [base0], ["Sources/M.swift"]),
        commit(CURRENT, [base0], [nightly]),
        commit(base0, [], [nightly]),
    ], activity=[{"before": CURRENT, "after": SHA, "actor": {"login": "austinywang"}}], commitPulls={})
    out = run(case)
    assert out["decision"]["action"] == "needs-ack", out["decision"]
    assert out["decision"]["surfaceFiles"] == [nightly]
    assert "austinywang" in out["decision"]["landers"]


def test_a_merge_that_changes_a_second_surface_file_is_a_lander_too() -> None:
    # Commit A (Leo) touches nightly.yml; merge S (Austin's push) resolves
    # cmux-next.yml to a version no commit's own diff lists.
    base0, a, mline, merge = "0" * 39 + "1", "b" * 40, "e" * 40, "9" * 40
    nightly, gate = ".github/workflows/nightly.yml", ".github/workflows/cmux-next.yml"
    case = scenario(commits=[
        commit(SHA, [merge], ["Sources/App.swift"], "teamleaderleo"),
        dict(commit(merge, [mline, a], []), tree={nightly: a, gate: base0, "Sources/M.swift": mline}),
        commit(a, [CURRENT], [nightly], "teamleaderleo"),
        commit(mline, [base0], ["Sources/M.swift"], "teamleaderleo"),
        commit(CURRENT, [base0], [gate]),
        commit(base0, [], [gate]),
    ], activity=[{"before": CURRENT, "after": SHA, "actor": {"login": "teamleaderleo"}},
                 {"before": "f" * 40, "after": merge, "actor": {"login": "austinywang"}}],
        commitPulls={}, surface=LANDER_RULE_ON)
    out = run(case)
    assert out["decision"]["action"] == "needs-ack", out["decision"]
    assert out["decision"]["surfaceFiles"] == [gate, nightly]
    assert merge in out["decision"]["touching"], out["decision"]


def test_a_deleted_surface_file_asks_for_an_ack() -> None:
    nightly = ".github/workflows/nightly.yml"
    case = scenario(commits=[
        dict(commit(SHA, [CURRENT], [nightly], "teamleaderleo"), tree={"Sources/App.swift": SHA}),
        commit(CURRENT, [], [nightly, "Sources/App.swift"]),
    ], activity=[{"before": CURRENT, "after": SHA, "actor": {"login": "teamleaderleo"}}], commitPulls={})
    out = run(case)
    assert out["decision"]["action"] == "needs-ack", out["decision"]
    assert out["decision"]["surfaceFiles"] == [nightly]


def test_a_commit_list_the_api_cannot_cover_is_refused() -> None:
    out = run(scenario(totalCommitsOverride=5000))
    assert out["decision"]["action"] == "refuse", out["decision"]


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
