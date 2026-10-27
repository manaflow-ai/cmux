// The plan of .github/workflows/cmux-next-tip-swift-suite-dispatch.yml: whether this tick asks
// cmux-next.yml for a tip_swift_suite run on the feat-cmux-next tip.
//
// A feat-cmux-next push skips swift-test, so the tip suite is how a Swift test red on the base
// shows: its "cmux-next swift test" check run lands on the tip commit, and
// scripts/ci/base_red_excuse.py reads it. One run at a time, at most one per 30-minute tick, and
// only when Swift changed:
//   - skip while a tip suite run is in flight, or when one was created in the last MIN_GAP_MS
//     (25 min, not 30: a late cron tick must not push the next run back a whole tick);
//   - the tip already has a swift-test verdict (pass or fail): skip;
//   - the tip has runs but no verdict (the runner was lost, "Set up runner" failed, the run was
//     cancelled, no test step ran): retry, at most MAX_ATTEMPTS runs per tip in all;
//   - a new tip: find the last green (the newest tip suite run whose swift-test passed; with none
//     within MAX_JOB_READS job reads, the newest red). None, or not an ancestor of the tip:
//     dispatch. Else "route": the workflow diffs green..tip and asks
//     cmux-next's own router (scripts/ci/cmux_next_route.py on the tip) whether that diff reaches
//     swift-test, and dispatches only then.
// A verdict is read from the swift-test job, never from the run's overall conclusion.
'use strict';

const SOURCE = 'feat-cmux-next';
const WORKFLOW = 'cmux-next.yml';
const TITLE = 'cmux-next tip Swift suite · ';
const SWIFT_JOB = 'cmux-next swift test';
// Steps whose failure is a verdict on the code: the package build and the test steps.
const VERDICT_STEP = /^(Build package and tests|Run |Test |Script tests)/;
const MIN_GAP_MS = 25 * 60 * 1000;
const MAX_ATTEMPTS = 3;
// Job listings per tick, so a long red streak cannot spend the token's budget.
const MAX_JOB_READS = 10;

function isTipSuite(run) {
  return (run.display_title || '') === TITLE + run.head_sha;
}

// 'pass', 'fail', null (no verdict), or undefined (not read: the tick's budget is spent).
// `reads` counts job listings.
async function verdict({ github, owner, repo, run, reads }) {
  if (run.status !== 'completed') return null;
  // Even a successful run is read: a run whose swift-test job was skipped tested nothing.
  if (reads.count >= MAX_JOB_READS) return undefined;
  reads.count += 1;
  const { data } = await github.rest.actions.listJobsForWorkflowRun({
    owner, repo, run_id: run.id, filter: 'latest', per_page: 100,
  });
  const job = (data.jobs || []).find((j) => j.name === SWIFT_JOB);
  if (!job || job.status !== 'completed') return null;
  if (job.conclusion === 'success') return 'pass';
  if (job.conclusion !== 'failure') return null;
  const failed = (job.steps || []).filter((s) => s.conclusion === 'failure');
  return failed.some((s) => VERDICT_STEP.test(s.name)) ? 'fail' : null;
}

async function plan({ github, context, now = Date.now() }) {
  const { owner, repo } = context.repo;
  const { data: ref } = await github.rest.git.getRef({ owner, repo, ref: `heads/${SOURCE}` });
  const tip = ref.object.sha;
  const { data } = await github.rest.actions.listWorkflowRuns({
    owner, repo, workflow_id: WORKFLOW, event: 'workflow_dispatch', branch: SOURCE, per_page: 100,
  });
  const runs = (data.workflow_runs || []).filter(isTipSuite)
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
  const out = (action, reason, base = '') => ({ action, reason, tip, base });

  const going = runs.find((r) => r.status !== 'completed');
  if (going) return out('skip', `run ${going.id} on ${going.head_sha} is in flight`);
  const recent = runs.find((r) => now - Date.parse(r.created_at) < MIN_GAP_MS);
  if (recent) return out('skip', `run ${recent.id} started less than 25 minutes ago`);

  const reads = { count: 0 };
  const onTip = runs.filter((r) => r.head_sha === tip);
  if (onTip.length) {
    for (const run of onTip) {
      const v = await verdict({ github, owner, repo, run, reads });
      if (v) return out('skip', `the tip has a swift-test verdict (${v}) in run ${run.id}`);
    }
    if (onTip.length >= MAX_ATTEMPTS) {
      return out('skip', `${onTip.length} runs on the tip gave no swift-test verdict; not retrying`);
    }
    return out('dispatch', `retry: ${onTip.length} run(s) on the tip gave no swift-test verdict`);
  }

  // The base to diff from: the last green, else (a red streak, or one longer than the read
  // budget) the newest run with a red verdict, so a red base is not re-run on a change that
  // does not reach swift-test. No run with a verdict at all: dispatch.
  let green = '';
  let red = '';
  for (const run of runs) {
    const v = await verdict({ github, owner, repo, run, reads });
    if (v === undefined) break;
    if (v === 'pass') { green = run.head_sha; break; }
    if (v === 'fail' && !red) red = run.head_sha;
  }
  const base = green || red;
  if (!base) return out('dispatch', 'no tip suite run with a swift-test verdict found');
  const { data: cmp } = await github.rest.repos.compareCommitsWithBasehead({
    owner, repo, basehead: `${base}...${tip}`, per_page: 1,
  });
  const what = green ? 'the last green' : 'the last red';
  if (cmp.status === 'identical') return out('skip', `the tip is ${what} commit`, base);
  if (cmp.status !== 'ahead') return out('dispatch', `${what} ${base} is not an ancestor of the tip`, base);
  return out('route', `diff ${what} ${base} with the tip`, base);
}

async function dispatch({ github, context }) {
  const { owner, repo } = context.repo;
  await github.rest.actions.createWorkflowDispatch({
    owner, repo, workflow_id: WORKFLOW,
    // Fully qualified: a tag named feat-cmux-next must never be picked.
    ref: `refs/heads/${SOURCE}`,
    inputs: { tip_swift_suite: 'true' },
  });
}

module.exports = { plan, dispatch, verdict, MIN_GAP_MS, MAX_ATTEMPTS, SWIFT_JOB };
