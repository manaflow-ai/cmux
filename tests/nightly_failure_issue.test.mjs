// node --test tests/nightly_failure_issue.test.mjs
// The classic failure incident under parallel main and rc push runs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { report, close, failuresIn, failureMarker } from '../scripts/ci/nightly_failure_issue.mjs';

const failureMarkerFor = (s) => failureMarker(s, 'main');

const sha = (c) => c.repeat(40);
const owner = 'o';
const repo = 'r';

function httpError(status) {
  return Object.assign(new Error(`HTTP ${status}`), { status });
}

// An in-memory GitHub: labels, issues with comments, and a commit graph.
// main is d unless a test moves it.
function fakeGitHub({ parents = {}, branches = { main: 'd'.repeat(40) }, labelExists = false, labelRace = false } = {}) {
  const issues = [];
  const labels = new Set(labelExists ? ['nightly-failure', 'rc-failure'] : []);
  const hooks = { afterComment: null, beforeList: null, hideFromList: () => false };
  const ancestors = (c) => {
    const seen = new Set();
    const stack = [c];
    while (stack.length) {
      const x = stack.pop();
      if (seen.has(x)) continue;
      seen.add(x);
      stack.push(...(parents[x] || []));
    }
    return seen;
  };
  const resolve = (ref) => branches[ref] || ref;
  const known = (c) => c in parents || Object.values(parents).some((p) => p.includes(c));
  const issue = (n) => issues.find((i) => i.number === n);
  const view = (i) => ({ number: i.number, body: i.body, state: i.state, state_reason: i.state_reason, labels: i.labels });
  const rest = {
    issues: {
      async getLabel({ name }) { if (!labels.has(name)) throw httpError(404); return { data: { name } }; },
      async createLabel({ name }) {
        if (labelRace) { labels.add(name); throw httpError(422); }
        if (labels.has(name)) throw httpError(422);
        labels.add(name);
        return { data: { name } };
      },
      async listForRepo({ labels: label, state }) {
        if (hooks.beforeList) await hooks.beforeList();
        const listed = issues.filter((i) => i.labels.includes(label) && (state === 'all' || i.state === state) && !hooks.hideFromList(i));
        return { data: listed.map(view) };
      },
      async create({ title, labels: ls, body }) {
        const i = { number: issues.length + 1, title, labels: ls, body, state: 'open', state_reason: null, comments: [] };
        issues.push(i);
        return { data: view(i) };
      },
      async get({ issue_number }) { return { data: view(issue(issue_number)) }; },
      async listComments({ issue_number }) { return { data: issue(issue_number).comments.map((body) => ({ body })) }; },
      async createComment({ issue_number, body }) {
        issue(issue_number).comments.push(body);
        if (hooks.afterComment) { const h = hooks.afterComment; hooks.afterComment = null; await h(issue_number, body); }
        return { data: {} };
      },
      async update({ issue_number, state, state_reason }) {
        const i = issue(issue_number);
        i.state = state;
        i.state_reason = state === 'closed' ? (state_reason || 'completed') : null;
        return { data: view(i) };
      },
    },
    git: {
      async listMatchingRefs({ ref }) {
        const prefix = ref.replace(/^heads\//, '');
        return { data: Object.keys(branches).filter((b) => b.startsWith(prefix)).map((b) => ({ ref: `refs/heads/${b}` })) };
      },
    },
    repos: {
      async compareCommitsWithBasehead({ basehead }) {
        const [base, head] = basehead.split('...').map(resolve);
        if (!known(base) || !known(head)) throw httpError(404);
        if (base === head) return { data: { status: 'identical' } };
        if (ancestors(head).has(base)) return { data: { status: 'ahead' } };
        if (ancestors(base).has(head)) return { data: { status: 'behind' } };
        return { data: { status: 'diverged' } };
      },
    },
  };
  rest.repos.getCommit = async ({ ref }) => { if (!known(ref)) throw httpError(422); return { data: { sha: ref } }; };
  const github = { rest, paginate: async (fn, args) => (await fn(args)).data };
  return { github, issues, labels, hooks };
}

// main: a <- b <- c <- d
const MAIN = { [sha('b')]: [sha('a')], [sha('c')]: [sha('b')], [sha('d')]: [sha('c')], [sha('a')]: [] };
const nightly = { owner, repo, channel: 'nightly', appName: 'cmux NIGHTLY', runUrl: 'https://run' };
const fail = (gh, c, ref = 'main', extra = {}) =>
  report({ github: gh, ...nightly, ...extra, ref, sha: c, body: `run failed on ${c} (${ref})` });
const publish = (gh, c, ref = 'main', extra = {}) => close({ github: gh, ...nightly, ...extra, ref, sha: c });
const open = (issues) => issues.filter((i) => i.state === 'open');

test('one incident per channel: a second failure comments, and the label is created once', async () => {
  const { github, issues, labels } = fakeGitHub({ parents: MAIN });
  await fail(github, sha('b'));
  await fail(github, sha('c'));
  assert.equal(issues.length, 1);
  assert.ok(labels.has('nightly-failure'));
  assert.deepEqual(failuresIn([issues[0].body, ...issues[0].comments]).map((f) => f.sha), [sha('b'), sha('c')]);
});

test('a 422 from a parallel label create is not a failure', async () => {
  const { github, issues } = fakeGitHub({ parents: MAIN, labelRace: true });
  await fail(github, sha('b'));
  assert.equal(open(issues).length, 1);
});

test("an older run's publication does not close a newer commit's incident", async () => {
  const { github, issues } = fakeGitHub({ parents: MAIN });
  await fail(github, sha('c'));
  assert.deepEqual(await publish(github, sha('b')), []);
  assert.equal(issues[0].state, 'open');
  assert.match(issues[0].comments.at(-1), /Still failing on c{40} \(main\)/);
  assert.deepEqual(await publish(github, sha('d')), [1]);
  assert.equal(issues[0].state, 'closed');
});

test('the incident closes only when every recorded failure is covered', async () => {
  const { github, issues } = fakeGitHub({ parents: MAIN });
  await fail(github, sha('b'));
  await fail(github, sha('d'));
  await publish(github, sha('c'));
  assert.equal(issues[0].state, 'open');
  await publish(github, sha('d'));
  assert.equal(issues[0].state, 'closed');
});

test('incidents opened before the markers are read from their prose', async () => {
  const { github, issues } = fakeGitHub({ parents: MAIN, labelExists: true });
  await github.rest.issues.create({ labels: ['nightly-failure'], body: `cmux NIGHTLY run https://x failed on ${sha('c')} (main) in: build.` });
  await publish(github, sha('b'));
  assert.equal(issues[0].state, 'open');
  await publish(github, sha('c'));
  assert.equal(issues[0].state, 'closed');
});

// rc/v0.65.2: 1 <- 2 ; rc/v0.65.3: 3 <- 4 (cut from main later; the lines diverge)
const RC = { [sha('1')]: [], [sha('2')]: [sha('1')], [sha('3')]: [], [sha('4')]: [sha('3')] };
const RC_BRANCHES = { 'rc/v0.65.2': sha('2'), 'rc/v0.65.3': sha('4') };
const rc = { channel: 'rc', appName: 'cmux RC' };

test('a newer RC line resolves an older line, never the reverse', async () => {
  // rc/v0.65.3 moves on to 7 after 4 published.
  const parents = { ...RC, [sha('7')]: [sha('4')] };
  const { github, issues } = fakeGitHub({ parents, branches: { ...RC_BRANCHES, 'rc/v0.65.3': sha('7') } });
  await fail(github, sha('1'), 'rc/v0.65.2', rc);
  await publish(github, sha('4'), 'rc/v0.65.3', rc);
  assert.equal(issues[0].state, 'closed');

  // The next incident reopens the same issue.
  await fail(github, sha('7'), 'rc/v0.65.3', rc);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].state, 'open');
  await publish(github, sha('2'), 'rc/v0.65.2', rc);
  assert.equal(issues[0].state, 'open');
  await publish(github, sha('7'), 'rc/v0.65.3', rc);
  assert.equal(issues[0].state, 'closed');
});

test('a failure rewritten off its branch is resolved by the branch tip', async () => {
  // 5 was force-pushed away: rc/v0.65.2 is now 1 <- 2, and 5 diverges from 2.
  const { github, issues } = fakeGitHub({ parents: { ...RC, [sha('5')]: [sha('1')] }, branches: RC_BRANCHES });
  await fail(github, sha('5'), 'rc/v0.65.2', rc);
  await publish(github, sha('2'), 'rc/v0.65.2', rc);
  assert.equal(issues[0].state, 'closed');
});

test('a failure still on its branch, diverged from the publication, stays open', async () => {
  // 6 is on rc/v0.65.2 (the branch moved to 6) and diverges from the published 2.
  const { github, issues } = fakeGitHub({ parents: { ...RC, [sha('6')]: [sha('1')] }, branches: { ...RC_BRANCHES, 'rc/v0.65.2': sha('6') } });
  await fail(github, sha('6'), 'rc/v0.65.2', rc);
  await publish(github, sha('2'), 'rc/v0.65.2', rc);
  assert.equal(issues[0].state, 'open');
});

test('a close that lands between a report and its check is undone by the reporter', async () => {
  const { github, issues, hooks } = fakeGitHub({ parents: MAIN });
  await fail(github, sha('b'));
  // The closer read the issue before d's marker, so it closes it right after.
  hooks.afterComment = async (n) => { await github.rest.issues.update({ issue_number: n, state: 'closed' }); };
  await fail(github, sha('d'));
  assert.equal(issues[0].state, 'open');
  assert.match(issues[0].comments.at(-1), /^Reopened: failing on .*d{40} \(main\)/);
});

test('a report that lands between a close and its read-back is undone by the closer', async () => {
  const { github, issues, hooks } = fakeGitHub({ parents: MAIN });
  await fail(github, sha('b'));
  // The reporter's marker for d lands right after the closer's resolution comment.
  hooks.afterComment = async (n) => { issues[n - 1].comments.push(`<!-- cmux-nightly-failure: sha=${sha('d')} ref=main -->`); };
  assert.deepEqual(await publish(github, sha('c')), []);
  assert.equal(issues[0].state, 'open');
});

test('a report covered by the racing close leaves the incident closed', async () => {
  const { github, issues, hooks } = fakeGitHub({ parents: MAIN });
  await fail(github, sha('b'));
  hooks.afterComment = async (n) => {
    issues[n - 1].comments.push(`<!-- cmux-nightly-resolved: sha=${sha('d')} ref=main -->`);
    await github.rest.issues.update({ issue_number: n, state: 'closed' });
  };
  await fail(github, sha('c'));
  assert.equal(issues[0].state, 'closed');
});

test('two reporters that both found no incident converge on one', async () => {
  const { github, issues, hooks } = fakeGitHub({ parents: MAIN });
  // Both reporters list before either creates.
  let gate;
  const bothListed = new Promise((r) => { gate = r; });
  let lists = 0;
  hooks.beforeList = async () => { lists += 1; if (lists === 2) gate(); if (lists <= 2) await bothListed; };
  await Promise.all([fail(github, sha('b')), fail(github, sha('c'))]);
  hooks.beforeList = null;
  assert.equal(issues.length, 2);
  const left = open(issues);
  assert.equal(left.length, 1);
  assert.equal(left[0].number, 1);
  const failures = failuresIn([left[0].body, ...issues[0].comments]).map((f) => f.sha).sort();
  assert.deepEqual(failures, [sha('b'), sha('c')]);
  assert.equal(issues[1].state_reason, 'not_planned');
  // The duplicate's failures count on the incident that stays.
  await publish(github, sha('b'));
  assert.equal(issues[0].state, 'open');
  await publish(github, sha('c'));
  assert.equal(issues[0].state, 'closed');
});

test('an older run that fails after a newer one published opens no incident', async () => {
  const { github, issues } = fakeGitHub({ parents: MAIN });
  github.rest.repos.getReleaseByTag = async () => ({ data: { body: `<!-- cmux-published-sha: ${sha('d')} -->\nnotes` } });
  assert.equal(await fail(github, sha('b'), 'main', { releaseTag: 'nightly' }), null);
  assert.equal(issues.length, 0);
  // A failure newer than the published commit is an incident.
  github.rest.repos.getReleaseByTag = async () => ({ data: { body: `<!-- cmux-published-sha: ${sha('b')} -->` } });
  assert.equal(await fail(github, sha('c'), 'main', { releaseTag: 'nightly' }), 1);
  // No release yet: report.
  github.rest.repos.getReleaseByTag = async () => { throw httpError(404); };
  assert.equal(await fail(github, sha('d'), 'main', { releaseTag: 'nightly' }), 1);
});

test('a failure rewritten off its branch after the branch published opens no incident', async () => {
  // 5 was force-pushed away from rc/v0.65.2, whose tip 2 is published.
  const { github, issues } = fakeGitHub({ parents: { ...RC, [sha('5')]: [sha('1')] }, branches: RC_BRANCHES });
  github.rest.repos.getReleaseByTag = async () => ({ data: { body: `<!-- cmux-published-sha: ${sha('2')} -->` } });
  assert.equal(await fail(github, sha('5'), 'rc/v0.65.2', { ...rc, releaseTag: 'rc' }), null);
  assert.equal(issues.length, 0);
  // Still on its branch (the branch moved to 6): an incident.
  const other = fakeGitHub({ parents: { ...RC, [sha('6')]: [sha('1')] }, branches: { ...RC_BRANCHES, 'rc/v0.65.2': sha('6') } });
  other.github.rest.repos.getReleaseByTag = async () => ({ data: { body: `<!-- cmux-published-sha: ${sha('2')} -->` } });
  assert.equal(await fail(other.github, sha('6'), 'rc/v0.65.2', { ...rc, releaseTag: 'rc' }), 1);
});

test('comments are read in id order whatever order the API returns', async () => {
  const { github, issues } = fakeGitHub({ parents: MAIN, labelExists: true });
  // An old-style close settled c; then a rerun fails again at c.
  await github.rest.issues.create({ labels: ['nightly-failure'], body: failureMarkerFor(sha('c')) });
  issues[0].comments.push(`cmux NIGHTLY publish succeeded again on ${sha('a')}: https://x`);
  issues[0].state = 'closed';
  await fail(github, sha('c'));
  assert.equal(issues[0].state, 'open');
  const list = github.rest.issues.listComments;
  github.rest.issues.listComments = async (args) => {
    const { data } = await list(args);
    return { data: data.map((c, i) => ({ ...c, id: i + 1 })).reverse() };
  };
  assert.deepEqual(await publish(github, sha('a')), []);
  assert.equal(issues[0].state, 'open');
});

test('an older RC line that fails after a newer line published is resolved by that line', async () => {
  const { github, issues } = fakeGitHub({ parents: RC, branches: RC_BRANCHES });
  // The release does not name its line, so the report alone cannot tell.
  github.rest.repos.getReleaseByTag = async () => ({ data: { body: `<!-- cmux-published-sha: ${sha('4')} -->` } });
  assert.equal(await fail(github, sha('2'), 'rc/v0.65.2', { ...rc, releaseTag: 'rc' }), 1);
  assert.equal(issues[0].state, 'open');
  // The newer line's next close knows its line and resolves it.
  assert.deepEqual(await publish(github, sha('4'), 'rc/v0.65.3', rc), [1]);
});

test('open duplicates left by older code are each resolved on their own', async () => {
  const { github, issues } = fakeGitHub({ parents: MAIN, labelExists: true });
  await github.rest.issues.create({ labels: ['nightly-failure'], body: `<!-- cmux-nightly-failure: sha=${sha('b')} ref=main -->` });
  await github.rest.issues.create({ labels: ['nightly-failure'], body: `<!-- cmux-nightly-failure: sha=${sha('d')} ref=main -->` });
  assert.deepEqual(await publish(github, sha('c')), [1]);
  assert.equal(issues[1].state, 'open'); // d is newer than c
  // An older writer that appends to the open duplicate is still read there.
  issues[1].comments.push(`cmux NIGHTLY run https://x failed on ${sha('d')} (main) in: build.`);
  assert.deepEqual(await publish(github, sha('d')), [2]);
});

test('a failure recorded after a close settled the same commit counts again', async () => {
  const { github, issues } = fakeGitHub({ parents: MAIN, labelExists: true });
  // Settled by the old code's closing comment, which carries no resolution marker.
  await github.rest.issues.create({ labels: ['nightly-failure'], body: failureMarkerFor(sha('c')) });
  issues[0].comments.push(`cmux NIGHTLY publish succeeded again on ${sha('c')} (main): https://x`);
  issues[0].state = 'closed';
  await fail(github, sha('c'));
  assert.equal(issues[0].state, 'open');
  assert.deepEqual(await publish(github, sha('b')), []);
  assert.equal(issues[0].state, 'open');
  assert.deepEqual(await publish(github, sha('c')), [1]);
});

test('every incident reuses the oldest issue, so a lagging list never splits one', async () => {
  const { github, issues, hooks } = fakeGitHub({ parents: MAIN });
  await fail(github, sha('b'));
  await publish(github, sha('b'));
  assert.equal(issues[0].state, 'closed');
  // Newer issues are missing from the lagging list; the oldest one is not.
  hooks.hideFromList = (i) => i.number > 1;
  await Promise.all([fail(github, sha('c')), fail(github, sha('d'))]);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].state, 'open');
  // The failures settled by the earlier close do not count again.
  await publish(github, sha('d'));
  assert.equal(issues[0].state, 'closed');
});

test('a publication that finishes while a failure is recorded closes the incident again', async () => {
  const { github, issues, hooks } = fakeGitHub({ parents: MAIN });
  let reads = 0;
  github.rest.repos.getReleaseByTag = async () => {
    reads += 1;
    return { data: { body: reads === 1 ? `<!-- cmux-published-sha: ${sha('a')} -->` : `<!-- cmux-published-sha: ${sha('d')} -->` } };
  };
  assert.equal(await fail(github, sha('b'), 'main', { releaseTag: 'nightly', runUrl: 'https://run' }), 1);
  assert.equal(reads, 2);
  assert.equal(issues[0].state, 'closed');
});

test('a publication of a commit GitHub does not have never closes a failure', async () => {
  const { github, issues } = fakeGitHub({ parents: MAIN });
  await fail(github, sha('c'));
  assert.deepEqual(await publish(github, sha('f')), []); // f is unknown
  assert.equal(issues[0].state, 'open');
  // A failed commit that is gone is resolved by a publication GitHub has.
  const other = fakeGitHub({ parents: MAIN, labelExists: true });
  await other.github.rest.issues.create({ labels: ['nightly-failure'], body: failureMarkerFor(sha('e')) });
  assert.deepEqual(await publish(other.github, sha('d')), [1]);
});

test('a branch rewound below a failed commit is resolved by publishing its tip', async () => {
  // main was rewound from d to b; d still exists.
  const { github, issues } = fakeGitHub({ parents: MAIN, branches: { main: sha('b') } });
  await fail(github, sha('d'));
  assert.deepEqual(await publish(github, sha('b')), [1]);
  // The reporter for d, after b published from the rewound branch, opens nothing.
  const other = fakeGitHub({ parents: MAIN, branches: { main: sha('b') } });
  other.github.rest.repos.getReleaseByTag = async () => ({ data: { body: `<!-- cmux-published-sha: ${sha('b')} -->` } });
  assert.equal(await fail(other.github, sha('d'), 'main', { releaseTag: 'nightly' }), null);
  assert.equal(other.issues.length, 0);
  // Not rewound: d is still on main and stays an incident.
  const kept = fakeGitHub({ parents: MAIN, branches: { main: sha('d') } });
  await fail(kept.github, sha('d'));
  assert.deepEqual(await publish(kept.github, sha('b')), []);
});

test('a failure that the closing publication already includes leaves the incident closed', async () => {
  const { github, issues } = fakeGitHub({ parents: MAIN });
  await fail(github, sha('b'));
  await publish(github, sha('d'));
  assert.equal(issues[0].state, 'closed');
  // A stale-tag reporter for c that paused before writing (no release check).
  await fail(github, sha('c'));
  assert.equal(issues[0].state, 'closed');
  // A newer commit's failure reopens it.
  const { github: g2, issues: i2 } = fakeGitHub({ parents: { ...MAIN, [sha('e')]: [sha('d')] }, branches: { main: sha('e') } });
  await fail(g2, sha('b'));
  await publish(g2, sha('d'));
  await fail(g2, sha('e'));
  assert.equal(i2[0].state, 'open');
});
