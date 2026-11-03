import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { returnBrief, MAX_ARTIFACT_READ_AGE_MS } from '../src/agent-session/acpmux/session-info/returnBriefModel.ts';

const COMMIT = 'a'.repeat(40);
const REVISION = 'b'.repeat(40);
const DIGEST = 'sha256:' + 'c'.repeat(64);
const base = () => ({
  sessionId: 'session-17', turnId: 'turn-4', repository: 'example/atlas', commit: COMMIT,
  now: 1200, viewerScope: 'team-1', observed: { changedPaths: ['src/retry.ts', 'src/retry.ts', 'test/retry.ts'], previews: 1 },
  risks: ['Retry under network loss awaits a live run'],
});
const run = () => ({ ownerRead: true, sessionId: 'session-17', turnId: 'turn-4', commit: COMMIT,
  kind: 'tests', tests: { passed: 12, failed: 0, skipped: 1 }, state: 'succeeded', githubRunId: 47 });
const artifact = () => ({ ownerRead: true, checkedAt: 1180, sessionId: 'session-17', turnId: 'turn-4',
  id: 'artifact-1', path: 'reports/retry.md', revision: REVISION, digest: DIGEST, readbackDigest: DIGEST,
  scope: 'team-1', accessible: true, expiresAt: 200000 });
const approval = () => ({ ownerRead: true, sessionId: 'session-17', turnId: 'turn-4', authority: 'acpmux', state: 'approved' });
const item = (input, id) => returnBrief(input).items.find(x => x.id === id);

test('a complete owner-backed return retains direct review links and exactly reported tests', () => {
  const input = { ...base(), run: run(), approval: approval(), artifact: artifact(), pullRequest: { ownerRead: true, repository: 'example/atlas', number: 7, headCommit: COMMIT, state: 'open' } };
  const view = returnBrief(input);
  assert.equal(view.source, 'example/atlas @ aaaaaaaaaaaa');
  assert.equal(item(input, 'changes').level, 'observed');
  assert.match(item(input, 'changes').detail, /2 path/);
  assert.deepEqual([item(input, 'checks').level, item(input, 'artifact').level, item(input, 'approvals').level], ['verified', 'verified', 'verified']);
  assert.match(item(input, 'checks').detail, /12 tests passed, 1 skipped/);
  assert.match(item(input, 'checks').href, /\/actions\/runs\/47$/);
  assert.equal(item(input, 'artifact').action, 'artifact');
  assert.match(item(input, 'pull-request').detail, /awaits human review/);
  assert.deepEqual(view.risks, ['Retry under network loss awaits a live run']);
});

test('assistant claims and transcript-only previews cannot mint receipts, approvals or a saved file', () => {
  const input = { ...base(), observed: { changedPaths: [], previews: 2 } };
  assert.equal(item(input, 'checks').level, 'unverified');
  assert.equal(item(input, 'artifact').level, 'unverified');
  assert.equal(item(input, 'approvals').level, 'unverified');
  assert.equal(item(input, 'preview').level, 'observed');
  assert.equal(item(input, 'changes').action, undefined);
});

test('cross-turn and changed-commit job receipts never qualify as exact-head proof', () => {
  for (const patch of [{ turnId: 'turn-3' }, { commit: 'f'.repeat(40) }, { sessionId: 'other' }])
    assert.equal(item({ ...base(), run: { ...run(), ...patch } }, 'checks').level, 'stale');
  assert.equal(item({ ...base(), run: { ...run(), ownerRead: false } }, 'checks').level, 'unverified');
});

test('a successful command with zero executed tests cannot become a green test claim', () => {
  assert.equal(item({ ...base(), run: { ...run(), tests: undefined } }, 'checks').level, 'unverified');
  assert.equal(item({ ...base(), run: { ...run(), tests: { passed: 0, failed: 0, skipped: 7 } } }, 'checks').level, 'unverified');
  assert.equal(item({ ...base(), run: { ...run(), tests: { passed: 2, failed: 1, skipped: 0 } } }, 'checks').level, 'unverified');
  assert.match(item({ ...base(), run: { ...run(), kind: 'build' } }, 'checks').detail, /tests separately unverified/);
});

test('failed, cancelled and outcome-unknown jobs retain their real disposition', () => {
  assert.equal(item({ ...base(), run: { ...run(), state: 'failed' } }, 'checks').level, 'failed');
  assert.equal(item({ ...base(), run: { ...run(), state: 'cancelled' } }, 'checks').level, 'failed');
  const unknown = item({ ...base(), run: { ...run(), state: 'outcome_unknown' } }, 'checks');
  assert.equal(unknown.level, 'unknown');
  assert.match(unknown.detail, /reconcile/);
});

test('wrong team, expired retention, old owner read and changed digest refuse readback', () => {
  assert.equal(item({ ...base(), artifact: { ...artifact(), scope: 'team-2' } }, 'artifact').level, 'inaccessible');
  assert.equal(item({ ...base(), artifact: { ...artifact(), accessible: false } }, 'artifact').action, undefined);
  assert.equal(item({ ...base(), artifact: { ...artifact(), expiresAt: 1200 } }, 'artifact').level, 'expired');
  assert.equal(item({ ...base(), now: 1180 + MAX_ARTIFACT_READ_AGE_MS + 1, artifact: artifact() }, 'artifact').level, 'stale');
  assert.equal(item({ ...base(), artifact: { ...artifact(), checkedAt: 1201 } }, 'artifact').level, 'stale');
  assert.equal(item({ ...base(), artifact: { ...artifact(), readbackDigest: 'sha256:' + 'e'.repeat(64) } }, 'artifact').level, 'failed');
  assert.equal(item({ ...base(), artifact: { ...artifact(), readbackDigest: undefined } }, 'artifact').action, undefined);
  assert.equal(item({ ...base(), artifact: { ...artifact(), revision: 'latest' } }, 'artifact').level, 'stale');
});

test('pending, denied and wrong-turn approvals are explicit', () => {
  assert.equal(item({ ...base(), approval: { ...approval(), state: 'pending' } }, 'approvals').level, 'observed');
  assert.equal(item({ ...base(), approval: { ...approval(), state: 'denied' } }, 'approvals').level, 'failed');
  assert.equal(item({ ...base(), approval: { ...approval(), turnId: 'other' } }, 'approvals').level, 'unverified');
});

test('a mentioned PR, wrong repository and new PR head lack GitHub verification', () => {
  const pr = { ownerRead: true, repository: 'example/atlas', number: 7, headCommit: COMMIT, state: 'merged' };
  assert.equal(item({ ...base(), pullRequest: pr }, 'pull-request').level, 'verified');
  assert.equal(item({ ...base(), pullRequest: { ...pr, ownerRead: false } }, 'pull-request').level, 'stale');
  assert.equal(item({ ...base(), pullRequest: { ...pr, headCommit: REVISION } }, 'pull-request').level, 'stale');
  assert.equal(item({ ...base(), pullRequest: { ...pr, repository: 'other/atlas' } }, 'pull-request').href, undefined);
});

test('reopening means fresh authorization, digest and expiry checks against the original owner', () => {
  const input = { ...base(), artifact: artifact() };
  const reopened = JSON.parse(JSON.stringify(input));
  assert.equal(item(reopened, 'artifact').action, 'artifact');
  reopened.viewerScope = 'team-2';
  assert.equal(item(reopened, 'artifact').action, undefined);
  reopened.viewerScope = 'team-1';
  reopened.now = 1180 + MAX_ARTIFACT_READ_AGE_MS + 1;
  assert.equal(item(reopened, 'artifact').action, undefined);
  reopened.artifact.checkedAt = reopened.now;
  reopened.artifact.expiresAt = reopened.now - 1;
  assert.equal(item(reopened, 'artifact').action, undefined);
});


test('synthetic retained bytes survive scratch destruction and another process checks digest', async () => {
  const root = await mkdtemp(join(tmpdir(), 'return-brief-proof-'));
  const scratch = join(root, 'scratch');
  const store = join(root, 'owner');
  const file = join(store, 'result.md');
  const bytes = Buffer.from('# Retry proof\n12 executed passing tests\n');
  const digest = 'sha256:' + createHash('sha256').update(bytes).digest('hex');
  const independentRead = () => {
    const child = spawnSync(process.execPath, [
      '-e',
      'const fs=require("node:fs"); const c=require("node:crypto"); const b=fs.readFileSync(process.argv[1]); console.log("sha256:"+c.createHash("sha256").update(b).digest("hex"))',
      file,
    ], { encoding: 'utf8' });
    assert.equal(child.status, 0, child.stderr);
    return child.stdout.trim();
  };
  try {
    await mkdir(scratch);
    await mkdir(store);
    await writeFile(join(scratch, 'temporary-result.md'), bytes);
    await writeFile(file, await readFile(join(scratch, 'temporary-result.md')));
    await rm(scratch, { recursive: true });
    const ownerReceipt = { ...artifact(), digest, readbackDigest: independentRead() };
    assert.equal(item({ ...base(), artifact: ownerReceipt }, 'artifact').level, 'verified');
    assert.equal(item({ ...base(), viewerScope: 'wrong-team', artifact: ownerReceipt }, 'artifact').level, 'inaccessible');
    await writeFile(file, '# Tampered after publication\n');
    assert.equal(item({ ...base(), artifact: { ...ownerReceipt, readbackDigest: independentRead() } }, 'artifact').level, 'failed');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
