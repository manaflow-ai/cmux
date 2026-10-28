// The classic nightly and RC failure incident: one issue per channel label
// (`nightly-failure`, `rc-failure`), shared by every run.
//
// Main and rc push runs build in parallel (#25959), so reports and closes
// arrive in any order. Each failure is recorded with a marker naming its
// commit and branch, and a publication closes the incident only when it
// covers every failure still open on it:
//   - the failed commit is the published commit or one of its ancestors;
//   - or, for RC, the failure is on an older rc/vX.Y.Z line than the
//     published one (each RC line is cut from main, so lines diverge);
//   - or the failed commit is gone from its branch (history was rewritten).
// A newer commit's failure therefore stays open when an older run publishes.
//
// One issue, never a new one per incident: the channel's incident lives on
// the oldest issue that ever carried its label, reopened when a failure
// arrives. GitHub's issue list lags a create, so two reporters that each
// created an issue could each miss the other's; the oldest issue is long
// settled in the list, so every reporter finds the same one. Only the very
// first report of a channel creates it. rc/ branches cut before this change
// still run the old inline script and may open another issue; each open
// issue is resolved on its own, as before. Those writers keep the old code's
// races (a failure written just after a close lands on a closed issue); they
// go away with the branches.
//
// An issue is an ordered log. A failure counts until a later closing comment
// settles it, so a rerun that fails again at a commit an earlier close settled
// counts again. Comments by the code before this ("publish succeeded again
// on", "accepted and published") settled everything before them. A failure
// that counts is covered by any publication the issue records, whichever was
// written first: the feed already includes that commit.
//
// Reporter and closer race on the issue. The reporter writes its marker and
// then reads the issue's state; the closer writes its resolution, reads the
// failures, closes, and reads them again. Whichever reads second sees the
// other's write, and reopens the incident when a failure is left uncovered.
// A reporter also checks the channel's publication before and after it
// records: a failure that a publication already supersedes is not an
// incident, and one superseded while it was being recorded is closed again.

const FAILURE = /<!--\s*cmux-nightly-failure:\s*sha=([0-9a-f]{40})\s+ref=(\S+?)\s*-->/gi;
const RESOLVED = /<!--\s*cmux-nightly-resolved:\s*sha=([0-9a-f]{40})\s+ref=(\S+?)\s*-->/gi;
// Incidents opened before the markers existed name the commit in prose.
const LEGACY = /(?:failed on|tag marker stale for) ([0-9a-f]{40}) \(([^)\s]+)\)/gi;

export function failureMarker(sha, ref) {
  return `<!-- cmux-nightly-failure: sha=${sha.toLowerCase()} ref=${ref} -->`;
}

export function resolvedMarker(sha, ref) {
  return `<!-- cmux-nightly-resolved: sha=${sha.toLowerCase()} ref=${ref} -->`;
}

function collect(patterns, texts) {
  const found = new Map();
  for (const pattern of patterns) {
    for (const text of texts) {
      for (const match of String(text || '').matchAll(pattern)) {
        const entry = { sha: match[1].toLowerCase(), ref: match[2] };
        found.set(`${entry.sha} ${entry.ref}`, entry);
      }
    }
  }
  return [...found.values()];
}

export function failuresIn(texts) {
  return collect([FAILURE, LEGACY], texts);
}

export function resolutionsIn(texts) {
  return collect([RESOLVED], texts);
}

// rc/v0.65.2 -> [0, 65, 2]; anything else -> null.
export function rcVersion(ref) {
  const match = /^rc\/v?(\d+(?:\.\d+)*)$/.exec(ref || '');
  return match ? match[1].split('.').map(Number) : null;
}

function compareVersions(a, b) {
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const d = (a[i] || 0) - (b[i] || 0);
    if (d !== 0) return d;
  }
  return 0;
}

// The compare status of base...head, or 'missing' when GitHub no longer has
// one of the commits (404 or 422). Any other error throws: the incident stays
// open rather than closing on an unread answer.
async function compareStatus(github, owner, repo, base, head) {
  try {
    const { data } = await github.rest.repos.compareCommitsWithBasehead({ owner, repo, basehead: `${base}...${head}`, per_page: 1 });
    return data.status;
  } catch (error) {
    if (error.status === 404 || error.status === 422) return 'missing';
    throw error;
  }
}

// Whether GitHub still has `sha`. Only a 404 or 422 means it does not; any
// other error throws.
async function commitExists(github, owner, repo, sha) {
  try {
    await github.rest.repos.getCommit({ owner, repo, ref: sha, per_page: 1 });
    return true;
  } catch (error) {
    if (error.status === 404 || error.status === 422) return false;
    throw error;
  }
}

// A compare that could not be read: the failure is resolved only when the
// failed commit itself is gone and the published one is not.
async function failedCommitGone(github, owner, repo, failedSha, publishedSha) {
  return !(await commitExists(github, owner, repo, failedSha)) && (await commitExists(github, owner, repo, publishedSha));
}

// Whether `sha` is no longer on `branch`: the branch tip does not include it.
// A branch GitHub cannot read is not proof, so the failure stays.
async function offBranch(github, owner, repo, sha, branch) {
  const status = await compareStatus(github, owner, repo, sha, branch);
  return status === 'behind' || status === 'diverged';
}

// Whether publishing `published` resolves `failure`.
export async function covers({ github, owner, repo, published, failure }) {
  if (failure.sha === published.sha.toLowerCase()) return true;
  const status = await compareStatus(github, owner, repo, failure.sha, published.sha);
  if (status === 'ahead' || status === 'identical') return true;
  if (status === 'missing') return failedCommitGone(github, owner, repo, failure.sha, published.sha);
  if (failure.ref !== published.ref) {
    if (status === 'behind') return false; // the failure is newer than the publication
    const failed = rcVersion(failure.ref);
    const shipped = rcVersion(published.ref);
    return Boolean(failed && shipped && compareVersions(shipped, failed) > 0);
  }
  // Newer than or diverged from the publication on one branch: the failure is
  // resolved only if it was rewritten away (a force-push or a rewind).
  return offBranch(github, owner, repo, failure.sha, failure.ref);
}

async function texts(github, owner, repo, issue) {
  const comments = await github.paginate(github.rest.issues.listComments, { owner, repo, issue_number: issue.number, per_page: 100 });
  // GitHub lists issue comments by ascending id; sort anyway, since settlement
  // depends on the order.
  const ordered = [...comments].sort((a, b) => (a.id ?? 0) - (b.id ?? 0));
  return [issue.body || '', ...ordered.map((comment) => comment.body || '')];
}

const key = (failure) => `${failure.sha}@${failure.ref}`;
const SETTLED = /<!--\s*cmux-nightly-settled:\s*([^>]*?)\s*-->/i;
// Closing comments written before the markers existed settled everything.
const LEGACY_SETTLED = /(?:publish succeeded again on|accepted and published) [0-9a-f]{40}/i;

export function settledMarker(failures) {
  return `<!-- cmux-nightly-settled: ${failures.map(key).join(',')} -->`;
}

// The log's failures that count, each with the issue's resolutions. A failure
// is settled by a later closing comment that lists it.
export function activeFailures(all) {
  const entries = [];
  all.forEach((text, index) => {
    const settled = SETTLED.exec(String(text || ''));
    const settles = settled ? new Set(settled[1].split(',').filter(Boolean)) : null;
    const settlesAll = !settled && LEGACY_SETTLED.test(String(text || ''));
    if (settles || settlesAll) {
      for (const entry of entries) {
        if (settlesAll || settles.has(key(entry.failure))) entry.settled = true;
      }
    }
    for (const failure of failuresIn([text])) {
      // A failure written again later replaces its earlier entry.
      for (const entry of entries) if (key(entry.failure) === key(failure)) entry.replaced = true;
      entries.push({ failure, settled: false, replaced: false });
    }
  });
  // A publication covers a failure whatever the order of their comments: it
  // includes the failed commit or not.
  const resolutions = resolutionsIn(all);
  return entries.filter((entry) => !entry.settled && !entry.replaced).map((entry) => ({ ...entry, later: resolutions }));
}

async function openIncidents(github, owner, repo, label) {
  const issues = await github.paginate(github.rest.issues.listForRepo, { owner, repo, labels: label, state: 'open', per_page: 100 });
  return issues.filter((issue) => !issue.pull_request).sort((a, b) => a.number - b.number);
}

// The oldest issue that ever carried the label, open or closed.
async function oldestIncident(github, owner, repo, label) {
  const { data } = await github.rest.issues.listForRepo({ owner, repo, labels: label, state: 'all', sort: 'created', direction: 'asc', per_page: 10 });
  return data.filter((issue) => !issue.pull_request).sort((a, b) => a.number - b.number)[0] || null;
}

async function isCovered(github, owner, repo, failure, resolutions) {
  for (const published of resolutions) {
    if (await covers({ github, owner, repo, published, failure })) return true;
  }
  return false;
}

// The counting failures that neither a later resolution nor `extra` covers.
async function uncovered({ github, owner, repo, entries, extra = [] }) {
  const left = [];
  for (const entry of entries) {
    if (!(await isCovered(github, owner, repo, entry.failure, [...entry.later, ...extra]))) left.push(entry.failure);
  }
  return left;
}

export async function ensureLabel({ github, owner, repo, label, description }) {
  try {
    await github.rest.issues.getLabel({ owner, repo, name: label });
    return;
  } catch (error) {
    if (error.status !== 404) throw error;
  }
  try {
    await github.rest.issues.createLabel({ owner, repo, name: label, color: 'b60205', description });
  } catch (error) {
    // 422: a parallel reporter created it between the read and the create.
    if (error.status !== 422) throw error;
  }
}

// The commit the channel's release names as published, or null.
export async function publishedCommit({ github, owner, repo, releaseTag }) {
  try {
    const { data } = await github.rest.repos.getReleaseByTag({ owner, repo, tag: releaseTag });
    const match = /<!--\s*cmux-published-sha:\s*([0-9a-f]{40})\s*-->/i.exec(data.body || '');
    return match ? match[1].toLowerCase() : null;
  } catch (error) {
    if (error.status === 404) return null;
    throw error;
  }
}

// The channel's publication that supersedes a failure of `sha` on `ref`, as
// { sha, ref }, or null.
async function superseding({ github, owner, repo, releaseTag, sha, ref }) {
  const published = await publishedCommit({ github, owner, repo, releaseTag });
  if (!published || published === sha.toLowerCase()) return null;
  const status = await compareStatus(github, owner, repo, sha, published);
  if (status === 'ahead') return { sha: published, ref };
  if (status === 'missing') return (await failedCommitGone(github, owner, repo, sha, published)) ? { sha: published, ref } : null;
  if (status !== 'diverged' && status !== 'behind') return null;
  // The release names its commit, not its rc/ line, so a diverged publication
  // is never taken for a newer line's here; that line's close resolves it.
  // The failed commit was rewritten off its branch, and the publication is
  // that branch's: the failure is not an incident (`covers` resolves it too).
  if (!(await offBranch(github, owner, repo, sha, ref))) return null;
  const publishedOnBranch = await compareStatus(github, owner, repo, published, ref);
  return publishedOnBranch === 'ahead' || publishedOnBranch === 'identical' ? { sha: published, ref } : null;
}

// Records a failure of `sha` on `ref` on the channel's incident. With
// `releaseTag`, a failure that the channel's publication supersedes (an older
// run that failed after a newer one published, or an older RC line) is not an
// incident.
export async function report({ github, owner, repo, channel, appName, ref, sha, body, runUrl = '', releaseTag = null, log = () => {} }) {
  const label = `${channel}-failure`;
  if (releaseTag) {
    const by = await superseding({ github, owner, repo, releaseTag, sha, ref });
    if (by) {
      log(`${releaseTag} already publishes ${by.sha} (${by.ref}), which supersedes ${sha} (${ref}); no incident`);
      return null;
    }
  }
  const text = `${failureMarker(sha, ref)}\n${body}`;
  const title = `${appName} build is failing on ${ref}`;
  await ensureLabel({ github, owner, repo, label, description: `${appName} publish failing` });
  let issue = await oldestIncident(github, owner, repo, label);
  if (!issue) {
    // The channel's first incident ever. Two first reporters keep the older issue.
    const { data } = await github.rest.issues.create({ owner, repo, title, labels: [label], body: text });
    issue = (await oldestIncident(github, owner, repo, label)) || data;
    if (issue.number !== data.number) {
      await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body: text });
      await github.rest.issues.createComment({ owner, repo, issue_number: data.number, body: `Duplicate of #${issue.number}.` });
      await github.rest.issues.update({ owner, repo, issue_number: data.number, state: 'closed', state_reason: 'not_planned' });
    }
  } else {
    await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body: text });
  }
  // The issue is closed when this is a new incident, or when a closer read it
  // before this marker landed. It opens when any failure that counts on it is
  // left uncovered; a failure that a publication the issue records already
  // includes is not an incident.
  const { data: current } = await github.rest.issues.get({ owner, repo, issue_number: issue.number });
  if (current.state === 'closed') {
    const left = await uncovered({ github, owner, repo, entries: activeFailures(await texts(github, owner, repo, current)) });
    if (left.length > 0) {
      await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'open', title });
      await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body: `Reopened: failing on ${left.map((f) => `${f.sha} (${f.ref})`).join(', ')}.` });
      log(`reopened #${issue.number}`);
    }
  }
  log(`recorded ${sha} (${ref}) on #${issue.number}`);
  // A publication that finished while this was recorded supersedes it.
  if (releaseTag) {
    const by = await superseding({ github, owner, repo, releaseTag, sha, ref });
    if (by) await close({ github, owner, repo, channel, appName, ref: by.ref, sha: by.sha, runUrl, log });
  }
  return issue.number;
}

// Resolves each open incident of the channel when the publication of `sha` on
// `ref` covers every failure that counts on it, and comments when it does not.
export async function close({ github, owner, repo, channel, appName, ref, sha, runUrl, log = () => {} }) {
  const label = `${channel}-failure`;
  const published = { sha: sha.toLowerCase(), ref };
  const closed = [];
  for (const issue of await openIncidents(github, owner, repo, label)) {
    const before = activeFailures(await texts(github, owner, repo, issue));
    const left = await uncovered({ github, owner, repo, entries: before, extra: [published] });
    if (left.length > 0) {
      const names = left.map((f) => `${f.sha} (${f.ref})`).join(', ');
      await github.rest.issues.createComment({
        owner, repo, issue_number: issue.number,
        body: `${resolvedMarker(sha, ref)}\n${appName} published ${sha} (${ref}): ${runUrl}\n\nStill failing on ${names}, which this publication does not include; the incident stays open.`,
      });
      log(`#${issue.number} stays open: ${names}`);
      continue;
    }
    await github.rest.issues.createComment({
      owner, repo, issue_number: issue.number,
      body: `${resolvedMarker(sha, ref)}\n${settledMarker(before.map((entry) => entry.failure))}\n${appName} publish succeeded on ${sha} (${ref}): ${runUrl}`,
    });
    await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'closed' });
    // A reporter may have recorded a failure after the read above; the
    // closing comment's resolution covers it only if the publication includes it.
    const after = await uncovered({ github, owner, repo, entries: activeFailures(await texts(github, owner, repo, issue)), extra: [published] });
    if (after.length > 0) {
      await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'open' });
      await github.rest.issues.createComment({
        owner, repo, issue_number: issue.number,
        body: `Reopened: ${after.map((f) => `${f.sha} (${f.ref})`).join(', ')} failed while this incident was being closed.`,
      });
      log(`#${issue.number} reopened`);
      continue;
    }
    closed.push(issue.number);
    log(`closed #${issue.number}`);
  }
  return closed;
}
