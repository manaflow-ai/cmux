// Drives scripts/ci/gh_budget_wait.cjs against a fake octokit (run by tests/test_gh_budget_wait.py).
// 2026-11-20: cmux NEXT resource budget dispatcher run 44710255073 died on an octokit
// "HttpError: API rate limit exceeded for installation" in its github-script step.
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { install, classify } = require('../scripts/ci/gh_budget_wait.cjs');

function httpError(status, message, headers = {}) {
  const error = new Error(message);
  error.status = status;
  error.response = { status, headers };
  return error;
}

// A fake octokit: hook.wrap keeps the wrapper; request() runs it around `respond`.
function fakeGithub(failures) {
  const calls = [];
  let wrapper = null;
  const github = {
    hook: { wrap: (name, fn) => { assert.strictEqual(name, 'request'); wrapper = fn; } },
    async request(options) {
      const inner = async (opts) => {
        calls.push(`${opts.method} ${opts.url}`);
        const next = failures.shift();
        if (next) throw next;
        return { status: 200, data: { ok: true } };
      };
      return wrapper ? wrapper(inner, options) : inner(options);
    },
  };
  return { github, calls };
}

function fakeSpare(failures) {
  const calls = [];
  return {
    calls,
    async request(options) {
      calls.push(options);
      const next = failures.shift();
      if (next) throw next;
      return { status: 200, data: { spare: true } };
    },
  };
}

function harness(failures, env = {}, spare = undefined) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gh-budget-wait-js-'));
  const { github, calls } = fakeGithub(failures);
  const slept = [];
  const notes = { notice: [], error: [] };
  const core = { notice: (m) => notes.notice.push(m), error: (m) => notes.error.push(m) };
  install({
    github, core,
    env: { RUNNER_TEMP: tmp, ...env },
    sleep: async (ms) => { slept.push(ms / 1000); },
    now: () => 1_000_000,
    spare,
  });
  const waited = () => {
    const file = path.join(tmp, 'gh-budget-wait', 'waited');
    return fs.existsSync(file) ? Number(fs.readFileSync(file, 'utf8')) : 0;
  };
  return { github, calls, slept, notes, waited, cleanup: () => fs.rmSync(tmp, { recursive: true, force: true }) };
}

const req = { method: 'POST', url: '/repos/o/r/actions/workflows/w.yml/dispatches' };
const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test('classify', () => {
  assert.strictEqual(classify(httpError(403, 'API rate limit exceeded for installation ID 1')), 'rate');
  assert.strictEqual(classify(httpError(403, 'Forbidden', { 'x-ratelimit-remaining': '0' })), 'rate');
  assert.strictEqual(classify(httpError(429, 'Too Many Requests')), 'rate');
  assert.strictEqual(classify(httpError(500, 'Failed to run workflow dispatch')), 'server');
  assert.strictEqual(classify(httpError(403, 'Resource not accessible by integration')), null);
  assert.strictEqual(classify(httpError(404, 'Not Found')), null);
});

test('an installation-quota 403 waits for x-ratelimit-reset, then succeeds', async () => {
  const h = harness([httpError(403, 'API rate limit exceeded for installation ID 1',
    { 'x-ratelimit-remaining': '0', 'x-ratelimit-reset': String(1_000_000 + 120) })]);
  const result = await h.github.request(req);
  assert.strictEqual(result.status, 200);
  assert.deepStrictEqual(h.slept, [125]);
  assert.strictEqual(h.calls.length, 2);
  assert.strictEqual(h.waited(), 125);
  h.cleanup();
});

test('retry-after wins over the reset', async () => {
  const h = harness([httpError(403, 'You have exceeded a secondary rate limit', { 'retry-after': '30' })]);
  await h.github.request(req);
  assert.deepStrictEqual(h.slept, [31]);
  h.cleanup();
});

test('a refusal with no reset backs off 60, 120', async () => {
  const h = harness([httpError(403, 'API rate limit exceeded for installation'), httpError(429, 'Too Many Requests')]);
  await h.github.request(req);
  assert.deepStrictEqual(h.slept, [60, 120]);
  h.cleanup();
});

test('a reset past the cap fails at once, loud', async () => {
  const h = harness([httpError(403, 'API rate limit exceeded for installation',
    { 'x-ratelimit-remaining': '0', 'x-ratelimit-reset': String(1_000_000 + 3000) })], { GH_BUDGET_WAIT_MAX_SECONDS: '900' });
  await assert.rejects(h.github.request(req), /rate limit exceeded/);
  assert.deepStrictEqual(h.slept, []);
  assert.strictEqual(h.calls.length, 1);
  assert.match(h.notes.error[0], /past this job's 900s left to wait/);
  h.cleanup();
});

test('a 5xx backs off 10, 20, 40 and fails loud after its tries', async () => {
  const fails = Array.from({ length: 5 }, () => httpError(500, 'Failed to run workflow dispatch'));
  const h = harness(fails);
  await assert.rejects(h.github.request(req), /Failed to run workflow dispatch/);
  assert.deepStrictEqual(h.slept, [10, 20, 40]);
  assert.strictEqual(h.calls.length, 4);
  assert.match(h.notes.error[0], /server error 500 \(try 4 of 4\); failing/);
  h.cleanup();
});

test('the job total bounds every wait', async () => {
  const fails = Array.from({ length: 5 }, () => httpError(502, 'Bad Gateway'));
  const h = harness(fails, { GH_BUDGET_WAIT_MAX_SECONDS: '25' });
  await assert.rejects(h.github.request(req), /Bad Gateway/);
  assert.deepStrictEqual(h.slept, [10, 15]);
  assert.match(h.notes.error[0], /25s of waiting is spent/);
  h.cleanup();
});

const dry = () => httpError(403, 'API rate limit exceeded for installation ID 1',
  { 'x-ratelimit-remaining': '0', 'x-ratelimit-reset': String(1_000_000 + 600) });
const read = { method: 'GET', url: '/repos/{owner}/{repo}/git/ref/{ref}', owner: 'o', repo: 'r', ref: 'heads/x', request: { hook: 'first client' } };

test('a rate-limited GET is read on the spare token, with no wait', async () => {
  const spare = fakeSpare([]);
  const h = harness([dry()], {}, spare);
  const result = await h.github.request(read);
  assert.deepStrictEqual(result.data, { spare: true });
  assert.deepStrictEqual(h.slept, []);
  assert.strictEqual(h.calls.length, 1);
  assert.strictEqual(spare.calls.length, 1);
  assert.strictEqual(spare.calls[0].request, undefined, 'the first client\'s hook must not ride along');
  assert.strictEqual(spare.calls[0].ref, 'heads/x');
  h.cleanup();
});

test('a spare that is dry too falls back to the wait, once', async () => {
  const spare = fakeSpare([dry()]);
  const h = harness([dry(), dry()], {}, spare);
  const result = await h.github.request(read);
  assert.deepStrictEqual(result.data, { ok: true });
  assert.deepStrictEqual(h.slept, [605, 605]);
  assert.strictEqual(spare.calls.length, 1);
  h.cleanup();
});

test('a write never moves to the spare token', async () => {
  const spare = fakeSpare([]);
  const h = harness([dry()], {}, spare);
  await h.github.request(req);
  assert.strictEqual(spare.calls.length, 0);
  assert.deepStrictEqual(h.slept, [605]);
  h.cleanup();
});

test('a server error does not use the spare token', async () => {
  const spare = fakeSpare([]);
  const h = harness([httpError(502, 'Bad Gateway')], {}, spare);
  await h.github.request(read);
  assert.strictEqual(spare.calls.length, 0);
  assert.deepStrictEqual(h.slept, [10]);
  h.cleanup();
});

test('another failure is not retried', async () => {
  const h = harness([httpError(404, 'Not Found')]);
  await assert.rejects(h.github.request(req), /Not Found/);
  assert.deepStrictEqual(h.slept, []);
  assert.strictEqual(h.calls.length, 1);
  h.cleanup();
});

(async () => {
  for (const [name, fn] of tests) {
    await fn();
    console.log(`ok ${name}`);
  }
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
