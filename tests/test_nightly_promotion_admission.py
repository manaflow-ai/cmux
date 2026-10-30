#!/usr/bin/env python3
"""Behavior of the nightly-next promote guard (scripts/ci/promote-nightly-next.mjs).

The guard runs from main in nightly.yml. Each case drives it against an
in-memory GitHub API (runs, jobs, refs, commits, pull requests, repository
activity, deployment approvals) and checks the decision the workflow acts on:

- G1: a SHA that is not on feat-cmux-next is refused.
- G2 (requireReleaseCompile, off by default since 2026-10-26): only a
  cmux-next.yml push run of this repository proves the Release compile; a
  same-named job in another workflow does not. The lookup retries while
  GitHub's index lags. Off, the promoted commit's own nightly build is the
  compile gate and a tip with no green Release compile is promoted itself.
  The G2 cases set scenario requireReleaseCompile.
- G3 and G4 run only with requireApproval (off by default since 2026-10-27:
  approval is retired); off, they are skipped and read nothing. scenario()
  sets requireApproval so the G3/G4 cases keep testing them.
- G3: a range that changes no release surface file is promoted; a range that
  changes one needs an approval.
- G4: the approval must come from someone who did not land the surface
  change (push actor, PR author or merger, commit author) and did not start
  the run; a missing push actor fails closed.
- Newest request wins (decideNewest): a newer request GitHub evicted from the
  promote queue in the last day is decided before this request's own commit;
  a person's cancel, an older or ungreen commit and a dry run are not. The
  retired release-surface-ack waiters are never read.
"""

from __future__ import annotations

import json
import os
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
const calls = { dispatchStatuses: [], runs: 0, jobs: 0, activityPages: 0, moves: 0, comparePages: 0, trees: 0, commitReads: 0, commitInFlight: 0, commitMaxInFlight: 0 };
const pullsListCommits = Symbol('listCommits');
const notices = [];
const actions = {
  // Only decideNewest() lists runs without paginating: the promotion requests on main.
  listWorkflowRuns: async (params) => {
    calls.dispatchStatuses.push(params.status);
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
      // A train commit's message and parents (readTrainCommit()) come from
      // scenario.gitCommits; any other commit has neither, so it is no train.
      getCommit: async ({ commit_sha }) => ({ data: { sha: commit_sha, tree: { sha: `T|${commit_sha}|` }, ...((scenario.gitCommits || {})[commit_sha] || {}) } }),
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
        if ((scenario.compareThrows || []).includes(basehead)) throw Object.assign(new Error('Bad Gateway'), { status: 502 });
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
      ...(scenario.requireReleaseCompile === undefined ? {} : { requireReleaseCompile: scenario.requireReleaseCompile }),
      ...(scenario.requireApproval === undefined ? {} : { requireApproval: scenario.requireApproval }),
    })).decision
  : await guard.decide({
      github, core, owner: 'manaflow-ai', repo: 'cmux', sha: scenario.sha,
      surfaceText: scenario.surface, sleep: async () => {},
      ...(scenario.requireReleaseCompile === undefined ? {} : { requireReleaseCompile: scenario.requireReleaseCompile }),
      ...(scenario.requireApproval === undefined ? {} : { requireApproval: scenario.requireApproval }),
      // G1' tree check: scenario.trainVerify is its answer, 'throw' a crash.
      verifyTrain: scenario.trainVerify === undefined ? null : async () => {
        if (scenario.trainVerify === 'throw') throw new Error('merge-tree crashed');
        return scenario.trainVerify;
      },
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
        "requireApproval": True,
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
    out = run(scenario(runs=[gate_run(path=".github/workflows/other.yml")], requireReleaseCompile=True))
    assert out["decision"]["action"] == "refuse"
    out = run(scenario(runs=[gate_run(head_repository={"full_name": "someone/cmux"})], requireReleaseCompile=True))
    assert out["decision"]["action"] == "refuse"


def test_tip_without_release_compile_promotes_newest_earlier_green_commit() -> None:
    case = scenario(runs=[gate_run(id=8, head_sha=MID)], jobs={"8": GREEN}, requireReleaseCompile=True)
    out = run(case)
    assert out["decision"]["action"] == "promote", out
    assert out["decision"]["sha"] == MID, out
    assert any("newest green source commit" in note for note in out["notices"]), out["notices"]


def test_fallback_ranks_green_commits_by_ancestry_not_run_time() -> None:
    older, newer, tip = "e" * 40, "d" * 40, "f" * 40
    commits = [
        {"sha": tip, "parents": [{"sha": newer}], "author": {"login": "lawrencecchen"}, "committer": {"login": "lawrencecchen"}, "files": []},
        {"sha": newer, "parents": [{"sha": older}], "author": {"login": "lawrencecchen"}, "committer": {"login": "lawrencecchen"}, "files": []},
        {"sha": older, "parents": [{"sha": CURRENT}], "author": {"login": "lawrencecchen"}, "committer": {"login": "lawrencecchen"}, "files": []},
        {"sha": CURRENT, "parents": [], "author": {"login": "lawrencecchen"}, "committer": {"login": "lawrencecchen"}, "files": []},
    ]
    case = scenario(sha=tip, sourceHead=tip, onSource={tip: "identical"}, commits=commits,
                    runs=[gate_run(id=8, head_sha=older, created_at="2026-10-24T01:00:00Z"), gate_run(id=9, head_sha=newer, created_at="2026-10-24T00:59:00Z")],
                    jobs={"8": GREEN, "9": GREEN}, requireReleaseCompile=True)
    out = run(case)
    assert out["decision"]["action"] == "promote", out
    assert out["decision"]["sha"] == newer, out


def test_fallback_never_promotes_a_descendant_of_an_older_requested_sha() -> None:
    requested, later = "d" * 40, "e" * 40
    commits = [
        {"sha": later, "parents": [{"sha": requested}], "author": {"login": "lawrencecchen"}, "committer": {"login": "lawrencecchen"}, "files": []},
        {"sha": requested, "parents": [{"sha": CURRENT}], "author": {"login": "lawrencecchen"}, "committer": {"login": "lawrencecchen"}, "files": []},
        {"sha": CURRENT, "parents": [], "author": {"login": "lawrencecchen"}, "committer": {"login": "lawrencecchen"}, "files": []},
    ]
    case = scenario(sha=requested, sourceHead=later, onSource={requested: "ahead"}, commits=commits,
                    runs=[gate_run(id=8, head_sha=later)], jobs={"8": GREEN}, requireReleaseCompile=True)
    out = run(case)
    assert out["decision"]["action"] == "refuse", out
    assert "no earlier green source commit" in out["decision"]["reason"], out


def test_admission_retries_while_the_index_lags() -> None:
    out = run(scenario(emptyRuns=2, requireReleaseCompile=True))
    assert out["decision"]["action"] == "promote"
    assert out["calls"]["runs"] == 3
    assert any("retry" in notice for notice in out["notices"])


def test_in_progress_success_is_not_admission() -> None:
    out = run(scenario(jobs={7: [dict(GREEN[0], status="in_progress")]}, requireReleaseCompile=True))
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


def test_a_diverged_range_is_refused() -> None:
    out = run(scenario(rangeStatus="diverged"))
    assert out["decision"]["action"] == "refuse", out["decision"]
    assert "is not an ancestor" in out["decision"]["reason"]


def test_a_request_nightly_next_already_contains_is_a_superseded_no_op() -> None:
    # 2026-10-27: requests for 00:30Z landings, dispatched at 04:41Z after a
    # newer commit was promoted, failed with "is not an ancestor". nightly-next
    # already containing the commit is a quiet success that moves nothing.
    out = run(scenario(rangeStatus="behind"))
    assert out["decision"]["action"] == "skip", out["decision"]
    assert "superseded by newer target" in out["decision"]["reason"], out["decision"]
    assert out["ack"]["ok"] and not out["ack"].get("move"), out["ack"]


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
    if not green:
        case["requireReleaseCompile"] = True
    return case


def test_a_newer_request_evicted_from_the_queue_is_decided() -> None:
    out = run(with_evicted(NEWER))
    assert out["decision"]["action"] == "promote", out["decision"]
    assert out["decision"]["sha"] == NEWER
    assert out["newest"]["requested"] == SHA and not out["newest"]["scanFailed"]
    # One scan, of cancelled requests only: the retired release-surface-ack
    # waiters (waiting, queued or in-progress runs) are never listed.
    assert out["calls"]["dispatchStatuses"] == ["cancelled"], out["calls"]


def test_a_waiting_ack_job_is_not_read() -> None:
    # Run 900 still waits on a release-surface-ack job for NEWER (the
    # 2026-10-16 runs on main that never timed out); nothing reads it.
    case = with_evicted(MID)
    case["jobs"]["900"] = [{"name": f"nightly-next promotion {NEWER} from {CURRENT}", "status": "waiting"}]
    case["dispatchRuns"].append({"id": 900, "status": "waiting"})
    out = run(case)
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == SHA, out["decision"]
    assert out["calls"]["dispatchStatuses"] == ["cancelled"], out["calls"]


def two_evicted() -> tuple[dict, str]:
    """Run 950 asked for NEWER and run 951 for SHA2, between SHA and NEWER; both were evicted."""
    sha2 = "e" * 40
    case = with_evicted(NEWER)
    case["commits"][0]["parents"] = [{"sha": sha2}]
    case["commits"].insert(1, commit(sha2, [SHA], ["Sources/Two.swift"]))
    case["runs"].append(gate_run(id=9, head_sha=sha2))
    case["jobs"]["9"] = GREEN
    case["jobs"]["951"] = [{"id": 9510, "name": "promote-nightly-next", "status": "completed", "conclusion": "cancelled"}]
    case["annotations"]["9510"] = [{"annotation_level": "failure", "message": EVICTED}]
    case["dispatchRuns"].append(dict(case["dispatchRuns"][0], id=951, display_title=f"Promote nightly-next to {sha2}"))
    return case, sha2


def test_a_refused_newest_evicted_request_falls_back_to_the_next_newest() -> None:
    # feat-cmux-next is at SHA2 again (NEWER was dropped), so G1 refuses NEWER.
    case, sha2 = two_evicted()
    case["sourceHead"] = sha2
    out = run(case)
    assert out["decision"]["action"] == "promote", out["decision"]
    assert out["decision"]["sha"] == sha2
    assert any(notice.startswith(f"{NEWER} is refused") for notice in out["notices"]), out["notices"]


def test_an_evicted_request_that_cannot_be_ordered_is_a_scan_failure() -> None:
    case, sha2 = two_evicted()
    case["compareThrows"] = [f"{NEWER}...{sha2}"]
    out = run(case)
    assert out["newest"]["scanFailed"] is True, out
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == SHA, out["decision"]


def diverged_evicted() -> dict:
    """NEWER branches off MID, so neither SHA nor NEWER contains the other; feat-cmux-next's tip merges both."""
    tip = "f" * 40
    case = with_evicted(NEWER)
    case["commits"][0]["parents"] = [{"sha": MID}]
    case["commits"].insert(0, commit(tip, [NEWER, SHA], []))
    case["sourceHead"] = tip
    return case


def test_a_diverged_evicted_request_is_decided_when_the_request_is_refused() -> None:
    # nightly-next is not an ancestor of SHA, so SHA is refused; NEWER is promoted.
    case = diverged_evicted()
    case["rangeStatus"] = "diverged"
    out = run(case)
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == NEWER, out["decision"]
    assert out["newest"]["requested"] == SHA and not out["newest"]["scanFailed"]
    assert any("which diverges from it" in notice for notice in out["notices"]), out["notices"]


def test_a_diverged_evicted_request_waits_while_the_request_is_admitted() -> None:
    out = run(diverged_evicted())
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == SHA, out["decision"]
    assert out["notices"] == [], out["notices"]


def test_an_uncomparable_evicted_request_is_skipped_not_a_scan_failure() -> None:
    out = run(with_evicted("7" * 40))
    assert not out["newest"]["scanFailed"], out
    assert any("cannot be compared" in notice for notice in out["notices"]), out["notices"]
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == SHA


def test_an_unreadable_eviction_list_decides_the_request_alone() -> None:
    case = with_evicted(NEWER)
    case["dispatchThrows"] = True
    out = run(case)
    assert not out["newest"]["scanFailed"], out
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == SHA
    assert any("cancelled in the promote queue" in notice for notice in out["notices"]), out["notices"]


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
    run_name = data["run-name"]
    assert run_name.startswith("${{ inputs.promote_nightly_next_sha && format('Promote nightly-next to {0}', inputs.promote_nightly_next_sha)")
    assert "github.event_name == 'schedule'" in run_name
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


# Main's copy also pins the Linux runner labels of the nightly jobs here
# (test_non_macos_nightly_next_orchestration_uses_the_trusted_fast_check_fallback).
# feat-cmux-next routes them through vars.LINUX_RUNNER instead, and
# tests/test_ci_nightly_off_blacksmith.py owns its runner rules.


def test_only_the_wait_for_the_approval_is_cancellable() -> None:
    import yaml

    jobs = yaml.safe_load(WORKFLOW)["jobs"]
    wait, move, decide_job = jobs["await-release-surface-ack"], jobs["promote-nightly-next-acked"], jobs["promote-nightly-next"]
    # The waiter: one shared non-cancelling group (a per-run group when the
    # scan failed), the approval environment only for needs-ack, no secrets.
    assert wait["concurrency"]["cancel-in-progress"] is False
    assert wait["concurrency"]["group"].startswith("nightly-next-promote-ack${{")
    assert "scan_failed == 'true' && format('-wait-{0}', github.run_id)" in wait["concurrency"]["group"]
    assert "'release-surface-ack'" in wait["environment"] and "action == 'needs-ack'" in wait["environment"]
    assert wait["permissions"] == {}
    assert "secrets." not in json.dumps(wait)
    # The writers are never in a cancelling group.
    assert move["concurrency"]["cancel-in-progress"] is False and "github.run_id" in move["concurrency"]["group"]
    assert decide_job["concurrency"] == {"group": "nightly-next-promote", "cancel-in-progress": False}
    assert move["needs"] == ["promote-nightly-next", "await-release-surface-ack"]
    assert move["environment"] == "nightly-next-promote"
    assert "requireNonLander: policy.require_non_lander_approver" in WORKFLOW


# ------------------------------------------------------------ train commits (G1'/G2')

TRAIN = "e" * 40
TRAIN_GATE = [{"name": "nightly-next train Release compile", "status": "completed", "conclusion": "success"}]


def train_run(**overrides) -> dict:
    run = {
        "id": 9, "head_sha": TRAIN, "head_branch": "nightly-train/123/1", "event": "workflow_dispatch",
        "path": ".github/workflows/nightly-next-train.yml", "head_repository": {"full_name": "manaflow-ai/cmux"},
    }
    run.update(overrides)
    return run


def train_case(**overrides) -> dict:
    """TRAIN = nightly-next train commit: parents CURRENT (nightly-next) and
    SHA (a feat-cmux-next commit), trailer `Nightly-Train: v1`."""
    case = scenario(sha=TRAIN, runs=[train_run()], jobs={"9": TRAIN_GATE},
                    trainVerify={"ok": True, "reason": "tree is the tip minus 0 revert(s)"})
    case["commits"].insert(0, {"sha": TRAIN, "parents": [{"sha": CURRENT}, {"sha": SHA}],
                               "author": {"login": "github-actions[bot]"}, "committer": {"login": "github-actions[bot]"},
                               "files": []})
    case["gitCommits"] = {TRAIN: {"message": "nightly-next train: x\n\nNightly-Train: v1\n",
                                  "parents": [{"sha": CURRENT}, {"sha": SHA}]}}
    case.update(overrides)
    case["jobs"] = {str(k): v for k, v in case["jobs"].items()}
    return case


def test_a_verified_green_train_commit_promotes() -> None:
    decision = run(train_case())["decision"]
    assert decision["action"] == "promote", decision


def test_a_train_commit_without_a_tree_verifier_is_refused() -> None:
    case = train_case()
    del case["trainVerify"]
    decision = run(case)["decision"]
    assert decision["action"] == "refuse" and "no train tree verifier" in decision["reason"], decision


def test_a_train_commit_whose_tree_is_not_its_reverts_is_refused() -> None:
    decision = run(train_case(trainVerify={"ok": False, "reason": "the tree is not the tip minus its reverts"}))["decision"]
    assert decision["action"] == "refuse" and "minus its reverts" in decision["reason"], decision


def test_a_crashed_tree_check_is_refused() -> None:
    decision = run(train_case(trainVerify="throw"))["decision"]
    assert decision["action"] == "refuse" and "failed to run" in decision["reason"], decision


def test_a_train_commit_needs_its_own_train_gate_run() -> None:
    # The cmux-next.yml push run of its second parent is not the train's gate.
    decision = run(train_case(runs=[gate_run(head_sha=TRAIN)], jobs={"7": GREEN}))["decision"]
    assert decision["action"] == "refuse" and "nightly-next-train.yml" in decision["reason"], decision
    decision = run(train_case(runs=[train_run(head_branch="feat-cmux-next")]))["decision"]
    assert decision["action"] == "refuse", decision
    decision = run(train_case(jobs={"9": [{**TRAIN_GATE[0], "conclusion": "failure"}]}))["decision"]
    assert decision["action"] == "refuse", decision


def test_a_train_commit_on_an_old_nightly_head_is_refused() -> None:
    case = train_case()
    case["gitCommits"][TRAIN]["parents"] = [{"sha": MID}, {"sha": SHA}]
    decision = run(case)["decision"]
    assert decision["action"] == "refuse" and "was made on" in decision["reason"], decision


def test_a_train_commit_a_later_nightly_head_contains_is_a_superseded_no_op() -> None:
    case = train_case()
    case["gitCommits"][TRAIN]["parents"] = [{"sha": MID}, {"sha": SHA}]
    case["rangeStatus"] = "behind"
    decision = run(case)["decision"]
    assert decision["action"] == "skip" and "superseded by newer target" in decision["reason"], decision


def test_a_train_commit_whose_tip_is_not_on_the_source_is_refused() -> None:
    # SHA is not reachable from the feat-cmux-next head MID ("behind").
    decision = run(train_case(sourceHead=MID))["decision"]
    assert decision["action"] == "refuse" and "second parent" in decision["reason"], decision


def test_a_plain_commit_still_takes_g1_and_g2() -> None:
    # No trailer: the train path is not taken even with a verifier present.
    case = scenario(trainVerify={"ok": True, "reason": "unused"})
    assert run(case)["decision"]["action"] == "promote"


def test_the_train_verifier_reads_the_script_verdict() -> None:
    script = r"""
const guard = await import(process.env.GUARD);
const answer = (status, stdout, stderr = '') => () => ({ status, stdout, stderr });
const ok = await guard.trainVerifier('x.py', { spawn: answer(0, 'log\n{"ok": true, "reason": "fine"}\n') })('a'.repeat(40));
const bad = await guard.trainVerifier('x.py', { spawn: answer(1, '{"ok": false, "reason": "differs"}') })('a'.repeat(40));
let crashed = null;
try { await guard.trainVerifier('x.py', { spawn: answer(1, '', 'Traceback') })('a'.repeat(40)); } catch (e) { crashed = e.message; }
console.log(JSON.stringify({ ok, bad, crashed }));
"""
    out = subprocess.run(["node", "--input-type=module", "-e", script], cwd=ROOT, capture_output=True, text=True,
                         env={**os.environ, "GUARD": str(GUARD)}, check=True)
    result = json.loads(out.stdout)
    assert result["ok"] == {"ok": True, "reason": "fine"}
    assert result["bad"] == {"ok": False, "reason": "differs"}
    assert result["crashed"] and "Traceback" in result["crashed"]


def test_both_promote_decisions_pass_the_train_verifier() -> None:
    assert WORKFLOW.count("verifyTrain: guard.trainVerifier(") == 2
    assert WORKFLOW.count("scripts/ci/nightly_next_train.py\n") >= 2


def test_by_default_a_tip_without_a_release_compile_is_promoted_itself() -> None:
    # 2026-10-26: the nightly build compiles the promoted commit and publishes
    # nothing when that fails, so promotion no longer waits for G2.
    case = scenario(runs=[gate_run(id=8, head_sha=MID)], jobs={"8": GREEN})
    out = run(case)
    assert out["decision"]["action"] == "promote", out
    assert out["decision"]["sha"] == SHA, out
    assert out["calls"]["runs"] == 0, out["calls"]
    out = run(scenario(runs=[], jobs={}))
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == SHA, out


def test_by_default_g1_still_refuses_a_commit_off_feat_cmux_next() -> None:
    out = run(scenario(onSource={SHA: "diverged"}, sourceHead="e" * 40, runs=[], jobs={}))
    assert out["decision"]["action"] == "refuse"
    assert "is not on feat-cmux-next" in out["decision"]["reason"]


def test_by_default_a_newer_evicted_request_without_a_compile_is_decided() -> None:
    case = with_evicted(NEWER)
    case["jobs"]["8"] = []
    out = run(case)
    assert out["decision"]["action"] == "promote" and out["decision"]["sha"] == NEWER, out["decision"]


def test_the_workflow_leaves_g2_off() -> None:
    assert "requireReleaseCompile" not in WORKFLOW



def test_by_default_g3_and_g4_are_skipped_and_read_nothing() -> None:
    # Approval is retired, so the release surface (G3) and lander (G4) reads
    # are skipped: no range listing, no tree, no per-commit read.
    case = surface_change(lander_rule=False)
    del case["requireApproval"]
    out = run(case)
    assert out["decision"]["action"] == "promote", out["decision"]
    assert out["decision"]["gates"] == {"G3": "skipped: no approval needed", "G4": "skipped: no approval needed"}
    assert out["decision"]["reason"] == "G3 and G4 skipped: no approval needed"
    assert out["calls"]["trees"] == 0 and out["calls"]["commitReads"] == 0, out["calls"]
    # G1 and the ancestry check (one compare each) still run.
    assert out["calls"]["comparePages"] == 2, out["calls"]
    assert out["ack"]["ok"] and out["ack"]["move"], out["ack"]
    assert "requireApproval" not in WORKFLOW.split("promote-nightly-next-acked:")[0]


def test_g3_and_g4_skip_still_refuses_what_g1_and_ancestry_refuse() -> None:
    case = scenario(onSource={SHA: "diverged"}, sourceHead="e" * 40)
    del case["requireApproval"]
    assert run(case)["decision"]["action"] == "refuse"
    case = scenario(rangeStatus="diverged")
    del case["requireApproval"]
    assert run(case)["decision"]["action"] == "refuse"
    case = scenario(surface=SURFACE.replace("@require_non_lander_approver off", "@require_non_lander_approver ON"))
    del case["requireApproval"]
    assert "unknown policy line" in run(case)["decision"]["reason"]


def test_g4_reads_grow_with_the_range_only_with_require_approval() -> None:
    # A 200-commit range that touches the surface: G4 reads every commit with
    # requireApproval and none without it.
    commits, activity, parent = [], [], CURRENT
    for i in range(200):
        sha = f"{i + 1:040x}"
        commits.append({"sha": sha, "parents": [{"sha": parent}], "author": {"login": "teamleaderleo"},
                        "committer": {"login": "web-flow"}, "files": [{"filename": ".github/workflows/nightly.yml" if i == 0 else "Sources/App.swift"}]})
        activity.append({"before": parent, "after": sha, "actor": {"login": "teamleaderleo"}})
        parent = sha
    commits.reverse()
    activity.reverse()
    commits.append({"sha": CURRENT, "parents": [], "author": {"login": "lawrencecchen"}, "committer": {"login": "lawrencecchen"}, "files": []})
    case = scenario(sha=parent, sourceHead=parent, onSource={parent: "identical"}, commits=commits, activity=activity, commitPulls={})
    approved = run(case)
    assert approved["decision"]["action"] == "needs-ack", approved["decision"]
    assert approved["calls"]["commitReads"] == 200, approved["calls"]
    del case["requireApproval"]
    skipped = run(case)
    assert skipped["decision"]["action"] == "promote", skipped["decision"]
    assert skipped["calls"]["commitReads"] == 0 and skipped["calls"]["trees"] == 0, skipped["calls"]


def main() -> None:
    tests = [value for name, value in globals().items() if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS: nightly-next promote guard ({len(tests)} cases)")


if __name__ == "__main__":
    main()
