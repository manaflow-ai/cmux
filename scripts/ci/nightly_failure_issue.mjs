// The classic nightly and RC failure incident: one open issue per channel
// label (`nightly-failure`, `rc-failure`), shared by every run.
//
// Main and rc push runs build in parallel (#25959), so reports and closes
// arrive in any order. Each failure is recorded with a marker naming its
// commit and branch, and a publication closes the incident only when it
// covers every recorded failure:
//   - the failed commit is the published commit or one of its ancestors;
//   - or, for RC, the failure is on an older rc/vX.Y.Z line than the
//     published one (each RC line is cut from main, so lines diverge);
//   - or the failed commit is gone from its branch (history was rewritten).
// A newer commit's failure therefore stays open when an older run publishes.
//
// Reporter and closer race on the same issue. The reporter writes its marker
// and then reads the issue's state; the closer writes its resolution, reads
// the failures, closes, and reads them again. Whichever reads second sees the
// other's write, and reopens the incident when a failure is left uncovered.
// Two reporters that both found no open issue each create one; both then
// keep the lowest-numbered open issue and close the others as duplicates.

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

async function openIncidents(github, owner, repo, label) {
  const issues = await github.paginate(github.rest.issues.listForRepo, { owner, repo, labels: label, state: 'open', per_page: 100 });
  return issues.filter((issue) => !issue.pull_request).sort((a, b) => a.number - b.number);
}

// The failures recorded on an issue that none of `resolutions` covers.
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

// Whether `published` is on an rc/ line newer than the failure's line (RC
// lines are cut from main, so they diverge from one another).
export async function onNewerRcLine({ github, owner, repo, published, failureRef }) {
  const failed = rcVersion(failureRef);
  if (!failed) return false;
  const refs = await github.paginate(github.rest.git.listMatchingRefs, { owner, repo, ref: 'heads/rc/', per_page: 100 });
  for (const { ref } of refs) {
    const branch = ref.replace(/^refs\/heads\//, '');
    const version = rcVersion(branch);
    if (!version || compareVersions(version, failed) <= 0) continue;
    const status = await compareStatus(github, owner, repo, published, branch);
    if (status === 'ahead' || status === 'identical') return true;
  }
  return false;
}

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Records a failure of `sha` on `ref` in the channel's one open incident.
// With `releaseTag`, a failure the channel has already published past (an
// older run that failed after a newer one published, or an older RC line
// than the published one) is not an incident.
export async function report({ github, owner, repo, channel, appName, ref, sha, body, releaseTag = null, log = () => {}, attempt = 1, sleep = pause }) {
  const label = `${channel}-failure`;
  if (releaseTag) {
    const published = await publishedCommit({ github, owner, repo, releaseTag });
    if (published && published !== sha.toLowerCase()) {
      const status = await compareStatus(github, owner, repo, sha, published);
      if (status === 'ahead' || (status === 'diverged' && await onNewerRcLine({ github, owner, repo, published, failureRef: ref }))) {
        log(`${releaseTag} already publishes ${published}, which supersedes ${sha} (${ref}); no incident`);
        return null;
      }
    }
  }
  const text = `${failureMarker(sha, ref)}\n${body}`;
  await ensureLabel({ github, owner, repo, label, description: `${appName} publish failing` });
  let open = await openIncidents(github, owner, repo, label);
  let issue;
  if (open.length > 0) {
    issue = open[0];
    await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body: text });
  } else {
    const { data } = await github.rest.issues.create({ owner, repo, title: `${appName} build is failing on ${ref}`, labels: [label], body: text });
    issue = data;
    // The issue list can lag a create. Read it until it shows this issue, so
    // it also shows a parallel reporter's issue created before this one. A
    // pair that still misses each other converges at the next report or close.
    for (let tries = 1; ; tries += 1) {
      open = await openIncidents(github, owner, repo, label);
      if (open.some((other) => other.number === issue.number) || tries === 5) break;
      await sleep(2000);
    }
    if (open.length > 0 && open[0].number < issue.number) {
      // A parallel reporter opened an older incident: record there.
      await github.rest.issues.createComment({ owner, repo, issue_number: open[0].number, body: text });
      issue = open[0];
    }
  }
  // Keep the lowest-numbered open incident; carry the others' failures to it.
  for (const duplicate of open) {
    if (duplicate.number > issue.number) await closeDuplicate({ github, owner, repo, duplicate, canonical: issue });
  }
  // A closer may have read the issue before this marker landed and closed it,
  // or a parallel reporter closed it as a duplicate of an older incident.
  const { data: current } = await github.rest.issues.get({ owner, repo, issue_number: issue.number });
  if (current.state === 'closed' && current.state_reason === 'not_planned' && attempt < 3) {
    return report({ github, owner, repo, channel, appName, ref, sha, body, releaseTag, log, attempt: attempt + 1, sleep });
  }
  if (current.state === 'closed') {
    const resolutions = resolutionsIn(await texts(github, owner, repo, current));
    const left = await uncovered({ github, owner, repo, failures: [{ sha: sha.toLowerCase(), ref }], resolutions });
    if (left.length > 0) {
      await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'open' });
      await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body: `Reopened: ${sha} (${ref}) failed while this incident was being closed.` });
      log(`reopened #${issue.number}`);
    }
  }
  log(`recorded ${sha} (${ref}) on #${issue.number}`);
  return issue.number;
}

async function closeDuplicate({ github, owner, repo, duplicate, canonical }) {
  const failures = failuresIn(await texts(github, owner, repo, duplicate));
  const carried = failures.map((f) => failureMarker(f.sha, f.ref)).join('\n');
  await github.rest.issues.createComment({
    owner, repo, issue_number: canonical.number,
    body: `${carried}\nFailures carried over from duplicate #${duplicate.number}.`.trim(),
  });
  await github.rest.issues.createComment({ owner, repo, issue_number: duplicate.number, body: `Duplicate of #${canonical.number}.` });
  await github.rest.issues.update({ owner, repo, issue_number: duplicate.number, state: 'closed', state_reason: 'not_planned' });
}

// Resolves the channel's open incidents that the publication of `sha` on
// `ref` covers, and comments on the ones it leaves open.
export async function close({ github, owner, repo, channel, appName, ref, sha, runUrl, log = () => {} }) {
  const label = `${channel}-failure`;
  const published = { sha: sha.toLowerCase(), ref };
  const closed = [];
  // Duplicates that two reporters left open (a lagging list) fold into the
  // lowest-numbered incident first, failures carried over.
  const incidents = await openIncidents(github, owner, repo, label);
  for (const duplicate of incidents.slice(1)) {
    await closeDuplicate({ github, owner, repo, duplicate, canonical: incidents[0] });
  }
  for (const issue of incidents.slice(0, 1)) {
    const before = await texts(github, owner, repo, issue);
    const resolutions = [...resolutionsIn(before), published];
    // Unmarked, unparseable incidents close as before.
    let left = await uncovered({ github, owner, repo, failures: failuresIn(before), resolutions });
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
      body: `${resolvedMarker(sha, ref)}\n${appName} publish succeeded again on ${sha} (${ref}): ${runUrl}`,
    });
    await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'closed' });
    // A reporter may have recorded a failure after the read above.
    const after = await texts(github, owner, repo, issue);
    left = await uncovered({ github, owner, repo, failures: failuresIn(after), resolutions: [...resolutionsIn(after), published] });
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
