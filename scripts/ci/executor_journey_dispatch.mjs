// The daily Executor journey dispatcher (.github/workflows/executor-journey-nightly-dispatch.yml):
// start feat-cmux-next's executor-journey.yml (executor.sh runs a real job in a cmux Cloud staging
// machine), wait for its verdict, and keep one issue open while it is red. The API retries are the
// Cloud chat proof dispatcher's. Tested by tests/executor_journey_dispatch.test.mjs.
import { RETRY_DELAYS_MS, retried } from './cloud_chat_proof_dispatch.mjs';

export { RETRY_DELAYS_MS };
export const WORKFLOW = 'executor-journey.yml';
export const SOURCE = 'feat-cmux-next';

// The journey's one job times out at 20 min on feat-cmux-next; plus room for its runner to queue.
export const JOURNEY_WORST_CASE_MINUTES = 20;
export const WAIT_MINUTES = JOURNEY_WORST_CASE_MINUTES + 20;
export const FIND_TRIES = 60;
export const FIND_INTERVAL_MS = 10_000;
export const POLL_INTERVAL_MS = 30_000;
export const ISSUE_TITLE = 'Executor journey red: executor.sh in a cmux Cloud staging machine';

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function findRun({ github, owner, repo, requestId, since, sleep, log }) {
  const { data } = await retried(
    () => github.rest.actions.listWorkflowRuns({
      owner, repo, workflow_id: WORKFLOW, branch: SOURCE, event: 'workflow_dispatch',
      created: `>=${since}`, per_page: 50,
    }),
    { sleep, log, what: 'listing the journey runs' },
  );
  // The run-name ends with request_id (executor-journey.yml run-name), so this finds its own run.
  return data.workflow_runs.find((r) => (r.display_title || '').endsWith(` ${requestId}`));
}

// Dispatches the journey and waits for it. Returns { run, error, green, verdict, where }.
export async function prove({ github, owner, repo, requestId, sleep = wait, now = () => Date.now(), log = () => {} }) {
  const since = new Date(now() - 60_000).toISOString();
  let run, error;
  try {
    const inputs = { request_id: requestId };
    // A dispatch whose answer was lost may still have started the run: look before dispatching again.
    await retried(async () => {
      if (await findRun({ github, owner, repo, requestId, since, sleep, log })) return;
      // Fully qualified: a tag named feat-cmux-next must never be picked.
      await github.rest.actions.createWorkflowDispatch({
        owner, repo, workflow_id: WORKFLOW, ref: `refs/heads/${SOURCE}`, inputs,
      });
    }, { sleep, log, what: 'dispatching the journey' });
    for (let tries = 0; !run && tries < FIND_TRIES; tries++) {
      await sleep(FIND_INTERVAL_MS);
      run = await findRun({ github, owner, repo, requestId, since, sleep, log });
    }
    const deadline = now() + WAIT_MINUTES * 60_000;
    while (run && run.status !== 'completed' && now() < deadline) {
      await sleep(POLL_INTERVAL_MS);
      const id = run.id;
      run = (await retried(
        () => github.rest.actions.getWorkflowRun({ owner, repo, run_id: id }),
        { sleep, log, what: `reading run ${id}` },
      )).data;
    }
  } catch (e) {
    error = e;
  }
  const green = !error && run?.status === 'completed' && run.conclusion === 'success';
  const where = run ? run.html_url : `(no run found for ${requestId})`;
  const verdict = error
    ? `not read (${error.message})`
    : !run ? 'never started'
    : run.status !== 'completed' ? `still running past ${WAIT_MINUTES} min`
    : run.conclusion;
  return { run, error, green, verdict, where };
}

// Closes the open issue on green; opens it, or comments on it, otherwise.
export async function report({ github, owner, repo, green, verdict, where, sleep = wait, log = () => {} }) {
  const call = (what, fn) => retried(fn, { sleep, log, what });
  const { data: found } = await call('searching for the open issue', () => github.rest.search.issuesAndPullRequests({
    q: `repo:${owner}/${repo} is:issue is:open in:title "${ISSUE_TITLE}"`, per_page: 5,
  }));
  const open = found.items.find((issue) => issue.title === ISSUE_TITLE);
  if (green) {
    if (open) {
      await call('commenting on the issue', () => github.rest.issues.createComment({ owner, repo, issue_number: open.number, body: `Green again: ${where}` }));
      await call('closing the issue', () => github.rest.issues.update({ owner, repo, issue_number: open.number, state: 'closed' }));
    }
    return { open, action: open ? 'closed' : 'none' };
  }
  const body = [
    `The daily Executor journey (install executor.sh in a fresh cmux Cloud staging machine, add DeepWiki's MCP server as an app, \`executor execute\` a job that calls one of its tools) is ${verdict}: ${where}`,
    '',
    'The run summary names the phase that failed and its error text. This closes on the next green run.',
  ].join('\n');
  if (open) {
    await call('commenting on the issue', () => github.rest.issues.createComment({ owner, repo, issue_number: open.number, body }));
    return { open, action: 'commented' };
  }
  await call('opening the issue', () => github.rest.issues.create({ owner, repo, title: ISSUE_TITLE, body }));
  return { open, action: 'opened' };
}
