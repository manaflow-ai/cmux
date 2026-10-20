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
- Newest request wins (decideNewest): a request steps aside for a live waiter
  whose commit contains its own, decides a newer waiter's commit instead of its
  own older one, and cancels nothing when it cannot read the other requests.
  A newer request GitHub evicted from the promote queue in the last day is
  decided like a dead waiter; a person's cancel, an older or ungreen commit
  and a dry run are not.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "scripts" / "ci" / "promote-nightly-next.mjs"
SURFACE = (ROOT / ".github" / "release-surface.txt").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "nightly.yml").read_text(encoding="utf-8")

CURRENT = "c" * 40
MID = "d" * 40
SHA = "a" * 40
NEWER = "b" * 40

HARNESS = r"""
// From a file: a long range's scenario is over Linux's 128 KiB limit for one
// environment variable (E2BIG).
const scenario = JSON.parse((await import('node:fs')).readFileSync(process.env.SCENARIO_FILE, 'utf8'));
const guard = await import(process.env.GUARD);
const calls = { runs: 0, jobs: 0, activityPages: 0, moves: 0, comparePages: 0, trees: 0, commitReads: 0, commitInFlight: 0, commitMaxInFlight: 0 };
const pullsListCommits = Symbol('listCommits');
const notices = [];
const actions = {
  // Only decideNewest() lists runs without paginating: the promotion requests on main.
  listWorkflowRuns: async (params) => {
    if (scenario.dispatchThrows) throw Object.assign(new Error('Service Unavailable'), { status: 503 });
    return { data: { workflow_runs: (scenario.dispatchRuns || []).filter((run) => run.status === params.status) } };
  },
  listJobsForWorkflowRun: Symbol('jobs'),
};
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
    // The annotations on a request's promote job (evictedPromotions()).
    checks: { listAnnotations: async ({ check_run_id }) => ({ data: (scenario.annotations || {})[check_run_id] || [] }) },
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
      // Each read takes a little time, as on GitHub, so the test sees how
      // many the guard keeps in flight at once.
      getCommit: async ({ ref, per_page = 300, page = 1 }) => {
        const c = commits[ref];
        if (!c) throw new Error(`unexpected commit ${ref}`);
        calls.commitReads += 1;
        calls.commitInFlight += 1;
        calls.commitMaxInFlight = Math.max(calls.commitMaxInFlight, calls.commitInFlight);
        await new Promise((resolve) => setTimeout(resolve, 1));
        calls.commitInFlight -= 1;
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
    if (route === 'GET /repos/{owner}/{repo}/commits/{commit_sha}/pulls') {
      // GitHub answers 500 now and then (run 39413299148): the first
      // `pullsErrors` reads of this list fail with a server error.
      calls.pullsReads = (calls.pullsReads || 0) + 1;
      if (calls.pullsReads <= (scenario.pullsErrors || 0)) throw Object.assign(new Error('Server Error'), { status: scenario.pullsErrorStatus || 500 });
      return { data: scenario.commitPulls[params.commit_sha] || [] };
    }
    if (route === 'GET /repos/{owner}/{repo}/actions/runs/{run_id}/approvals') return { data: scenario.approvals };
    throw new Error(`unexpected request ${route}`);
  },
};
const core = { notice: (m) => notices.push(m), warning: (m) => notices.push(`warning: ${m}`) };
let newest = null;
const decision = scenario.newest
  ? (newest = await guard.decideNewest({
      github, core, owner: 'manaflow-ai', repo: 'cmux', sha: scenario.sha, runId: 1,
      surfaceText: scenario.surface, sleep: async () => {},
    })).decision
  : await guard.decide({
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
console.log(JSON.stringify({ decision, ack, calls, notices, moveError, newest }));
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
    with tempfile.NamedTemporaryFile("w", suffix=".json") as scenario_file:
        json.dump(case, scenario_file)
        scenario_file.flush()
        result = subprocess.run(
            ["node", "--input-type=module", "-e", HARNESS],
            cwd=ROOT,
            env={**os.environ, "SCENARIO_FILE": scenario_file.name, "GUARD": str(GUARD)},
            capture_output=True, text=True, check=False,
        )
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def policy_surface(value: str) -> str:
    return re.sub(r"(?m)^@require_non_lander_approver (?:on|off)$",
                  f"@require_non_lander_approver {value}", SURFACE)


LANDER_RULE_ON = policy_surface("on")
LANDER_RULE_OFF = policy_surface("off")


def surface_change(lander_rule: bool = True) -> dict:
    case = scenario(rangeFiles=[{"filename": ".github/workflows/nightly.yml"}],
                    surface=LANDER_RULE_ON if lander_rule else LANDER_RULE_OFF)
    case["commits"][0]["files"] = [{"filename": ".github/workflows/nightly.yml"}]
    return case


def test_lander_rule_ships_on() -> None:
    assert "@require_non_lander_approver on" in SURFACE.splitlines()


def test_with_lander_rule_off_a_lander_may_approve() -> None:
    case = surface_change(lander_rule=False)
    case["approvals"] = [{"state": "approved", "user": {"login": "teamleaderleo"},
                          "environments": [{"name": "release-surface-ack"}]}]
    out = run(case)
    assert out["decision"]["action"] == "needs-ack"
    assert out["ack"]["ok"] and out["ack"]["approver"] == "teamleaderleo", out["ack"]


def test_an_unknown_policy_line_refuses_the_promotion() -> None:
    case = surface_change()
    case["surface"] = re.sub(r"(?m)^@require_non_lander_approver (?:on|off)$",
                             "@require_non_lander_approver ON", SURFACE)
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


def test_first_promotion_refuses_when_commit_authors_cannot_be_bounded() -> None:
    case = surface_change()
    case["current"] = None
    case["approvals"] = [{"state": "approved", "user": {"login": "teamleaderleo"},
                          "environments": [{"name": "release-surface-ack"}]}]
    out = run(case)
    assert out["decision"]["action"] == "refuse", out["decision"]
    assert "does not exist" in out["decision"]["reason"]


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


def test_unknown_surface_commit_author_fails_closed() -> None:
    case = surface_change()
    case["commits"][0]["author"] = None
    case["approvals"] = [{"state": "approved", "user": {"login": "austinywang"},
                          "environments": [{"name": "release-surface-ack"}]}]
    out = run(case)
    assert out["decision"]["action"] == "refuse", out["decision"]
    assert "author" in out["decision"]["reason"]


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


def merged_long_range(main_count, side_count, surface_at_side=None) -> dict:
    # A long feat-cmux-next range with a big merge (like the iOS merge
    # ebc7d9c6296): side_count commits on a side branch from CURRENT, merged
    # into a main_count-commit line. Over 1000 commits in all.
    side = [f"a{i:039x}" for i in range(1, side_count + 1)]
    line = [f"b{i:039x}" for i in range(1, main_count + 1)]
    merge = "9" * 39 + "e"
    chain = []
    for i, sha in enumerate(side):
        parent = CURRENT if i == 0 else side[i - 1]
        files = [".github/workflows/nightly.yml"] if i == surface_at_side else [f"ios/S{i}.swift"]
        chain.append(commit(sha, [parent], files, "austinywang"))
    for i, sha in enumerate(line):
        parent = CURRENT if i == 0 else (merge if i == main_count // 2 else line[i - 1])
        chain.append(commit(sha, [parent], [f"Sources/M{i}.swift"]))
    merged = commit(merge, [line[main_count // 2 - 1], side[-1]], [])
    if surface_at_side is not None:
        # The merge keeps the side branch's surface change (the harness tree
        # of a merge is otherwise its first parent's).
        merged["tree"] = {".github/workflows/nightly.yml": side[surface_at_side]}
    chain.append(merged)
    chain.reverse()
    head = line[-1]
    return scenario(sha=head, sourceHead=head, onSource={head: "identical"},
                    runs=[gate_run(head_sha=head)], commits=chain + [commit(CURRENT, [], [])],
                    activity=[{"before": CURRENT, "after": head, "actor": {"login": "teamleaderleo"}}],
                    commitPulls={}, surface=SURFACE)


def test_a_range_over_1000_commits_with_a_merge_promotes() -> None:
    # 304de7d...ad551c0 on 2026-10-20 was 1782 commits, 1549 from one merge:
    # no smaller step existed, so a cap on the range blocked every nightly.
    out = run(merged_long_range(232, 1549))
    assert out["decision"]["action"] == "promote", out["decision"]
    assert out["calls"]["comparePages"] >= 18  # every page of the commit list was read


def test_a_surface_change_on_a_late_page_of_a_long_range_still_asks_for_an_ack() -> None:
    # The surface commit sits past the 1000th commit of the list.
    out = run(merged_long_range(232, 1549, surface_at_side=5))
    assert out["decision"]["action"] == "needs-ack", out["decision"]
    assert out["decision"]["surfaceFiles"] == [".github/workflows/nightly.yml"]
    assert "austinywang" in out["decision"]["landers"], out["decision"]


def test_a_long_surface_range_reads_its_commits_in_parallel_within_a_bound() -> None:
    # Run 39410930509: read one by one, 1782 commits ran the decide job past
    # its 10-minute limit. Reads overlap, but never more than 16 at once.
    out = run(merged_long_range(232, 1549, surface_at_side=5))
    assert out["decision"]["action"] == "needs-ack", out["decision"]
    assert out["calls"]["commitReads"] >= 1782, out["calls"]
    assert 8 <= out["calls"]["commitMaxInFlight"] <= 16, out["calls"]


def test_a_transient_github_server_error_is_retried() -> None:
    case = scenario(rangeFiles=[{"filename": ".github/workflows/nightly.yml"}], pullsErrors=2)
    case["commits"][0]["files"] = [{"filename": ".github/workflows/nightly.yml"}]
    out = run(case)
    assert out["decision"]["action"] == "needs-ack", out["decision"]
    assert "teamleaderleo" in out["decision"]["landers"], out["decision"]


def test_a_lasting_github_server_error_still_fails() -> None:
    case = scenario(rangeFiles=[{"filename": ".github/workflows/nightly.yml"}], pullsErrors=99)
    case["commits"][0]["files"] = [{"filename": ".github/workflows/nightly.yml"}]
    try:
        out = run(case)
    except RuntimeError as error:
        assert "Server Error" in str(error), error
    else:
        raise AssertionError(f"a lasting 500 must not decide: {out['decision']}")


def test_a_client_error_is_not_retried() -> None:
    case = scenario(rangeFiles=[{"filename": ".github/workflows/nightly.yml"}], pullsErrors=1, pullsErrorStatus=404)
    case["commits"][0]["files"] = [{"filename": ".github/workflows/nightly.yml"}]
    try:
        out = run(case)
    except RuntimeError as error:
        assert "Server Error" in str(error), error
    else:
        raise AssertionError(f"a 404 must not be retried: {out['decision']}")


def test_a_long_range_the_compare_api_lists_short_is_refused() -> None:
    # total_commits says more than the pages hold: fail closed.
    case = merged_long_range(232, 1549)
    case["totalCommitsOverride"] = 1782 + 40
    out = run(case)
    assert out["decision"]["action"] == "refuse", out["decision"]
    assert "did not list them all" in out["decision"]["reason"]


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


def with_waiter(waiter_sha: str, waiter_current: str, green: bool = True, status: str = "waiting") -> dict:
    """SHA is requested while run 900 waits for the approval of waiter_sha.

    NEWER is the feat-cmux-next tip one commit after SHA; MID is older than SHA.
    """
    case = scenario(newest=True, sourceHead=NEWER, onSource={SHA: "ahead"},
                    runs=[gate_run(), gate_run(id=8, head_sha=NEWER)],
                    jobs={7: GREEN, 8: GREEN if green else [],
                          900: [{"name": f"nightly-next promotion {waiter_sha} from {waiter_current}", "status": status}]},
                    dispatchRuns=[{"id": 900, "status": "waiting" if status == "waiting" else "in_progress"}])
    case["commits"].insert(0, commit(NEWER, [SHA], ["Sources/Newer.swift"]))
    return case


def test_a_live_waiter_for_a_newer_commit_keeps_waiting() -> None:
    out = run(with_waiter(NEWER, CURRENT))
    assert out["decision"]["action"] == "superseded", out["decision"]
    assert out["decision"]["sha"] == NEWER
    assert out["newest"]["requested"] == SHA and not out["newest"]["scanFailed"]


def test_a_live_waiter_for_the_same_commit_keeps_waiting() -> None:
    out = run(with_waiter(SHA, CURRENT))
    assert out["decision"]["action"] == "superseded", out["decision"]
    assert out["decision"]["sha"] == SHA


def test_a_request_never_decides_less_than_a_dead_waiter() -> None:
    # The waiter was decided against an older nightly-next, so its approval
    # would be refused; this request decides the waiter's newer commit.
    out = run(with_waiter(NEWER, "9" * 40))
    assert out["decision"]["action"] == "promote", out["decision"]
    assert out["decision"]["sha"] == NEWER
    assert out["newest"]["requested"] == SHA and not out["newest"]["scanFailed"]


def test_a_newer_request_replaces_an_older_waiter() -> None:
    out = run(with_waiter(MID, CURRENT))
    assert out["decision"]["action"] == "promote", out["decision"]
    assert out["decision"]["sha"] == SHA


def test_a_refused_waiter_commit_falls_back_to_the_request() -> None:
    out = run(with_waiter(NEWER, "9" * 40, green=False))
    assert out["decision"]["action"] == "promote", out["decision"]
    assert out["decision"]["sha"] == SHA


def test_an_approved_live_waiter_is_not_cancelled() -> None:
    out = run(with_waiter(MID, CURRENT, status="in_progress"))
    assert out["decision"]["action"] == "superseded", out["decision"]
    assert out["decision"]["sha"] == MID


def test_a_refused_newest_waiter_falls_back_to_the_next_newest() -> None:
    # Run 900 waits for NEWER (no green compile any more), run 901 for SHA2
    # between SHA and NEWER; both were decided against an older nightly-next.
    sha2 = "e" * 40
    case = with_waiter(NEWER, "9" * 40, green=False)
    case["commits"][0]["parents"] = [{"sha": sha2}]
    case["commits"].insert(1, commit(sha2, [SHA], ["Sources/Two.swift"]))
    case["runs"].append(gate_run(id=9, head_sha=sha2))
    case["jobs"]["9"] = GREEN
    case["jobs"]["901"] = [{"name": f"nightly-next promotion {sha2} from {'9' * 40}", "status": "waiting"}]
    case["dispatchRuns"].append({"id": 901, "status": "waiting"})
    out = run(case)
    assert out["decision"]["action"] == "promote", out["decision"]
    assert out["decision"]["sha"] == sha2


def test_an_uncomparable_waiter_is_skipped_not_a_scan_failure() -> None:
    gone = "7" * 40
    case = with_waiter(gone, "9" * 40)
    out = run(case)
    assert not out["newest"]["scanFailed"], out
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == SHA


def test_a_finished_waiter_does_not_count() -> None:
    out = run(with_waiter(NEWER, CURRENT, status="completed"))
    assert out["decision"]["action"] == "promote", out["decision"]
    assert out["decision"]["sha"] == SHA


def test_an_unreadable_queue_decides_the_request_and_cancels_nothing() -> None:
    case = with_waiter(NEWER, CURRENT)
    case["dispatchThrows"] = True
    out = run(case)
    assert out["newest"]["scanFailed"] is True
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == SHA


EVICTED = "Canceling since a higher priority waiting request for nightly-next-promote exists"


def with_evicted(evicted_sha: str, *, message: str = EVICTED, age_hours: float = 1, green: bool = True,
                 title: str | None = None) -> dict:
    """SHA is requested after GitHub cancelled run 950's request for evicted_sha in the promote queue."""
    from datetime import datetime, timedelta, timezone

    created = (datetime.now(timezone.utc) - timedelta(hours=age_hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    case = scenario(newest=True, sourceHead=NEWER, onSource={SHA: "ahead"},
                    runs=[gate_run(), gate_run(id=8, head_sha=NEWER)],
                    jobs={7: GREEN, 8: GREEN if green else [],
                          950: [{"id": 9500, "name": "promote-nightly-next", "status": "completed", "conclusion": "cancelled"}]},
                    dispatchRuns=[{"id": 950, "status": "cancelled", "created_at": created,
                                   "display_title": title or f"Promote nightly-next to {evicted_sha}"}],
                    annotations={"9500": [{"annotation_level": "failure", "message": message}]})
    case["commits"].insert(0, commit(NEWER, [SHA], ["Sources/Newer.swift"]))
    return case


def test_a_newer_request_evicted_from_the_queue_is_decided() -> None:
    out = run(with_evicted(NEWER))
    assert out["decision"]["action"] == "promote", out["decision"]
    assert out["decision"]["sha"] == NEWER
    assert out["newest"]["requested"] == SHA and not out["newest"]["scanFailed"]


def test_an_older_evicted_request_does_not_replace_the_request() -> None:
    out = run(with_evicted(MID))
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == SHA, out["decision"]


def test_an_evicted_request_without_a_green_compile_falls_back_to_the_request() -> None:
    out = run(with_evicted(NEWER, green=False))
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == SHA, out["decision"]


def test_a_request_a_person_cancelled_is_not_recovered() -> None:
    out = run(with_evicted(NEWER, message="The run was canceled by @lawrencecchen."))
    assert out["decision"]["sha"] == SHA, out["decision"]


def test_an_evicted_request_older_than_a_day_is_not_recovered() -> None:
    out = run(with_evicted(NEWER, age_hours=25))
    assert out["decision"]["sha"] == SHA, out["decision"]


def test_a_dry_run_request_is_not_recovered() -> None:
    out = run(with_evicted(NEWER, title=f"Promote nightly-next to dry-run:{NEWER}"))
    assert out["decision"]["sha"] == SHA, out["decision"]


def test_the_request_title_names_its_commit() -> None:
    import yaml

    data = yaml.safe_load(WORKFLOW)
    # guard.evictedPromotions() parses this title (REQUEST_TITLE).
    assert data["run-name"] == "${{ inputs.promote_nightly_next_sha && format('Promote nightly-next to {0}', inputs.promote_nightly_next_sha) || '' }}"
    assert data["jobs"]["promote-nightly-next"]["permissions"]["checks"] == "read"


def test_workflow_runs_the_guard_from_main_and_gates_the_move() -> None:
    assert "environment: nightly-next-promote" in WORKFLOW
    assert "&& 'release-surface-ack' || ''" in WORKFLOW
    assert "requested.startsWith('dry-run:')" in WORKFLOW
    assert "ref: ${{ github.sha }}" in WORKFLOW
    assert "if: steps.decide.outputs.action == 'promote' && steps.decide.outputs.dry_run != 'true'" in WORKFLOW
    assert "if: needs.await-release-surface-ack.result == 'success' && needs.promote-nightly-next.outputs.action == 'needs-ack' && needs.promote-nightly-next.outputs.dry_run != 'true'" in WORKFLOW
    assert "group: nightly-next-promote-ack-${{ github.run_id }}" in WORKFLOW
    assert "guard.decideNewest({" in WORKFLOW


def test_only_the_wait_for_the_approval_is_cancellable() -> None:
    import yaml

    jobs = yaml.safe_load(WORKFLOW)["jobs"]
    wait, move, decide_job = jobs["await-release-surface-ack"], jobs["promote-nightly-next-acked"], jobs["promote-nightly-next"]
    # The waiter: one shared cancel-in-progress group (a per-run group when the
    # scan failed), the approval environment only for needs-ack, no secrets.
    assert wait["concurrency"]["cancel-in-progress"] is True
    assert wait["concurrency"]["group"].startswith("nightly-next-promote-ack${{")
    assert "scan_failed == 'true' && format('-wait-{0}', github.run_id)" in wait["concurrency"]["group"]
    assert "'release-surface-ack'" in wait["environment"] and "action == 'needs-ack'" in wait["environment"]
    assert wait["permissions"] == {}
    assert "secrets." not in json.dumps(wait)
    # guard.pendingPromotions() parses this name.
    assert wait["name"] == "nightly-next promotion ${{ needs.promote-nightly-next.outputs.sha }} from ${{ needs.promote-nightly-next.outputs.current || 'none' }}"
    # The writers are never in a cancelling group.
    assert move["concurrency"]["cancel-in-progress"] is False and "github.run_id" in move["concurrency"]["group"]
    assert decide_job["concurrency"] == {"group": "nightly-next-promote", "cancel-in-progress": False}
    assert move["needs"] == ["promote-nightly-next", "await-release-surface-ack"]
    assert move["environment"] == "nightly-next-promote"
    assert "requireNonLander: policy.require_non_lander_approver" in WORKFLOW


def test_workflow_executes_the_release_surface_approval_gate() -> None:
    import yaml

    jobs = yaml.safe_load(WORKFLOW)["jobs"]
    decide = jobs["promote-nightly-next"]
    steps = {step["name"]: step for step in decide["steps"]}
    direct = "steps.decide.outputs.action == 'promote' && steps.decide.outputs.dry_run != 'true'"
    assert steps["Mint release App token"]["if"] == direct
    assert steps["Move nightly-next"]["if"] == direct

    wait = jobs["await-release-surface-ack"]
    assert wait["if"] == (
        "(needs.promote-nightly-next.outputs.action == 'needs-ack' || "
        "needs.promote-nightly-next.outputs.action == 'promote') && "
        "needs.promote-nightly-next.outputs.dry_run != 'true'"
    )
    acknowledged = jobs["promote-nightly-next-acked"]
    assert acknowledged["if"] == (
        "needs.await-release-surface-ack.result == 'success' && "
        "needs.promote-nightly-next.outputs.action == 'needs-ack' && "
        "needs.promote-nightly-next.outputs.dry_run != 'true'"
    )


def main() -> None:
    tests = [value for name, value in globals().items() if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS: nightly-next promote guard ({len(tests)} cases)")


if __name__ == "__main__":
    main()
