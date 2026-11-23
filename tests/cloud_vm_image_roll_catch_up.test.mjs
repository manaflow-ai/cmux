// node --test tests/cloud_vm_image_roll_catch_up.test.mjs
// Runs the script step of .github/workflows/cloud-vm-image-roll-catch-up.yml against an in-memory GitHub and
// a fake cloud-machine channel: it dispatches a roll of the channel's build only when the image lock pins an
// older cmux-tui, no roll is pending, the switch is not off, and rolls since the publish have not kept failing.
import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const workflowText = readFileSync(join(root, '.github/workflows/cloud-vm-image-roll-catch-up.yml'), 'utf8');

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
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString('base64');

const PIN = 'a'.repeat(40);
const NEW = 'b'.repeat(40);
const PUBLISHED = 1795426728; // 2026-11-23T09:38:48Z

let channel;
let fetched;
const realFetch = globalThis.fetch;
beforeEach(() => {
  fetched = [];
  channel = { status: 200, payload: { channel: 'cloud-machine', purpose: 'cmux-cloud-machine-update', commit: NEW, published_at: PUBLISHED } };
  globalThis.fetch = async (url) => {
    fetched.push(String(url));
    return { ok: channel.status === 200, status: channel.status, async json() { return { payload: b64(channel.payload), schema: 1, signatures: [] }; } };
  };
});
afterEach(() => { globalThis.fetch = realFetch; });

// `pending` maps a run status to a run id; `compare` is the status of pin...commit; `recent` are completed
// dispatched rolls since the publish.
function fakeGitHub({ pending = {}, mode = 'live', pin = PIN, compare = 'ahead', recent = [] } = {}) {
  const calls = { dispatches: [], listed: [], compared: [], files: [] };
  const github = {
    rest: {
      actions: {
        async listWorkflowRuns(args) {
          calls.listed.push(args);
          if (args.status === 'completed') return { data: { total_count: recent.length, workflow_runs: recent } };
          const id = pending[args.status];
          return { data: { total_count: id ? 1 : 0, workflow_runs: id ? [{ id }] : [] } };
        },
        async createWorkflowDispatch(args) { calls.dispatches.push(args); return { data: {} }; },
      },
      repos: {
        async getContent({ path, ref }) {
          calls.files.push({ path, ref });
          const files = {
            'images/cmux-vm/auto-roll.json': { mode },
            'images/cmux-vm/inputs.lock.json': { programs: [{ name: 'cmux-tui-hook', version: 'x' }, { name: 'cmux-tui', version: pin }] },
          };
          return { data: { content: b64(files[path]) } };
        },
        async compareCommitsWithBasehead({ basehead }) { calls.compared.push(basehead); return { data: { status: compare } }; },
      },
    },
  };
  return { github, calls };
}

async function runStep(github) {
  const core = { notices: [], warnings: [], notice(m) { this.notices.push(m); }, warning(m) { this.warnings.push(m); }, info() {} };
  const context = { repo: { owner: 'o', repo: 'r' } };
  const fakeProcess = { ...process, env: { ...process.env, GH_BUDGET_WAIT_JS: '' } };
  await new AsyncFunction('github', 'context', 'core', 'process', workflowScript())(github, context, core, fakeProcess);
  return core;
}

test('a channel build newer than the pin dispatches its roll on feat-cmux-next', async () => {
  const { github, calls } = fakeGitHub();
  const core = await runStep(github);
  assert.deepEqual(calls.dispatches, [{ owner: 'o', repo: 'r', workflow_id: 'cloud-vm-image-roll.yml', ref: 'refs/heads/feat-cmux-next', inputs: { commit: NEW } }]);
  assert.deepEqual(fetched, ['https://files.cmux.com/cmux-tui/channels/cloud-machine.json']);
  assert.deepEqual(calls.compared, [`${PIN}...${NEW}`]);
  assert.ok(calls.files.every((f) => f.ref === 'refs/heads/feat-cmux-next'));
  const since = calls.listed.find((a) => a.status === 'completed');
  assert.equal(since.created, '>=2026-11-23T09:38:48Z');
  assert.equal(since.event, 'workflow_dispatch');
  assert.match(core.notices.join('\n'), /Dispatched a roll of cmux-tui bbbbbbbbbbbb/);
});

for (const status of ['queued', 'in_progress', 'waiting', 'pending', 'requested']) {
  test(`a roll already ${status} is left alone: a new dispatch would replace a waiting one`, async () => {
    const { github, calls } = fakeGitHub({ pending: { [status]: 9 } });
    const core = await runStep(github);
    assert.deepEqual(calls.dispatches, []);
    assert.deepEqual(fetched, []);
    assert.match(core.notices.join('\n'), new RegExp(`already ${status} \\(run 9\\)`));
  });
}

test('auto-roll.json off starts nothing (a dispatch would ignore off)', async () => {
  const { github, calls } = fakeGitHub({ mode: 'off' });
  await runStep(github);
  assert.deepEqual(calls.dispatches, []);
});

test('dry-run dispatches one roll per publish: the roll bakes and gates but never moves the pin', async () => {
  const first = fakeGitHub({ mode: 'dry-run' });
  await runStep(first.github);
  assert.equal(first.calls.dispatches.length, 1);
  const again = fakeGitHub({ mode: 'dry-run', recent: [{ id: 1, conclusion: 'success' }] });
  await runStep(again.github);
  assert.deepEqual(again.calls.dispatches, []);
});

test('a lock pin that is not a commit fails the step', async () => {
  const { github, calls } = fakeGitHub({ pin: 'v1.0' });
  await assert.rejects(runStep(github), /not a commit/);
  assert.deepEqual(calls.dispatches, []);
});

test('a channel without a publish time fails the step', async () => {
  channel.payload = { ...channel.payload, published_at: 'soon' };
  const { github, calls } = fakeGitHub();
  await assert.rejects(runStep(github), /published_at is not a time/);
  assert.deepEqual(calls.dispatches, []);
});

test('the pinned build is not rolled again', async () => {
  const { github, calls } = fakeGitHub({ pin: NEW });
  const core = await runStep(github);
  assert.deepEqual(calls.dispatches, []);
  assert.deepEqual(calls.compared, []);
  assert.match(core.notices.join('\n'), /already pins/);
});

for (const status of ['behind', 'identical']) {
  test(`a channel build ${status} the pin is not rolled`, async () => {
    const { github, calls } = fakeGitHub({ compare: status });
    await runStep(github);
    assert.deepEqual(calls.dispatches, []);
  });
}

test('two failed rolls since the publish stop the catch-up', async () => {
  const { github, calls } = fakeGitHub({ recent: [{ id: 1, conclusion: 'failure' }, { id: 2, conclusion: 'failure' }] });
  const core = await runStep(github);
  assert.deepEqual(calls.dispatches, []);
  assert.match(core.warnings.join('\n'), /2 rolls .* failed \(1, 2\)/);
});

test('one failed roll since the publish is retried', async () => {
  const { github, calls } = fakeGitHub({ recent: [{ id: 1, conclusion: 'failure' }] });
  await runStep(github);
  assert.equal(calls.dispatches.length, 1);
});

test('three rolls since the publish that left the pin behind stop the catch-up', async () => {
  const recent = [1, 2, 3].map((id) => ({ id, conclusion: 'success' }));
  const { github, calls } = fakeGitHub({ recent });
  const core = await runStep(github);
  assert.deepEqual(calls.dispatches, []);
  assert.match(core.warnings.join('\n'), /3 rolls ran since/);
});

test('an unreadable channel fails the step and dispatches nothing', async () => {
  channel.status = 503;
  const { github, calls } = fakeGitHub();
  await assert.rejects(runStep(github), /cloud-machine channel: HTTP 503/);
  assert.deepEqual(calls.dispatches, []);
});

test('a channel payload for another purpose or without a commit is refused', async () => {
  for (const payload of [
    { ...channel.payload, purpose: 'something-else' },
    { ...channel.payload, channel: 'nightly' },
    { ...channel.payload, commit: 'main' },
  ]) {
    channel.payload = payload;
    const { github, calls } = fakeGitHub();
    await assert.rejects(runStep(github), /unexpected payload/);
    assert.deepEqual(calls.dispatches, []);
  }
});
