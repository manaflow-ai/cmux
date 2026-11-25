'use strict';
// node --test tests/incident_report.test.cjs: scripts/ci/incident_report.cjs, the failure report that outlives an
// exhausted GitHub token (runs 45548650589 and 45551813915 died on "API rate limit exceeded for installation").
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const ir = require(path.join(__dirname, '..', 'scripts', 'ci', 'incident_report.cjs'));

const RESET = 1_800_000_000; // epoch seconds

function limited(reset = RESET) {
  const error = new Error('API rate limit exceeded for installation.');
  error.status = 403;
  error.response = { headers: { 'x-ratelimit-remaining': '0', 'x-ratelimit-reset': String(reset) } };
  return error;
}

function fakeCore() {
  const said = { notice: [], warning: [], error: [], summary: [] };
  const summary = {
    addHeading(text) { said.summary.push(text); return summary; },
    addRaw(text) { said.summary.push(text); return summary; },
    write: async () => {},
  };
  return { said, summary, notice: (m) => said.notice.push(m), warning: (m) => said.warning.push(m), error: (m) => said.error.push(m) };
}

// An octokit whose REST calls go through its request hook, as @octokit/core's do. HANDLER answers each request.
function fakeOctokit(name, handler, graphqlHandler) {
  const calls = [];
  let wrapped = null;
  const base = async (options) => handler(options);
  const request = (options) => {
    calls.push({ name, ...options });
    return wrapped ? wrapped(base, options) : base(options);
  };
  const route = (method, url) => (params = {}) => request({ method, url, ...params });
  const gql = async (query, vars) => {
    calls.push({ name, graphql: query.trim().split(/[ ({]/)[0], vars });
    return graphqlHandler(query, vars);
  };
  return {
    calls,
    request,
    graphql: graphqlHandler ? gql : undefined,
    hook: { wrap: (_name, fn) => { wrapped = fn; } },
    rest: {
      issues: {
        getLabel: route('GET', '/repos/{owner}/{repo}/labels/{name}'),
        createLabel: route('POST', '/repos/{owner}/{repo}/labels'),
        listForRepo: route('GET', '/repos/{owner}/{repo}/issues'),
        createComment: route('POST', '/repos/{owner}/{repo}/issues/{issue_number}/comments'),
        create: route('POST', '/repos/{owner}/{repo}/issues'),
        update: route('PATCH', '/repos/{owner}/{repo}/issues/{issue_number}'),
      },
    },
  };
}

const context = { repo: { owner: 'manaflow-ai', repo: 'cmux' } };

test('a request the job token is refused for its rate limit goes again on a spare token', async () => {
  const core = fakeCore();
  const github = fakeOctokit('job', () => { throw limited(); });
  const spare = fakeOctokit('cmux-bot', (o) => ({ status: 200, data: o.url === '/repos/{owner}/{repo}/issues' && o.method === 'GET' ? [] : { number: 7 } }));
  ir.arm(github, { core, getOctokit: () => spare, spares: [{ name: 'cmux-bot', token: 't1' }, { name: 'glaeda-route', token: '' }] });
  const out = await ir.upsertIncident({ github, core, context, label: 'nightly-next-failure', title: 'T', body: 'B', deadlineMs: 0 });
  assert.deepEqual(out, { number: 7, created: true });
  assert.ok(spare.calls.some((c) => c.method === 'POST' && c.url === '/repos/{owner}/{repo}/issues' && c.title === 'T'));
  assert.ok(!spare.calls.some((c) => c.headers && c.headers.authorization), 'the job token is never sent with the spare');
  assert.ok(core.said.notice.some((m) => m.includes('cmux-bot')));
});

test('an error that is not a rate limit is the caller\'s, unchanged', async () => {
  const core = fakeCore();
  const notFound = Object.assign(new Error('Not Found'), { status: 404, response: { headers: {} } });
  const github = fakeOctokit('job', () => { throw notFound; });
  const spare = fakeOctokit('cmux-bot', () => ({ status: 200, data: {} }));
  ir.arm(github, { core, getOctokit: () => spare, spares: ['t1'] });
  await assert.rejects(github.rest.issues.update({ issue_number: 1 }), (e) => e === notFound);
  assert.equal(spare.calls.length, 0);
});

test('with REST dry on every token, the report goes through GraphQL', async () => {
  const core = fakeCore();
  const ops = [];
  const graphql = (query, vars) => {
    ops.push(query.match(/(repository|addComment|createLabel|createIssue|closeIssue)/)[1]);
    if (query.includes('repository(')) return { repository: { id: 'R', label: { id: 'L' }, issues: { nodes: [] } } };
    if (query.includes('createIssue')) {
      assert.deepEqual(vars.l, ['L']);
      return { createIssue: { issue: { number: 99 } } };
    }
    throw new Error(`unexpected ${query}`);
  };
  const github = fakeOctokit('job', () => { throw limited(); }, graphql);
  const spare = fakeOctokit('cmux-bot', () => { throw limited(RESET - 100); });
  ir.arm(github, { core, getOctokit: () => spare, spares: ['t1'] });
  const out = await ir.upsertIncident({ github, core, context, label: 'nightly-next-failure', title: 'T', body: 'B', deadlineMs: 0 });
  assert.deepEqual(out, { number: 99, created: true });
  assert.deepEqual(ops, ['repository', 'createIssue']);
  assert.ok(core.said.notice.some((m) => m.includes('GraphQL')));
});

test('an open incident gets a comment through GraphQL', async () => {
  const core = fakeCore();
  const ops = [];
  const graphql = (query, vars) => {
    if (query.includes('repository(')) return { repository: { id: 'R', label: { id: 'L' }, issues: { nodes: [{ id: 'I', number: 5 }] } } };
    ops.push([query.includes('addComment') ? 'addComment' : 'other', vars.id, vars.body]);
    return {};
  };
  const github = fakeOctokit('job', () => { throw limited(); }, graphql);
  ir.arm(github, { core, getOctokit: () => null, spares: [] });
  const out = await ir.upsertIncident({ github, core, context, label: 'x', title: 'T', body: 'B', deadlineMs: 0 });
  assert.deepEqual(out, { number: 5, created: false });
  assert.deepEqual(ops, [['addComment', 'I', 'B']]);
});

test('every path dry: it waits for the earliest reset, then reports', async () => {
  const core = fakeCore();
  let dry = true;
  const github = fakeOctokit('job', (o) => {
    if (dry) throw limited(RESET);
    return { status: 200, data: o.method === 'GET' && o.url.endsWith('/issues') ? [{ number: 3 }] : {} };
  }, () => { throw limited(); });
  const spare = fakeOctokit('cmux-bot', () => { throw limited(RESET - 600); });
  ir.arm(github, { core, getOctokit: () => spare, spares: ['t1'] });
  const nowMs = (RESET - 900) * 1000;
  const slept = [];
  const out = await ir.upsertIncident({ github, core, context, label: 'x', title: 'T', body: 'B', deadlineMs: 3600_000,
    now: () => nowMs, sleep: async (ms) => { slept.push(ms); dry = false; } });
  assert.deepEqual(out, { number: 3, created: false });
  assert.deepEqual(slept, [(RESET - 600) * 1000 + 2000 - nowMs], 'the spare\'s earlier reset decides the wait');
});

test('past the deadline the report is an ::error annotation and a summary, and the step fails', async () => {
  const core = fakeCore();
  const github = fakeOctokit('job', () => { throw limited(); }, () => { throw limited(); });
  ir.arm(github, { core, getOctokit: () => null, spares: [] });
  await assert.rejects(ir.upsertIncident({ github, core, context, label: 'x', title: 'cmux NIGHTLY build is failing', body: 'run 1 failed', deadlineMs: 0 }));
  assert.equal(core.said.error.length, 1);
  assert.match(core.said.error[0], /cmux NIGHTLY build is failing[\s\S]*run 1 failed/);
  assert.ok(core.said.summary.some((s) => s.includes('run 1 failed')));
});

test('closeIncidents comments on and closes every open incident', async () => {
  const core = fakeCore();
  const github = fakeOctokit('job', (o) => ({ status: 200, data: o.method === 'GET' ? [{ number: 1 }, { number: 2 }] : {} }));
  ir.arm(github, { core, getOctokit: () => null, spares: [] });
  const closed = await ir.closeIncidents({ github, core, context, label: 'x', body: 'green again', deadlineMs: 0 });
  assert.deepEqual(closed, [1, 2]);
  assert.equal(github.calls.filter((c) => c.method === 'PATCH' && c.state === 'closed').length, 2);
});
