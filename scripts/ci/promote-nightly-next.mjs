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
//   G4  for "needs-ack", the landers of every commit in the range (all parents,
//       from the compare API) that touches the surface: the push actor
//       (repository activity, compare before...after of each push), the
//       PR author and merger, and the commit author and committer. With the
//       policy line `@require_non_lander_approver on` the approval must come
//       from someone who is not a lander (ackDecision()); off, any approval in
//       the approval environment counts.
// Anything it cannot establish is a "refuse" (fail closed).
//
// The functions take injected clients so tests drive them with a fake API.

export const SOURCE = 'feat-cmux-next';
export const TARGET = 'nightly-next';
export const GATE_WORKFLOW = '.github/workflows/cmux-next.yml';
export const GATE_JOB = 'cmux-next Release compile (Xcode 26)';
export const ACK_ENVIRONMENT = 'release-surface-ack';
const BOT_LOGINS = new Set(['web-flow', 'github-actions[bot]', 'GitHub']);
const MAX_ACTIVITY_PAGES = 20;

export function parseSurface(text) {
  return text
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#') && !line.startsWith('@'));
}

// Policy lines in the surface file: `@<name> on|off`. Read from main.
// require_non_lander_approver (default off): when on, the approval must come
// from someone who did not land the range and did not start the run. When
// off, any approval in the environment counts (the environment's reviewers
// still decide who can approve).
export function parsePolicy(text) {
  const policy = { require_non_lander_approver: false };
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line.startsWith('@')) continue;
    const match = /^@([a-z_]+)\s+(on|off)$/.exec(line);
    // A typo must not silently leave a rule off: an unknown policy line throws.
    if (!match || !(match[1] in policy)) throw new Error(`unknown policy line in the release surface: ${line}`);
    policy[match[1]] = match[2] === 'on';
  }
  return policy;
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

// The compare API returns at most this many commits per page and files only on
// its first page (at most 300). Anything it cannot list in full is refused.
const COMPARE_PAGE = 100;
const MAX_RANGE_COMMITS = 1000;
const COMMIT_FILE_CAP = 3000;

// One compare request, memoized for the life of a decision: the guard reads
// the same range several times and the job token's quota is shared.
function comparer(github, owner, repo) {
  const cache = new Map();
  return async (basehead, page = 1, perPage = COMPARE_PAGE) => {
    const key = `${basehead}#${page}#${perPage}`;
    if (!cache.has(key)) {
      cache.set(key, github.rest.repos.compareCommitsWithBasehead({ owner, repo, basehead, per_page: perPage, page }).then((r) => r.data));
    }
    return cache.get(key);
  };
}

// Every commit in base...head (all parents, merges included), from the compare
// API's paginated commit list. Returns null when the list cannot be read in full.
async function rangeCommits(compare, base, head) {
  const commits = [];
  let total = null;
  for (let page = 1; page <= MAX_RANGE_COMMITS / COMPARE_PAGE + 1; page += 1) {
    const data = await compare(`${base}...${head}`, page);
    total = data.total_commits;
    const batch = data.commits || [];
    commits.push(...batch);
    if (commits.length >= total || batch.length === 0) break;
  }
  if (typeof total !== 'number' || total > MAX_RANGE_COMMITS) return null;
  if (commits.length !== total || new Set(commits.map((commit) => commit.sha)).size !== total) return null;
  return commits;
}

// The release surface blobs of a commit: path -> blob SHA for every path that
// matches the surface, read from the git trees of the surface's directories
// (an exact content view, no diff API). Returns null when a tree is truncated.
function surfaceDirectories(globs) {
  const dirs = new Set();
  for (const glob of globs) {
    const wildcard = glob.search(/[*?]/);
    const literal = wildcard === -1 ? glob : glob.slice(0, wildcard);
    const dir = literal.includes('/') ? literal.slice(0, literal.lastIndexOf('/')) : '';
    dirs.add(dir);
  }
  const sorted = [...dirs].sort((x, y) => x.length - y.length);
  return sorted.filter((dir, index) => !sorted.slice(0, index).some((parent) => parent === '' || dir.startsWith(`${parent}/`)));
}

async function surfaceBlobs(github, owner, repo, commitSha, dirs, matches) {
  const { data: commit } = await github.rest.git.getCommit({ owner, repo, commit_sha: commitSha });
  const blobs = new Map();
  for (const dir of dirs) {
    let tree = commit.tree.sha;
    let found = true;
    for (const part of dir ? dir.split('/') : []) {
      const { data } = await github.rest.git.getTree({ owner, repo, tree_sha: tree });
      if (data.truncated) return null;
      const entry = (data.tree || []).find((item) => item.path === part && item.type === 'tree');
      if (!entry) { found = false; break; }
      tree = entry.sha;
    }
    if (!found) continue;
    const { data } = await github.rest.git.getTree({ owner, repo, tree_sha: tree, recursive: 'true' });
    if (data.truncated) return null;
    for (const item of data.tree || []) {
      if (item.type !== 'blob' && item.type !== 'commit') continue;
      const path = dir ? `${dir}/${item.path}` : item.path;
      if (matches(path)) blobs.set(path, `${item.mode}:${item.sha}`);
    }
  }
  return blobs;
}

// One commit with its full file list. Returns null when GitHub truncates it.
async function commitWithFiles(github, owner, repo, sha) {
  const { data } = await github.rest.repos.getCommit({ owner, repo, ref: sha, per_page: 100, page: 1 });
  let files = data.files || [];
  let last = files.length;
  for (let page = 2; last >= 100 && page <= COMMIT_FILE_CAP / 100 + 1; page += 1) {
    const { data: more } = await github.rest.repos.getCommit({ owner, repo, ref: sha, per_page: 100, page });
    last = (more.files || []).length;
    files = files.concat(more.files || []);
  }
  if (files.length >= COMMIT_FILE_CAP) return null;
  return { ...data, files };
}

// Map each commit to every actor whose push brought it: the commits a push
// brought are compare(before...after). The activity API pages with a cursor.
async function pushActors(github, owner, repo, compare, wanted, rangeSet, boundary) {
  const actors = new Map([...wanted].map((sha) => [sha, new Set()]));
  const unresolved = () => [...wanted].some((sha) => actors.get(sha).size === 0);
  let reachedBoundary = !boundary;
  let pages = 0;
  for await (const response of github.paginate.iterator('GET /repos/{owner}/{repo}/activity', {
    owner, repo, ref: `refs/heads/${SOURCE}`, per_page: 100,
  })) {
    pages += 1;
    for (const event of response.data || []) {
      if (boundary && event.before === boundary) reachedBoundary = true;
      if (!rangeSet.has(event.after)) continue;
      if (!unresolved() && reachedBoundary) continue;
      // A branch creation (before = zeros) credits only its tip; the other
      // commits stay unresolved, which the caller treats as unknown.
      let brought = [event.after];
      if (!/^0+$/.test(event.before || '')) {
        let range = null;
        try { range = await rangeCommits(compare, event.before, event.after); } catch { range = null; }
        if (!range) {
          // This push's commits cannot be listed: its actor is unknown for
          // every wanted commit, so no lander can drop out of the list.
          for (const sha of wanted) actors.get(sha).add('');
          continue;
        }
        brought = brought.concat(range.map((commit) => commit.sha));
      }
      for (const sha of brought) {
        if (actors.has(sha)) actors.get(sha).add(event.actor?.login || '');
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

  // The current nightly-next must be an ancestor of the target: compare
  // status "ahead". "identical" was handled above; anything else refuses.
  const compare = comparer(github, owner, repo);
  if (current) {
    const data = await compare(`${current}...${sha}`);
    if (data.status !== 'ahead') {
      return refuse(`${current} (${TARGET}) is not an ancestor of ${sha} (compare status ${data.status}); nothing promoted`, { sha, current });
    }
  }

  // G3: release surface.
  let policy;
  try {
    policy = parsePolicy(surfaceText);
  } catch (error) {
    return refuse(error.message);
  }
  const matches = surfaceMatcher(parseSurface(surfaceText));
  if (!current) {
    return { action: 'needs-ack', reason: `${TARGET} does not exist; the first promotion needs a release approver`, sha, current, surfaceFiles: ['*'], landers: [] };
  }
  const touches = (file) => matches(file.filename) || Boolean(file.previous_filename && matches(file.previous_filename));

  // Every commit in the range, merges and second parents included.
  const commits = await rangeCommits(compare, current, sha);
  if (!commits) {
    return refuse(`the range ${current}...${sha} has more than ${MAX_RANGE_COMMITS} commits or the compare API did not list them all`, { sha, current });
  }
  const rangeSet = new Set(commits.map((commit) => commit.sha));

  // G3 from the trees, not from a diff API: compare every surface path's blob
  // in nightly-next and in the target. This is exact for any history shape
  // (a merge that drops the old tip's change included) and has no file cap.
  const dirs = surfaceDirectories(parseSurface(surfaceText));
  const before = await surfaceBlobs(github, owner, repo, current, dirs, matches);
  const after = await surfaceBlobs(github, owner, repo, sha, dirs, matches);
  if (!before || !after) {
    return refuse(`a release surface directory's git tree is truncated; the surface of ${current}...${sha} cannot be compared`, { sha, current });
  }
  const surfaceFiles = [...new Set([...before.keys(), ...after.keys()])].filter((path) => before.get(path) !== after.get(path)).sort();
  if (surfaceFiles.length === 0) {
    return { action: 'promote', reason: 'no release surface file changed', sha, current, surfaceFiles, landers: [] };
  }

  // G4: who landed the surface change: the commits whose own diff touches the
  // surface (a commit whose file list GitHub truncates counts as touching).
  // A change no single commit shows (a merge that kept the other side's
  // version) is attributed to the range's merge commits.
  const detailed = [];
  for (const commit of commits) {
    const full = await commitWithFiles(github, owner, repo, commit.sha);
    detailed.push(full || { sha: commit.sha, truncated: true, files: [], parents: commit.parents || [] });
  }
  const touching = detailed.filter((commit) => commit.truncated || commit.files.some(touches));
  // A surface path that no commit's own diff lists changed through a merge
  // resolution: every merge commit in the range is a lander for it.
  const listed = new Set(touching.flatMap((commit) => commit.files.flatMap((file) => [file.filename, file.previous_filename]).filter(Boolean)));
  const anyTruncated = touching.some((commit) => commit.truncated);
  if (!anyTruncated && surfaceFiles.some((path) => !listed.has(path))) {
    for (const commit of detailed) {
      if ((commit.parents || []).length > 1 && !touching.includes(commit)) touching.push(commit);
    }
  }
  if (touching.length === 0) {
    return refuse(`the surface of ${current}...${sha} changed (${surfaceFiles.join(', ')}) but no commit in the range accounts for it`, { sha, current, surfaceFiles });
  }
  const actors = await pushActors(github, owner, repo, compare, new Set(touching.map((commit) => commit.sha)), rangeSet, current);
  const landers = new Set();
  const unresolved = [];
  for (const commit of touching) {
    const logins = await landersOf(github, owner, repo, commit, actors);
    if (!logins) unresolved.push(commit.sha);
    else logins.forEach((login) => landers.add(login));
  }
  if (unresolved.length && policy.require_non_lander_approver) {
    return refuse(`no push actor found for ${unresolved.join(', ')}; the landers of the release surface change are unknown`, { sha, current, surfaceFiles });
  }
  return {
    action: 'needs-ack',
    reason: `${surfaceFiles.length} release surface file(s) changed`,
    sha, current, surfaceFiles, landers: [...landers].sort(),
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

export function ackDecision({ decision, approvers, triggeringActor, expectedCurrent, requireNonLander = false }) {
  if (decision.action === 'skip') return { ok: true, move: false, reason: decision.reason };
  if (decision.action === 'promote') return { ok: true, move: true, reason: 'no release surface file changed any more' };
  if (decision.action !== 'needs-ack') return { ok: false, reason: decision.reason };
  if (expectedCurrent && decision.current !== expectedCurrent) {
    return { ok: false, reason: `${TARGET} moved from ${expectedCurrent} to ${decision.current} after the approval was requested; request the promotion again` };
  }
  if (!requireNonLander) {
    if (approvers.length === 0) return { ok: false, reason: 'no approval in the approval environment' };
    return { ok: true, move: true, reason: `approved by ${approvers.join(', ')} (lander rule off)`, approver: approvers[0] };
  }
  const blocked = new Set([...(decision.landers || []), triggeringActor].filter(Boolean));
  const valid = approvers.filter((login) => !blocked.has(login));
  if (valid.length === 0) {
    return { ok: false, reason: `no approval by a release approver who did not land the range (approvers: ${approvers.join(', ') || 'none'}; landers: ${[...blocked].join(', ')})` };
  }
  return { ok: true, move: true, reason: `approved by ${valid.join(', ')}`, approver: valid[0] };
}

export async function move({ writer, github = writer, owner, repo, decision }) {
  const { sha, current } = decision;
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
    // Never a force update: GitHub refuses a non-fast-forward move as well.
    await writer.rest.git.updateRef({ owner, repo, ref: `heads/${TARGET}`, sha, force: false });
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
  if (decision.surfaceFiles?.length) {
    lines.push('- release surface files changed:', ...decision.surfaceFiles.map((file) => `  - \`${file}\``));
  }
  if (decision.landers?.length) lines.push(`- landers (cannot approve): ${decision.landers.join(', ')}`);
  if (decision.action === 'needs-ack') {
    lines.push('', `Review the range \`${decision.current}...${decision.sha}\` before you approve the ${ACK_ENVIRONMENT} deployment.`);
  }
  return `${lines.join('\n')}\n`;
}
