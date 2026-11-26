// The daily Cloud chat proof dispatcher (.github/workflows/cloud-chat-proof-nightly-dispatch.yml):
// start feat-cmux-next's cloud-chat-proof.yml for one agent, wait for its verdict, and keep one
// issue per agent open while it is red. Tested by tests/cloud_chat_proof_dispatch.test.mjs.

export const WORKFLOW = 'cloud-chat-proof.yml';
export const SOURCE = 'feat-cmux-next';

// The proof's longest path, from its job timeouts on feat-cmux-next: resolve 10, pick-proof-runner 5,
// proof-staging 120, proof-prod 120 (it needs staging), verdict 5. A run still inside that is not red.
export const PROOF_WORST_CASE_MINUTES = 10 + 5 + 120 + 120 + 5;
// Plus room for the runners to queue between jobs.
export const WAIT_MINUTES = PROOF_WORST_CASE_MINUTES + 20;
export const FIND_TRIES = 60;
export const FIND_INTERVAL_MS = 10_000;
export const POLL_INTERVAL_MS = 60_000;
// Waits between tries of one API call; a call still failing after the last is the verdict.
export const RETRY_DELAYS_MS = [15_000, 60_000, 180_000];

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A server error, a rate limit or a dropped connection passes; anything else is a real answer.
export function transient(error) {
  const status = error?.status;
  if (status === undefined || status === null) return true;
  if (status >= 500 || status === 429) return true;
  const message = String(error?.message || '');
  return status === 403 && /rate limit|abuse/i.test(message);
}

export async function retried(call, { sleep = wait, log = () => {}, what = 'call' }) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await call();
    } catch (error) {
      if (attempt >= RETRY_DELAYS_MS.length || !transient(error)) throw error;
      log(`${what} failed (${error.message}); trying again in ${RETRY_DELAYS_MS[attempt] / 1000} s`);
      await sleep(RETRY_DELAYS_MS[attempt]);
    }
  }
}

// The cmux-bot App's installation token lives one hour (GitHub's limit) and shares its hourly quota with
// every workflow that mints it, but the proof can run 260 min. Run 45425358279 lost its claude verdict to
// "Bad credentials" at minute 60, and its codex job to the installation's rate limit. A client made with
// rotating() moves to the fallback (the job's github.token, valid for the whole job, with its own quota)
// on a 401 or a rate limit and stays there.
export function rotating(primary, fallback, log = () => {}) {
  let current = primary;
  return async (fn) => {
    try {
      return await fn(current);
    } catch (error) {
      const status = error?.status;
      const limited = status === 429 || (status === 403 && /rate limit/i.test(String(error?.message || '')));
      if (!fallback || current === fallback || !(status === 401 || limited)) throw error;
      log(`cmux-bot token ${status === 401 ? 'expired' : 'rate limited'} (${error.message}); using github.token from here`);
      current = fallback;
      return await fn(current);
    }
  };
}

async function findRun({ api, owner, repo, requestId, since, sleep, log }) {
  const { data } = await retried(
    () => api((github) => github.rest.actions.listWorkflowRuns({
      owner, repo, workflow_id: WORKFLOW, branch: SOURCE, event: 'workflow_dispatch',
      created: `>=${since}`, per_page: 50,
    })),
    { sleep, log, what: 'listing the proof runs' },
  );
  // The run-name ends with request_id (cloud-chat-proof.yml run-name), so this finds its own run.
  return data.workflow_runs.find((r) => (r.display_title || '').endsWith(` ${requestId}`));
}

// Dispatches the proof and waits for it. Returns { run, error, green, verdict, where }.
export async function prove({ github, fallback, owner, repo, agent, requestId, sleep = wait, now = () => Date.now(), log = () => {}, api = rotating(github, fallback, log) }) {
  const since = new Date(now() - 60_000).toISOString();
  let run, error;
  try {
    const inputs = { build: 'published', agent, from_folder: 'true', request_id: requestId };
    // A dispatch whose answer was lost may still have started the run: look before dispatching again.
    await retried(async () => {
      if (await findRun({ api, owner, repo, requestId, since, sleep, log })) return;
      // Fully qualified: a tag named feat-cmux-next must never be picked.
      await api((github) => github.rest.actions.createWorkflowDispatch({
        owner, repo, workflow_id: WORKFLOW, ref: `refs/heads/${SOURCE}`, inputs,
      }));
    }, { sleep, log, what: 'dispatching the proof' });
    for (let tries = 0; !run && tries < FIND_TRIES; tries++) {
      await sleep(FIND_INTERVAL_MS);
      run = await findRun({ api, owner, repo, requestId, since, sleep, log });
    }
    const deadline = now() + WAIT_MINUTES * 60_000;
    while (run && run.status !== 'completed' && now() < deadline) {
      await sleep(POLL_INTERVAL_MS);
      const id = run.id;
      run = (await retried(
        () => api((github) => github.rest.actions.getWorkflowRun({ owner, repo, run_id: id })),
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
  return { run, error, green, verdict, where, api };
}

export function issueTitle(agent) {
  return `Cloud chat proof red: ${agent} from a folder on the published NEXT DEV app`;
}

// Closes the agent's open issue on green; opens it, or comments on it, otherwise.
// Pass prove()'s api so a token that expired during the wait is not used again.
export async function report({ github, fallback, owner, repo, agent, green, verdict, where, sleep = wait, log = () => {}, api = rotating(github, fallback, log) }) {
  const title = issueTitle(agent);
  const call = (what, fn) => retried(() => api((github) => fn(github)), { sleep, log, what });
  const { data: found } = await call('searching for the open issue', (github) => github.rest.search.issuesAndPullRequests({
    q: `repo:${owner}/${repo} is:issue is:open in:title "${title}"`, per_page: 5,
  }));
  const open = found.items.find((issue) => issue.title === title);
  if (green) {
    if (open) {
      await call('commenting on the issue', (github) => github.rest.issues.createComment({ owner, repo, issue_number: open.number, body: `Green again: ${where}` }));
      await call('closing the issue', (github) => github.rest.issues.update({ owner, repo, issue_number: open.number, state: 'closed' }));
    }
    return { open, action: open ? 'closed' : 'none' };
  }
  const body = [
    `The daily Cloud chat proof (${agent}, published NEXT DEV app, chat started from a plain folder, staging then production) is ${verdict}: ${where}`,
    '',
    'The run summary names the step that failed. This closes on the next green run of the same agent.',
  ].join('\n');
  if (open) {
    await call('commenting on the issue', (github) => github.rest.issues.createComment({ owner, repo, issue_number: open.number, body }));
    return { open, action: 'commented' };
  }
  await call('opening the issue', (github) => github.rest.issues.create({ owner, repo, title, body }));
  return { open, action: 'opened' };
}
