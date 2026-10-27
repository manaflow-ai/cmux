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
// The closing comment lists the failures it settled, so a later incident on
// the same issue starts from the failures recorded after them.
//
// One issue, never a new one per incident: the channel's incident lives on
// the oldest issue that ever carried its label, reopened when a failure
// arrives. GitHub's issue list lags a create, so two reporters that each
// created an issue could each miss the other's; the oldest issue is long
// settled in the list, so every reporter finds the same one. Only the very
// first report of a channel creates it. Open duplicates (left by the code
// before this, or by rc/ branches that still carry it) fold into it, their
// failures carried over.
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

// Whether publishing `published` resolves `failure`.
export async function covers({ github, owner, repo, published, failure }) {
  if (failure.sha === published.sha.toLowerCase()) return true;
  const status = await compareStatus(github, owner, repo, failure.sha, published.sha);
  if (status === 'ahead' || status === 'identical') return true;
  if (status === 'missing') return true; // the failed commit no longer exists
  if (status === 'behind') return false; // the failure is newer than the publication
  if (failure.ref !== published.ref) {
    const failed = rcVersion(failure.ref);
    const shipped = rcVersion(published.ref);
    return Boolean(failed && shipped && compareVersions(shipped, failed) > 0);
  }
  // Diverged on one branch: the failure is resolved only if it was rewritten away.
  const onBranch = await compareStatus(github, owner, repo, failure.sha, failure.ref);
  return !(onBranch === 'ahead' || onBranch === 'identical');
}

async function texts(github, owner, repo, issue) {
  const comments = await github.paginate(github.rest.issues.listComments, { owner, repo, issue_number: issue.number, per_page: 100 });
  return [issue.body || '', ...comments.map((comment) => comment.body || '')];
}

const key = (failure) => `${failure.sha}@${failure.ref}`;
const SETTLED = /<!--\s*cmux-nightly-settled:\s*([^>]*?)\s*-->/gi;

export function settledMarker(failures) {
  return `<!-- cmux-nightly-settled: ${failures.map(key).join(',')} -->`;
}

// The failures recorded on the issue that no closing comment settled, and the
// resolutions posted since the last close.
export function activeState(all) {
  const settled = new Set();
  let lastClose = -1;
  all.forEach((text, index) => {
    for (const match of String(text || '').matchAll(SETTLED)) {
      match[1].split(',').filter(Boolean).forEach((entry) => settled.add(entry));
      lastClose = index;
    }
  });
  return {
    failures: failuresIn(all).filter((failure) => !settled.has(key(failure))),
    resolutions: resolutionsIn(all.slice(lastClose + 1)),
  };
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

// The failures that none of `resolutions` covers.
async function uncovered({ github, owner, repo, failures, resolutions }) {
  const left = [];
  for (const failure of failures) {
    let resolved = false;
    for (const published of resolutions) {
      if (await covers({ github, owner, repo, published, failure })) { resolved = true; break; }
    }
    if (!resolved) left.push(failure);
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

// The rc/ branch newer than the failure's line that holds `published`, or null
// (RC lines are cut from main, so they diverge from one another).
export async function newerRcLine({ github, owner, repo, published, failureRef }) {
  const failed = rcVersion(failureRef);
  if (!failed) return null;
  const refs = await github.paginate(github.rest.git.listMatchingRefs, { owner, repo, ref: 'heads/rc/', per_page: 100 });
  for (const { ref } of refs) {
    const branch = ref.replace(/^refs\/heads\//, '');
    const version = rcVersion(branch);
    if (!version || compareVersions(version, failed) <= 0) continue;
    const status = await compareStatus(github, owner, repo, published, branch);
    if (status === 'ahead' || status === 'identical') return branch;
  }
  return null;
}

// The channel's publication that supersedes a failure of `sha` on `ref`, as
// { sha, ref }, or null.
async function superseding({ github, owner, repo, releaseTag, sha, ref }) {
  const published = await publishedCommit({ github, owner, repo, releaseTag });
  if (!published || published === sha.toLowerCase()) return null;
  const status = await compareStatus(github, owner, repo, sha, published);
  if (status === 'ahead') return { sha: published, ref };
  if (status !== 'diverged') return null;
  const line = await newerRcLine({ github, owner, repo, published, failureRef: ref });
  return line ? { sha: published, ref: line } : null;
}

async function closeDuplicate({ github, owner, repo, duplicate, canonical }) {
  const carry = async (failures) => {
    if (failures.length === 0) return;
    await github.rest.issues.createComment({
      owner, repo, issue_number: canonical.number,
      body: `${failures.map((f) => failureMarker(f.sha, f.ref)).join('\n')}\nFailures carried over from duplicate #${duplicate.number}.`,
    });
  };
  const before = activeState(await texts(github, owner, repo, duplicate)).failures;
  await carry(before);
  await github.rest.issues.createComment({ owner, repo, issue_number: duplicate.number, body: `Duplicate of #${canonical.number}.` });
  await github.rest.issues.update({ owner, repo, issue_number: duplicate.number, state: 'closed', state_reason: 'not_planned' });
  // A reporter may have recorded on it between the read and the close.
  const seen = new Set(before.map(key));
  await carry(activeState(await texts(github, owner, repo, duplicate)).failures.filter((f) => !seen.has(key(f))));
}

// Records a failure of `sha` on `ref` on the channel's incident. With
// `releaseTag`, a failure that the channel's publication supersedes (an older
// run that failed after a newer one published, or an older RC line) is not an
// incident.
export async function report({ github, owner, repo, channel, appName, ref, sha, body, runUrl = '', releaseTag = null, log = () => {} }) {
  const label = `${channel}-failure`;
  const failure = { sha: sha.toLowerCase(), ref };
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
    // The channel's first incident ever.
    const { data } = await github.rest.issues.create({ owner, repo, title, labels: [label], body: text });
    issue = (await oldestIncident(github, owner, repo, label)) || data;
    if (issue.number !== data.number) {
      await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body: text });
      await closeDuplicate({ github, owner, repo, duplicate: data, canonical: issue });
    }
  } else {
    if (issue.state === 'closed') {
      await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'open', title });
    }
    await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body: text });
  }
  for (const duplicate of await openIncidents(github, owner, repo, label)) {
    if (duplicate.number !== issue.number) await closeDuplicate({ github, owner, repo, duplicate, canonical: issue });
  }
  // A closer may have read the issue before this marker landed and closed it.
  const { data: current } = await github.rest.issues.get({ owner, repo, issue_number: issue.number });
  if (current.state === 'closed') {
    const state = activeState(await texts(github, owner, repo, current));
    if (state.failures.some((f) => key(f) === key(failure))
        && (await uncovered({ github, owner, repo, failures: [failure], resolutions: state.resolutions })).length > 0) {
      await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'open' });
      await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body: `Reopened: ${sha} (${ref}) failed while this incident was being closed.` });
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

// Resolves the channel's incident when the publication of `sha` on `ref`
// covers every failure still open on it, and comments when it does not.
export async function close({ github, owner, repo, channel, appName, ref, sha, runUrl, log = () => {} }) {
  const label = `${channel}-failure`;
  const published = { sha: sha.toLowerCase(), ref };
  const closed = [];
  const incidents = await openIncidents(github, owner, repo, label);
  // Open duplicates fold into the lowest-numbered incident first.
  for (const duplicate of incidents.slice(1)) {
    await closeDuplicate({ github, owner, repo, duplicate, canonical: incidents[0] });
  }
  for (const issue of incidents.slice(0, 1)) {
    const before = activeState(await texts(github, owner, repo, issue));
    const resolutions = [...before.resolutions, published];
    let left = await uncovered({ github, owner, repo, failures: before.failures, resolutions });
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
      body: `${resolvedMarker(sha, ref)}\n${settledMarker(before.failures)}\n${appName} publish succeeded again on ${sha} (${ref}): ${runUrl}`,
    });
    await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'closed' });
    // A reporter may have recorded a failure after the read above.
    const after = activeState(await texts(github, owner, repo, issue));
    left = await uncovered({ github, owner, repo, failures: after.failures, resolutions: [...after.resolutions, published] });
    if (left.length > 0) {
      await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'open' });
      await github.rest.issues.createComment({
        owner, repo, issue_number: issue.number,
        body: `Reopened: ${left.map((f) => `${f.sha} (${f.ref})`).join(', ')} failed while this incident was being closed.`,
      });
      log(`#${issue.number} reopened`);
      continue;
    }
    closed.push(issue.number);
    log(`closed #${issue.number}`);
  }
  return closed;
}
