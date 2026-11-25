// node --test tests/executor_journey_dispatch.test.mjs
// Runs the script step of .github/workflows/executor-journey-nightly-dispatch.yml against an
// in-memory GitHub and a fake clock: a slow green journey and one transient API error file nothing,
// a red one opens one issue (or comments on it), and the next green run closes it.
import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const workflowText = readFileSync(join(root, '.github/workflows/executor-journey-nightly-dispatch.yml'), 'utf8');

// The `script: |` block of the workflow's one github-script step.
function workflowScript() {
  const lines = workflowText.split('\n');
  const start = lines.findIndex((l) => /^\s+script: \|\s*$/.test(l));
  assert.ok(start >= 0, 'the workflow has a github-script step');
  const indent = lines[start].search(/\S/);
  const body = [];
  for (const line of lines.slice(start + 1)) {
    if (line.trim() && line.search(/\S/) <= indent) break;
    body.push(line);
  }
  return body.join('\n');
}

const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;

// A fake clock: every setTimeout fires at once and moves Date.now by its delay.
let clock;
const realSetTimeout = globalThis.setTimeout;
const realNow = Date.now;
beforeEach(() => {
  clock = Date.parse('2026-11-22T14:47:00Z');
  globalThis.setTimeout = (fn, ms = 0) => { clock += ms; queueMicrotask(fn); return 0; };
  Date.now = () => clock;
});
afterEach(() => {
  globalThis.setTimeout = realSetTimeout;
  Date.now = realNow;
});

function httpError(status, message = `HTTP ${status}`) {
  return Object.assign(new Error(message), { status });
}

// The proof run is created by the dispatch, takes `minutes` to finish, and ends in `conclusion`.
// `faults` maps a call name to the errors its next calls throw, in order.
function fakeGitHub({ minutes = 8, conclusion = 'success', openIssue = null, faults = {}, dispatchStartsRun = true } = {}) {
  const calls = { dispatch: 0, created: [], comments: [], closed: [] };
  let run = null;
  const fault = (name) => {
    const queue = faults[name];
    if (queue && queue.length) throw queue.shift();
  };
  const runView = () => {
    const done = clock >= run.startedAt + minutes * 60_000;
    return { ...run, status: done ? 'completed' : 'in_progress', conclusion: done ? conclusion : null };
  };
  const github = {
    rest: {
      actions: {
        async createWorkflowDispatch({ inputs }) {
          calls.dispatch++;
          if (dispatchStartsRun || calls.dispatch > 1) {
            run = run || {
              id: 7, html_url: 'https://github.com/o/r/actions/runs/7', startedAt: clock,
              display_title: `Executor journey (staging) ${inputs.request_id}`,
            };
          }
          fault('dispatch');
          return { data: {} };
        },
        async listWorkflowRuns() {
          fault('list');
          return { data: { workflow_runs: run ? [runView()] : [] } };
        },
        async getWorkflowRun() {
          fault('get');
          return { data: runView() };
        },
      },
      search: {
        async issuesAndPullRequests() {
          fault('search');
          return { data: { items: openIssue ? [openIssue] : [] } };
        },
      },
      issues: {
        async create({ title, body }) { calls.created.push({ title, body }); return { data: { number: 99 } }; },
        async createComment({ issue_number, body }) { calls.comments.push({ issue_number, body }); return { data: {} }; },
        async update({ issue_number, state }) { if (state === 'closed') calls.closed.push(issue_number); return { data: {} }; },
      },
    },
  };
  return { github, calls };
}

async function runStep(github) {
  const core = { notices: [], failed: null, info() {}, notice(m) { this.notices.push(m); }, setFailed(m) { this.failed = m; } };
  const context = { repo: { owner: 'o', repo: 'r' }, runId: 42 };
  const env = { ...process.env, GITHUB_RUN_ATTEMPT: '1', GITHUB_WORKSPACE: root };
  const fakeProcess = { ...process, env };
  await new AsyncFunction('github', 'context', 'core', 'process', workflowScript())(github, context, core, fakeProcess);
  return core;
}

const TITLE = 'Executor journey red: executor.sh in a cmux Cloud staging machine';

test('a green journey slower than its job timeout, inside the queue room, is green and files nothing', async () => {
  const { github, calls } = fakeGitHub({ minutes: 35 });
  const core = await runStep(github);
  assert.equal(core.failed, null, core.notices.join('\n'));
  assert.deepEqual(calls.created, []);
});

test('a journey still running past its worst case is red', async () => {
  const { github, calls } = fakeGitHub({ minutes: 120 });
  const core = await runStep(github);
  assert.match(core.failed, /still running past/);
  assert.equal(calls.created.length, 1);
});

test('a red journey opens one issue naming the run', async () => {
  const { github, calls } = fakeGitHub({ conclusion: 'failure' });
  const core = await runStep(github);
  assert.match(core.failed, /Executor journey failure/);
  assert.equal(calls.created.length, 1);
  assert.equal(calls.created[0].title, TITLE);
  assert.match(calls.created[0].body, /actions\/runs\/7/);
});

test('a red journey with the issue open comments on it instead of opening another', async () => {
  const { github, calls } = fakeGitHub({ conclusion: 'failure', openIssue: { number: 5, title: TITLE } });
  await runStep(github);
  assert.deepEqual(calls.created, []);
  assert.equal(calls.comments.length, 1);
  assert.equal(calls.comments[0].issue_number, 5);
});

test('one server error while reading the run does not file a red issue', async () => {
  const { github, calls } = fakeGitHub({ faults: { get: [httpError(502, 'Bad Gateway')] } });
  const core = await runStep(github);
  assert.equal(core.failed, null, core.notices.join('\n'));
  assert.deepEqual(calls.created, []);
});

test('a rate limit while finding the run does not file a red issue', async () => {
  const { github, calls } = fakeGitHub({ faults: { list: [httpError(403, 'API rate limit exceeded')] } });
  const core = await runStep(github);
  assert.equal(core.failed, null, core.notices.join('\n'));
  assert.deepEqual(calls.created, []);
});

test('a dispatch whose answer was lost is not dispatched twice', async () => {
  const { github, calls } = fakeGitHub({ faults: { dispatch: [httpError(504, 'Gateway Timeout')] } });
  const core = await runStep(github);
  assert.equal(core.failed, null, core.notices.join('\n'));
  assert.equal(calls.dispatch, 1);
});

test('a real error is red, after no retries', async () => {
  const { github, calls } = fakeGitHub({ faults: { get: [httpError(404, 'Not Found')] } });
  const core = await runStep(github);
  assert.match(core.failed, /not read \(Not Found\)/);
  assert.equal(calls.created.length, 1);
});

test('a green run closes the open issue', async () => {
  const { github, calls } = fakeGitHub({ openIssue: { number: 5, title: TITLE } });
  const core = await runStep(github);
  assert.equal(core.failed, null);
  assert.deepEqual(calls.closed, [5]);
});

test('the job timeout outlasts finding the run, the whole wait and the report', async () => {
  const journey = await import('../scripts/ci/executor_journey_dispatch.mjs');
  assert.equal(journey.ISSUE_TITLE, TITLE);
  const timeout = Number(/^\s+timeout-minutes: (\d+)\s*$/m.exec(workflowText)[1]);
  const retryMinutes = journey.RETRY_DELAYS_MS.reduce((a, b) => a + b, 0) / 60_000;
  const findMinutes = (journey.FIND_TRIES * journey.FIND_INTERVAL_MS) / 60_000;
  assert.ok(journey.WAIT_MINUTES >= journey.JOURNEY_WORST_CASE_MINUTES, 'the wait covers the journey job');
  assert.ok(timeout >= findMinutes + journey.WAIT_MINUTES + 3 * retryMinutes,
    `timeout-minutes ${timeout} < ${findMinutes} + ${journey.WAIT_MINUTES} + 3 x ${retryMinutes}`);
});
