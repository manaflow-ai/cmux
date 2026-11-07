// The plan of .github/workflows/cmux-next-tip-swift-suite-dispatch.yml: whether this tick asks
// cmux-next.yml for a tip suite run on the feat-cmux-next tip, for each suite in SUITES.
//
// A feat-cmux-next push skips swift-test and daemon-test, so the tip suites are how a Swift or
// live-daemon test red on the base shows: their "cmux-next swift test" and "cmux-next daemon tests"
// jobs run on the tip, and scripts/ci/base_red_excuse.py reads them (it looks the runs up by name
// when base pushes crowd them out of its window). Per suite, one run at a time, at most one per
// 30-minute tick, and only when its tier changed:
//   - skip while a tip suite run is in flight, or when one was created in the last MIN_GAP_MS
//     (25 min, not 30: a late cron tick must not push the next run back a whole tick);
//   - the tip already has a verdict for the suite's job (pass or fail): skip;
//   - the tip has runs but no verdict (the runner was lost, "Set up runner" failed, the run was
//     cancelled, no test step ran): retry, at most MAX_ATTEMPTS runs per tip in all;
//   - a new tip: find the last green (the newest tip suite run whose job passed; with none
//     within MAX_JOB_READS job reads, the newest red). None, or not an ancestor of the tip:
//     dispatch. A suite with everyLandings dispatches once the tip is that many commits past it,
//     so the base keeps a fresh verdict whatever changed. Else "route": the workflow diffs
//     green..tip and asks cmux-next's own router (scripts/ci/cmux_next_route.py on the tip)
//     whether that diff reaches the suite's tier, and dispatches only then.
// A verdict is read from the suite's job, never from the run's overall conclusion.
//
// A run is a tip suite run by its name, `<title><tested sha>`. The daemon suite's tree may still be
// publishing when it starts; its same-tree run then tests the recorded sha after the tip has moved
// (cmux_next_tree_notify.py), so the tested commit is read from the name, not the run's head_sha.
'use strict';

const SOURCE = 'feat-cmux-next';
const WORKFLOW = 'cmux-next.yml';
const SUITES = {
  swift: { title: 'cmux-next tip Swift suite · ', job: 'cmux-next swift test', input: 'tip_swift_suite' },
  // Most landings reach the daemon tier, but a burst that does not still leaves base_red_excuse.py a
  // fresh base verdict to compare with every 20 landings.
  daemon: { title: 'cmux-next tip daemon suite · ', job: 'cmux-next daemon tests', input: 'tip_daemon_suite',
            everyLandings: 20, deferrable: true },
};
// Steps whose failure is a verdict on the code: the package build and the test steps.
const VERDICT_STEP = /^(Build package and tests|Run |Test |Script tests)/;
const MIN_GAP_MS = 25 * 60 * 1000;
const MAX_ATTEMPTS = 3;
// Job listings per tick, so a long red streak cannot spend the token's budget.
const MAX_JOB_READS = 10;
// A daemon suite run whose tree was still publishing ends with daemon-test skipped and leaves a tree
// wait marker; the publish then starts its same-tree run (named like it, so it reads as in flight).
// Until then the run is pending, not a no-verdict run to retry: a retry would start a second same-tree
// run of the same sha. A tree publishes within the hour; after DEFERRED_GRACE_MS it is a lost run.
const DEFERRED_GRACE_MS = 90 * 60 * 1000;
const SWIFT_JOB = SUITES.swift.job;

function suiteOf(name) {
  const suite = SUITES[name || 'swift'];
  if (!suite) throw new Error(`unknown tip suite ${name}`);
  return suite;
}

// The commit a tip suite run tests, from its name; '' when it is not one of the suite's runs.
function testedSha(suite, run) {
  const title = run.display_title || '';
  const sha = title.startsWith(suite.title) ? title.slice(suite.title.length) : '';
  return /^[0-9a-f]{40}$/.test(sha) ? sha : '';
}

// 'pass', 'fail', 'skipped' (the job was skipped: no verdict, but see DEFERRED_GRACE_MS), null (no
// verdict), or undefined (not read: the tick's budget is spent). Callers treat 'skipped' as no verdict.
// `reads` counts job listings.
async function verdict({ github, owner, repo, run, reads, suite = SUITES.swift }) {
  if (run.status !== 'completed') return null;
  // Even a successful run is read: a run whose suite job was skipped tested nothing.
  if (reads.count >= MAX_JOB_READS) return undefined;
  reads.count += 1;
  const { data } = await github.rest.actions.listJobsForWorkflowRun({
    owner, repo, run_id: run.id, filter: 'latest', per_page: 100,
  });
  const job = (data.jobs || []).find((j) => j.name === suite.job);
  if (!job || job.status !== 'completed') return null;
  if (job.conclusion === 'skipped') return 'skipped';
  if (job.conclusion === 'success') return 'pass';
  if (job.conclusion !== 'failure') return null;
  const failed = (job.steps || []).filter((s) => s.conclusion === 'failure');
  return failed.some((s) => VERDICT_STEP.test(s.name)) ? 'fail' : null;
}

async function plan({ github, context, now = Date.now(), suite: requested }) {
  const name = requested || 'swift';
  const suite = suiteOf(name);
  const { owner, repo } = context.repo;
  const { data: ref } = await github.rest.git.getRef({ owner, repo, ref: `heads/${SOURCE}` });
  const tip = ref.object.sha;
  const { data } = await github.rest.actions.listWorkflowRuns({
    owner, repo, workflow_id: WORKFLOW, event: 'workflow_dispatch', branch: SOURCE, per_page: 100,
  });
  const runs = (data.workflow_runs || []).filter((r) => testedSha(suite, r))
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
  const out = (action, reason, base = '') => ({ action, reason, tip, base, suite: name });

  const going = runs.find((r) => r.status !== 'completed');
  if (going) return out('skip', `run ${going.id} on ${testedSha(suite, going)} is in flight`);
  const recent = runs.find((r) => now - Date.parse(r.created_at) < MIN_GAP_MS);
  if (recent) return out('skip', `run ${recent.id} started less than 25 minutes ago`);

  const reads = { count: 0 };
  const onTip = runs.filter((r) => testedSha(suite, r) === tip);
  if (onTip.length) {
    for (const run of onTip) {
      const v = await verdict({ github, owner, repo, run, reads, suite });
      if (v === 'skipped' && suite.deferrable && now - Date.parse(run.created_at) < DEFERRED_GRACE_MS) {
        return out('skip', `run ${run.id} skipped ${suite.job} while its tree publishes; its same-tree run follows`);
      }
      if (v && v !== 'skipped') return out('skip', `the tip has a ${suite.job} verdict (${v}) in run ${run.id}`);
    }
    if (onTip.length >= MAX_ATTEMPTS) {
      return out('skip', `${onTip.length} runs on the tip gave no ${suite.job} verdict; not retrying`);
    }
    return out('dispatch', `retry: ${onTip.length} run(s) on the tip gave no ${suite.job} verdict`);
  }

  // The base to diff from: the last green, else (a red streak, or one longer than the read
  // budget) the newest run with a red verdict, so a red base is not re-run on a change that
  // does not reach the suite. No run with a verdict at all: dispatch.
  let green = '';
  let red = '';
  // The newest verdict of either kind: the everyLandings floor counts from it, so a red periodic run
  // after the last green does not make every later tick dispatch again.
  let latest = '';
  for (const run of runs) {
    const v = await verdict({ github, owner, repo, run, reads, suite });
    if (v === undefined) break;
    if (!latest && (v === 'pass' || v === 'fail')) latest = testedSha(suite, run);
    if (v === 'pass') { green = testedSha(suite, run); break; }
    // A deferred run of an older sha (its same-tree run may still come) is no verdict here.
    if (v === 'fail' && !red) red = testedSha(suite, run);
  }
  const base = green || red;
  if (!base) return out('dispatch', `no tip suite run with a ${suite.job} verdict found`);
  const { data: cmp } = await github.rest.repos.compareCommitsWithBasehead({
    owner, repo, basehead: `${base}...${tip}`, per_page: 1,
  });
  const what = green ? 'the last green' : 'the last red';
  if (cmp.status === 'identical') return out('skip', `the tip is ${what} commit`, base);
  if (cmp.status !== 'ahead') return out('dispatch', `${what} ${base} is not an ancestor of the tip`, base);
  if (suite.everyLandings) {
    let since = { sha: base, by: cmp.ahead_by };
    if (latest && latest !== base) {
      const { data: last } = await github.rest.repos.compareCommitsWithBasehead({
        owner, repo, basehead: `${latest}...${tip}`, per_page: 1,
      });
      if (last.status === 'identical') return out('skip', `the tip is the newest ${suite.job} verdict's commit`, base);
      // Not an ancestor (a force push): the floor counts from the green, as before.
      if (last.status === 'ahead') since = { sha: latest, by: last.ahead_by };
    }
    if (since.by >= suite.everyLandings) {
      return out('dispatch', `the tip is ${since.by} commits past the newest verdict ${since.sha}`, base);
    }
  }
  return out('route', `diff ${what} ${base} with the tip`, base);
}

async function dispatch({ github, context, suite: requested, core }) {
  const name = requested || 'swift';
  const suite = suiteOf(name);
  const { owner, repo } = context.repo;
  try {
    await github.rest.actions.createWorkflowDispatch({
      owner, repo, workflow_id: WORKFLOW,
      // Fully qualified: a tag named feat-cmux-next must never be picked.
      ref: `refs/heads/${SOURCE}`,
      inputs: { [suite.input]: 'true' },
    });
  } catch (error) {
    // The tip's cmux-next.yml does not take the input yet (it lands on feat-cmux-next separately):
    // a warning, not a red tick. The Swift suite's input is long there; its refusal stays an error.
    // GitHub answers an input the workflow does not declare with 422 `Unexpected inputs provided:
    // ["tip_daemon_suite"]`; any other 422 (a bad ref, a disabled workflow) is a real failure.
    if (name !== 'swift' && error.status === 422 && /Unexpected inputs provided/.test(error.message || '')
        && (error.message || '').includes(suite.input)) {
      if (core) core.warning(`feat-cmux-next's ${WORKFLOW} refused ${suite.input}: ${error.message}`);
      return false;
    }
    throw error;
  }
  return true;
}

module.exports = { plan, dispatch, verdict, testedSha, SUITES, MIN_GAP_MS, MAX_ATTEMPTS, DEFERRED_GRACE_MS, SWIFT_JOB };
