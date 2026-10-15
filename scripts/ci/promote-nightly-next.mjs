// Decide and perform a nightly-next promotion (cmuxterm-hq#2053).
//
// nightly.yml on main runs this from main's own checkout, never from the SHA
// under test, so the guard and .github/release-surface.txt are main's.
//
// decide() checks, in order:
//   G1  the SHA is on feat-cmux-next (not a fork-network or dropped commit);
//   G2  a cmux-next.yml push run of this repository on feat-cmux-next for that
//       exact SHA has a successful "cmux-next Release compile (Xcode 26)" job;
//       the gate workflow is itself on the release surface;
//   G3  the files changed from the current nightly-next to the SHA. If none
//       matches the release surface the promotion goes ahead ("promote");
//       otherwise it needs a release approver ("needs-ack");
//   G4  for "needs-ack", the landers of every first-parent commit in the range
//       that touches the surface: the push actor (repository activity), the
//       PR author and merger, and the commit author and committer. The
//       approval must come from someone who is not a lander (approvedBy()).
// Anything it cannot establish is a "refuse" (fail closed).
//
// The functions take injected clients so tests drive them with a fake API.

export const SOURCE = 'feat-cmux-next';
export const TARGET = 'nightly-next';
export const GATE_WORKFLOW = '.github/workflows/cmux-next.yml';
export const GATE_JOB = 'cmux-next Release compile (Xcode 26)';
export const ACK_ENVIRONMENT = 'release-surface-ack';
const BOT_LOGINS = new Set(['web-flow', 'github-actions[bot]', 'GitHub']);
const MAX_FIRST_PARENT_COMMITS = 200;
const MAX_ACTIVITY_PAGES = 20;

export function parseSurface(text) {
  return text
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'));
}

function globToRegExp(glob) {
  let pattern = '';
  for (let i = 0; i < glob.length; i += 1) {
    const char = glob[i];
    if (char === '*' && glob[i + 1] === '*') {
      pattern += '.*';
      i += 1;
      if (glob[i + 1] === '/') i += 1;
    } else if (char === '*') {
      pattern += '[^/]*';
    } else if (char === '?') {
      pattern += '[^/]';
    } else {
      pattern += char.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    }
  }
  return new RegExp(`^${pattern}$`);
}

export function surfaceMatcher(globs) {
  const patterns = globs.map(globToRegExp);
  return (path) => patterns.some((pattern) => pattern.test(path));
}

const refuse = (reason, extra = {}) => ({ action: 'refuse', reason, ...extra });

async function admitted(github, owner, repo, sha, { attempts, delayMs, sleep, core }) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const runs = await github.paginate(github.rest.actions.listWorkflowRuns, {
      owner, repo, workflow_id: 'cmux-next.yml', event: 'push', branch: SOURCE, head_sha: sha, per_page: 100,
    });
    for (const run of runs) {
      if (run.head_sha !== sha || run.head_branch !== SOURCE || run.event !== 'push') continue;
      if (run.path !== GATE_WORKFLOW) continue;
      if (run.head_repository?.full_name !== `${owner}/${repo}`) continue;
      const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
        owner, repo, run_id: run.id, filter: 'latest', per_page: 100,
      });
      if (jobs.some((job) => job.status === 'completed' && job.name === GATE_JOB && job.conclusion === 'success')) {
        return true;
      }
    }
    if (attempt < attempts) {
      core?.notice?.(`The exact ${GATE_JOB} result is not visible yet; retrying promotion admission (${attempt}/${attempts - 1}).`);
      await sleep(delayMs);
    }
  }
  return false;
}

async function firstParentChain(github, owner, repo, from, to) {
  // Commits from `from` back to (not including) `to` along first parents.
  const chain = [];
  let cursor = from;
  while (cursor !== to) {
    if (chain.length >= MAX_FIRST_PARENT_COMMITS) return null;
    const { data } = await github.rest.repos.getCommit({ owner, repo, ref: cursor, per_page: 100, page: 1 });
    // getCommit pages its file list; read every page (GitHub caps it at 3000).
    let files = data.files || [];
    let last = files.length;
    let page = 2;
    // Keep reading while a page came back full (100, or more if per_page is ignored).
    for (; last >= 100 && page <= 30; page += 1) {
      const { data: more } = await github.rest.repos.getCommit({ owner, repo, ref: cursor, per_page: 100, page });
      last = (more.files || []).length;
      files = files.concat(more.files || []);
    }
    data.files = files;
    data.filesTruncated = files.length >= 3000 || (last >= 100 && page > 30);
    chain.push(data);
    const parent = data.parents?.[0]?.sha;
    if (!parent) return null;
    cursor = parent;
  }
  return chain;
}

async function pushActors(github, owner, repo, chainShas, boundary) {
  // Map each first-parent commit to every actor whose push brought it. The
  // activity API pages with a cursor (Link header), so read it through
  // github.paginate.iterator; stop once every commit has an actor.
  const order = new Map(chainShas.map((sha, index) => [sha, index]));
  const actors = new Map(chainShas.map((sha) => [sha, new Set()]));
  const unresolved = () => chainShas.some((sha) => actors.get(sha).size === 0);
  // Read back to the push that started from the range's base, so an earlier
  // push of the same commits (before a force push) adds its actor too.
  let reachedBoundary = !boundary;
  let pages = 0;
  for await (const response of github.paginate.iterator('GET /repos/{owner}/{repo}/activity', {
    owner, repo, ref: `refs/heads/${SOURCE}`, per_page: 100,
  })) {
    pages += 1;
    for (const event of response.data || []) {
      if (boundary && event.before === boundary) reachedBoundary = true;
      if (!order.has(event.after)) continue;
      // Every chain commit from `after` back to `before` arrived in this push
      // (to the end of the chain when `before` is outside it, a force push).
      for (let index = order.get(event.after); index < chainShas.length; index += 1) {
        const sha = chainShas[index];
        if (sha === event.before) break;
        actors.get(sha).add(event.actor?.login || '');
      }
    }
    if ((!unresolved() && reachedBoundary) || pages >= MAX_ACTIVITY_PAGES) break;
  }
  return actors;
}

async function landersOf(github, owner, repo, commit, actors) {
  const logins = new Set();
  const add = (login) => { if (login && !BOT_LOGINS.has(login)) logins.add(login); };
  add(commit.author?.login);
  add(commit.committer?.login);
  const pushers = actors.get(commit.sha);
  if (!pushers || pushers.size === 0 || pushers.has('')) return null;
  pushers.forEach(add);
  const { data: pulls } = await github.request('GET /repos/{owner}/{repo}/commits/{commit_sha}/pulls', {
    owner, repo, commit_sha: commit.sha,
  });
  for (const pull of pulls || []) {
    if (!pull.merged_at) continue;
    add(pull.user?.login);
    const { data: full } = await github.rest.pulls.get({ owner, repo, pull_number: pull.number });
    add(full.merged_by?.login);
    // Anyone whose commits are in the merged PR counts as a lander too.
    const prCommits = await github.paginate(github.rest.pulls.listCommits, { owner, repo, pull_number: pull.number, per_page: 100 });
    for (const prCommit of prCommits) {
      add(prCommit.author?.login);
      add(prCommit.committer?.login);
    }
  }
  return logins;
}

export async function decide({
  github, owner, repo, sha, surfaceText, core, sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  debounce = false, minIntervalHours = 0, admissionAttempts = 6, admissionDelayMs = 5000, now = () => Date.now(),
}) {
  if (!/^[0-9a-f]{40}$/.test(sha)) return refuse(`promote_nightly_next_sha must be 40 lowercase hex characters, got ${sha}`);

  // G1: on feat-cmux-next.
  const sourceHead = (await github.rest.git.getRef({ owner, repo, ref: `heads/${SOURCE}` })).data.object.sha;
  let onSource;
  try {
    onSource = (await github.rest.repos.compareCommitsWithBasehead({ owner, repo, basehead: `${sha}...${sourceHead}` })).data.status;
  } catch (error) {
    return refuse(`${sha} cannot be compared with ${SOURCE} (${error.status || error.message})`);
  }
  if (onSource !== 'ahead' && onSource !== 'identical') {
    return refuse(`${sha} is not on ${SOURCE} (compare status ${onSource})`);
  }

  // G2: the trusted gate.
  if (!(await admitted(github, owner, repo, sha, { attempts: admissionAttempts, delayMs: admissionDelayMs, sleep, core }))) {
    return refuse(`${sha} has no ${GATE_WORKFLOW} push run on ${SOURCE} in ${owner}/${repo} with a successful "${GATE_JOB}" job`);
  }

  if (debounce && Number.isFinite(minIntervalHours) && minIntervalHours > 0) {
    const { data } = await github.rest.actions.listWorkflowRuns({ owner, repo, workflow_id: 'nightly.yml', branch: TARGET, per_page: 1 });
    const last = data.workflow_runs?.[0];
    if (last) {
      const ageHours = (now() - Date.parse(last.created_at)) / 3_600_000;
      if (ageHours < minIntervalHours) {
        return { action: 'skip', reason: `Debounced: the last ${TARGET} build started ${ageHours.toFixed(2)}h ago (minimum ${minIntervalHours}h).`, sha };
      }
    }
  }

  let current = null;
  try {
    current = (await github.rest.git.getRef({ owner, repo, ref: `heads/${TARGET}` })).data.object.sha;
  } catch (error) {
    if (error.status !== 404) throw error;
  }
  if (current === sha) return { action: 'skip', reason: `${TARGET} is already at ${sha}.`, sha, current };

  let force = false;
  let mergeBase = current;
  if (current) {
    const { data } = await github.rest.repos.compareCommitsWithBasehead({ owner, repo, basehead: `${current}...${sha}` });
    if (data.status === 'diverged') {
      // A hand-made baseline (a feat-cmux-next commit plus patches) may be
      // replaced when the point where it left feat-cmux-next is on
      // feat-cmux-next; `sha` descends from it, so history never moves back.
      const base = data.merge_base_commit?.sha;
      mergeBase = base || null;
      if (base) {
        const { data: baseOnSource } = await github.rest.repos.compareCommitsWithBasehead({ owner, repo, basehead: `${base}...${sourceHead}` });
        force = baseOnSource.status === 'ahead' || baseOnSource.status === 'identical';
      }
    }
    if (data.status !== 'ahead' && !force) {
      return { action: 'skip', reason: `${sha} does not move ${TARGET} forward from ${current} (compare status ${data.status}); nothing promoted.`, sha, current };
    }
  }

  // G3: release surface.
  const matches = surfaceMatcher(parseSurface(surfaceText));
  if (!current) {
    return { action: 'needs-ack', reason: `${TARGET} does not exist; the first promotion needs a release approver`, sha, current, force, surfaceFiles: ['*'], landers: [] };
  }
  const touches = (file) => matches(file.filename) || Boolean(file.previous_filename && matches(file.previous_filename));
  // The compare API lists at most 300 files for the whole range.
  const { data: range } = await github.rest.repos.compareCommitsWithBasehead({ owner, repo, basehead: `${current}...${sha}`, per_page: 1 });
  const rangeFiles = range.files || [];
  // Walk the first-parent history only when it is needed: a range too large
  // for the compare API, or a surface change whose landers must be found.
  let chain = null;
  const walk = async () => {
    chain = chain || (mergeBase ? await firstParentChain(github, owner, repo, sha, mergeBase) : null);
    return chain;
  };
  const commitTouches = (commit) => commit.filesTruncated || (commit.files || []).some(touches);
  let surfaceFiles;
  if (rangeFiles.length < 300) {
    surfaceFiles = [...new Set(rangeFiles.filter(touches).flatMap((file) => [file.filename, file.previous_filename]).filter(Boolean).filter(matches))].sort();
  } else if (!force) {
    // Every changed file was changed by a first-parent commit of the range.
    if (!(await walk())) {
      return refuse(`the range ${current}...${sha} changes 300 or more files and its first-parent history is longer than ${MAX_FIRST_PARENT_COMMITS} commits`);
    }
    surfaceFiles = [...new Set(chain.flatMap((commit) => (commit.files || []).filter(touches).map((file) => file.filename)))].sort();
    if (chain.some((commit) => commit.filesTruncated)) surfaceFiles.push('<a commit with 3000 or more files>');
  } else {
    return refuse(`the replaced baseline ${current} and ${sha} differ in 300 or more files; the change cannot be listed`);
  }
  if (surfaceFiles.length === 0) {
    return { action: 'promote', reason: 'no release surface file changed', sha, current, force, surfaceFiles, landers: [] };
  }
  if (!(await walk())) {
    return refuse(`cannot walk the first-parent history from ${sha} back to ${current} within ${MAX_FIRST_PARENT_COMMITS} commits`);
  }

  // G4: who landed the surface change.
  const touching = chain.filter(commitTouches);
  if (touching.length === 0 && !force) {
    return refuse(`the range changes ${surfaceFiles.join(', ')} but no first-parent commit shows it`);
  }
  const actors = await pushActors(github, owner, repo, chain.map((commit) => commit.sha), mergeBase);
  const landers = new Set();
  const unresolved = [];
  for (const commit of touching) {
    const logins = await landersOf(github, owner, repo, commit, actors);
    if (!logins) unresolved.push(commit.sha);
    else logins.forEach((login) => landers.add(login));
  }
  if (unresolved.length) {
    return refuse(`no push actor found for ${unresolved.join(', ')}; the landers of the release surface change are unknown`, { sha, current, surfaceFiles });
  }
  return {
    action: 'needs-ack',
    reason: `${surfaceFiles.length} release surface file(s) changed`,
    sha, current, force, surfaceFiles, landers: [...landers].sort(),
    touching: touching.map((commit) => commit.sha),
  };
}

export async function approvedBy({ github, owner, repo, runId, environment = ACK_ENVIRONMENT }) {
  const { data } = await github.request('GET /repos/{owner}/{repo}/actions/runs/{run_id}/approvals', { owner, repo, run_id: runId });
  return (data || [])
    .filter((entry) => entry.state === 'approved' && (entry.environments || []).some((env) => env.name === environment))
    .map((entry) => entry.user?.login)
    .filter(Boolean);
}

export function ackDecision({ decision, approvers, triggeringActor, expectedCurrent }) {
  if (decision.action === 'skip') return { ok: true, move: false, reason: decision.reason };
  if (decision.action === 'promote') return { ok: true, move: true, reason: 'no release surface file changed any more' };
  if (decision.action !== 'needs-ack') return { ok: false, reason: decision.reason };
  if (expectedCurrent && decision.current !== expectedCurrent) {
    return { ok: false, reason: `${TARGET} moved from ${expectedCurrent} to ${decision.current} after the approval was requested; request the promotion again` };
  }
  const blocked = new Set([...(decision.landers || []), triggeringActor].filter(Boolean));
  const valid = approvers.filter((login) => !blocked.has(login));
  if (valid.length === 0) {
    return { ok: false, reason: `no approval by a release approver who did not land the range (approvers: ${approvers.join(', ') || 'none'}; landers: ${[...blocked].join(', ')})` };
  }
  return { ok: true, move: true, reason: `approved by ${valid.join(', ')}`, approver: valid[0] };
}

export async function move({ writer, github = writer, owner, repo, decision }) {
  const { sha, current, force } = decision;
  // Compare and swap: refuse when nightly-next moved after the decision.
  let now = null;
  try {
    now = (await github.rest.git.getRef({ owner, repo, ref: `heads/${TARGET}` })).data.object.sha;
  } catch (error) {
    if (error.status !== 404) throw error;
  }
  if (now !== (current || null)) {
    throw new Error(`${TARGET} is at ${now} but the decision was made at ${current}; request the promotion again`);
  }
  if (!current) {
    await writer.rest.git.createRef({ owner, repo, ref: `refs/heads/${TARGET}`, sha });
  } else {
    await writer.rest.git.updateRef({ owner, repo, ref: `heads/${TARGET}`, sha, force: Boolean(force) });
  }
  return `Promoted ${TARGET} to ${sha}; its push run publishes it.`;
}

export function summary(decision) {
  const lines = [
    `### nightly-next promotion: ${decision.action}`,
    '',
    `- SHA: \`${decision.sha || ''}\``,
    `- current nightly-next: \`${decision.current || 'none'}\``,
    `- reason: ${decision.reason}`,
  ];
  if (decision.force) {
    lines.push('- nightly-next is a hand-made baseline that this promotion replaces; the patches it drops are listed only when the compare shows them');
  }
  if (decision.surfaceFiles?.length) {
    lines.push('- release surface files changed:', ...decision.surfaceFiles.map((file) => `  - \`${file}\``));
  }
  if (decision.landers?.length) lines.push(`- landers (cannot approve): ${decision.landers.join(', ')}`);
  if (decision.action === 'needs-ack') {
    lines.push('', `Review the range \`${decision.current}...${decision.sha}\` before you approve the ${ACK_ENVIRONMENT} deployment.`);
  }
  return `${lines.join('\n')}\n`;
}
