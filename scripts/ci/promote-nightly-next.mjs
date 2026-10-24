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
// A train commit (nightly-next-train.yml; docs/ci/nightly-next-train.md) is
// checked by G1'/G2' in place of G1/G2:
//   G1' its second parent is on feat-cmux-next, and its tree is that parent
//       with exactly its `Nightly-Train-Revert:` reverts, which the injected
//       verifyTrain() rebuilds (scripts/ci/nightly_next_train.py verify);
//   G2' a nightly-next-train.yml dispatch run of this repository on a
//       nightly-train/* ref for that exact SHA has a successful
//       "nightly-next train Release compile" job;
// and its first parent must be the current nightly-next. G3/G4 are unchanged.
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

// A tip can still be compiling while an older commit has already finished its
// exact Release compile. Keep the safety gate, but promote the newest green
// source commit instead of waiting for the tip. This scan is bounded by the
// workflow-run API page and only accepts same-repository push runs on the
// source branch with the exact gate job green.
async function newestGreenSourceCommit(github, owner, repo, targetSha, excludeSha) {
  const runs = await github.paginate(github.rest.actions.listWorkflowRuns, {
    owner, repo, workflow_id: 'cmux-next.yml', event: 'push', branch: SOURCE, per_page: 100,
  });
  const ordered = [...runs].sort((a, b) => Date.parse(b.created_at || 0) - Date.parse(a.created_at || 0) || Number(b.id) - Number(a.id));
  const green = [];
  for (const run of ordered) {
    const candidate = run.head_sha;
    if (!candidate || candidate === excludeSha || run.event !== 'push' || run.head_branch !== SOURCE ||
        run.path !== GATE_WORKFLOW || run.head_repository?.full_name !== `${owner}/${repo}`) continue;
    let lineage;
    try {
      lineage = (await github.rest.repos.compareCommitsWithBasehead({
        owner, repo, basehead: `${candidate}...${targetSha}`,
      })).data.status;
    } catch {
      continue;
    }
    if (lineage !== 'ahead' && lineage !== 'identical') continue;
    const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
      owner, repo, run_id: run.id, filter: 'latest', per_page: 100,
    });
    if (jobs.some((job) => job.status === 'completed' && job.name === GATE_JOB && job.conclusion === 'success')) green.push(candidate);
  }
  if (green.length === 0) return null;
  // Run creation time is not commit order: reruns and delayed workflow runs
  // can make an older commit appear newer. Prefer the candidate that is a
  // descendant of every other green candidate; keep the first candidate only
  // when GitHub cannot relate two merge-shaped histories.
  let newest = green[0];
  for (const candidate of green.slice(1)) {
    try {
      const relation = (await github.rest.repos.compareCommitsWithBasehead({
        owner, repo, basehead: `${newest}...${candidate}`,
      })).data.status;
      if (relation === 'ahead') newest = candidate;
    } catch {
      // The candidate was already proven on the source branch; leave the
      // deterministic run-order winner when the pairwise comparison fails.
    }
  }
  return newest;
}

// A train commit (scripts/ci/nightly_next_train.py): two parents, the
// nightly-next head it was made on and a feat-cmux-next tip, and the
// `Nightly-Train: v1` trailer. Anything else (or an unreadable commit) is not a
// train commit and goes through G1/G2, which refuse what they cannot place.
export const TRAIN_TRAILER = 'Nightly-Train: v1';
export const TRAIN_WORKFLOW = '.github/workflows/nightly-next-train.yml';
export const TRAIN_GATE_JOB = 'nightly-next train Release compile';
export const TRAIN_REF_PREFIX = 'nightly-train/';

export async function readTrainCommit(github, owner, repo, sha) {
  let data;
  try {
    ({ data } = await github.rest.git.getCommit({ owner, repo, commit_sha: sha }));
  } catch {
    return null;
  }
  const lines = String(data?.message || '').split('\n').map((line) => line.trim());
  if (!lines.includes(TRAIN_TRAILER) || (data.parents || []).length !== 2) return null;
  return { firstParent: data.parents[0].sha, tip: data.parents[1].sha };
}

// verifyTrain for decide(): run the train script's `verify --fetch` in the
// guard's checkout (main's copy of the script) and read its JSON verdict.
export function trainVerifier(script, { cwd = process.cwd(), spawn } = {}) {
  return async (sha) => {
    const run = spawn || (await import('node:child_process')).spawnSync;
    const proc = run('python3', [script, 'verify', '--fetch', '--commit', sha], { cwd, encoding: 'utf8', timeout: 600000 });
    let verdict = null;
    try {
      verdict = JSON.parse(String(proc.stdout || '').trim().split('\n').pop());
    } catch {
      verdict = null;
    }
    if (!verdict || typeof verdict.ok !== 'boolean') {
      throw new Error(`verify exited ${proc.status}: ${String(proc.stderr || '').trim().slice(0, 400)}`);
    }
    return { ok: verdict.ok && proc.status === 0, reason: verdict.reason };
  };
}

async function admittedTrain(github, owner, repo, sha, { attempts, delayMs, sleep, core }) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const runs = await github.paginate(github.rest.actions.listWorkflowRuns, {
      owner, repo, workflow_id: 'nightly-next-train.yml', event: 'workflow_dispatch', head_sha: sha, per_page: 100,
    });
    for (const run of runs) {
      if (run.head_sha !== sha || run.event !== 'workflow_dispatch') continue;
      if (run.path !== TRAIN_WORKFLOW || !String(run.head_branch || '').startsWith(TRAIN_REF_PREFIX)) continue;
      if (run.head_repository?.full_name !== `${owner}/${repo}`) continue;
      const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
        owner, repo, run_id: run.id, filter: 'latest', per_page: 100,
      });
      if (jobs.some((job) => job.status === 'completed' && job.name === TRAIN_GATE_JOB && job.conclusion === 'success')) {
        return true;
      }
    }
    if (attempt < attempts) {
      core?.notice?.(`The ${TRAIN_GATE_JOB} result of ${sha} is not visible yet; retrying (${attempt}/${attempts - 1}).`);
      await sleep(delayMs);
    }
  }
  return false;
}

// The compare API returns at most this many commits per page and files only on
// its first page (at most 300). It pages through ranges of any length, so the
// guard reads every page; anything it cannot list in full is refused.
const COMPARE_PAGE = 100;
// A budget, not a history limit: G4 reads each commit of the range once, and
// the job token allows 15,000 requests an hour. A range over this budget is
// refused (fail closed) instead of running the token dry halfway through.
// It was 1000 until 2026-10-20, when a 1782-commit range (1549 of them from
// one merge) had no smaller step and blocked every nightly (run 39407965731).
const MAX_RANGE_COMMITS = 10000;
const COMMIT_FILE_CAP = 3000;
// Per-commit reads in flight at once. One by one, a 1782-commit range ran the
// decide job past its 10-minute limit (run 39410930509); 16 stays well under
// GitHub's secondary rate limit for concurrent requests.
const READ_CONCURRENCY = 16;

// GitHub answers a read with a 5xx now and then (run 39413299148). A read
// that fails that way is tried again after a short wait, up to this many
// times in all; a 4xx or a lasting 5xx still throws (fail closed).
const READ_ATTEMPTS = 4;

async function retrying(fn, sleep) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await fn();
    } catch (error) {
      if (!(error?.status >= 500) || attempt >= READ_ATTEMPTS) throw error;
      await sleep(1000 * 2 ** attempt);
    }
  }
}

// fn over items with at most `limit` calls in flight; results in input order.
async function mapLimit(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await fn(items[index], index);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

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
  const first = await compare(`${base}...${head}`, 1);
  const total = first.total_commits;
  if (typeof total !== 'number' || total > MAX_RANGE_COMMITS) return null;
  // Page count from the first page's total; every page is read, and the
  // pages must add up to exactly that many distinct commits.
  const pages = Math.max(1, Math.ceil(total / COMPARE_PAGE));
  const commits = [...(first.commits || [])];
  for (let page = 2; page <= pages; page += 1) {
    const data = await compare(`${base}...${head}`, page);
    if (data.total_commits !== total) return null;
    const batch = data.commits || [];
    if (batch.length === 0) break;
    commits.push(...batch);
  }
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
  // GitHub leaves these users null when an email is not linked to an account.
  // Silently omitting that identity would let a release approver approve their
  // own commit while the non-lander policy appears to be enabled.
  if (!commit.author?.login || !commit.committer?.login) return null;
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
    if (!pull.user?.login) return null;
    add(pull.user?.login);
    const { data: full } = await github.rest.pulls.get({ owner, repo, pull_number: pull.number });
    if (!full.merged_by?.login) return null;
    add(full.merged_by?.login);
    // Anyone whose commits are in the merged PR counts as a lander too.
    const prCommits = await github.paginate(github.rest.pulls.listCommits, { owner, repo, pull_number: pull.number, per_page: 100 });
    for (const prCommit of prCommits) {
      if (!prCommit.author?.login || !prCommit.committer?.login) return null;
      add(prCommit.author?.login);
      add(prCommit.committer?.login);
    }
  }
  return logins;
}

export async function decide({
  github, owner, repo, sha, surfaceText, core, sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  debounce = false, minIntervalHours = 0, admissionAttempts = 6, admissionDelayMs = 5000, now = () => Date.now(),
  verifyTrain = null,
}) {
  if (!/^[0-9a-f]{40}$/.test(sha)) return refuse(`promote_nightly_next_sha must be 40 lowercase hex characters, got ${sha}`);

  const sourceHead = (await github.rest.git.getRef({ owner, repo, ref: `heads/${SOURCE}` })).data.object.sha;
  const onSourceStatus = async (commit) => {
    try {
      return (await github.rest.repos.compareCommitsWithBasehead({ owner, repo, basehead: `${commit}...${sourceHead}` })).data.status;
    } catch (error) {
      return { error: `${commit} cannot be compared with ${SOURCE} (${error.status || error.message})` };
    }
  };
  const train = await readTrainCommit(github, owner, repo, sha);
  let trainFirstParent = null;
  if (train) {
    // G1' (docs/ci/nightly-next-train.md): the second parent is on
    // feat-cmux-next and the tree is that parent with exactly the listed
    // reverts, which the verifier rebuilds itself (it trusts no list).
    const status = await onSourceStatus(train.tip);
    if (status?.error) return refuse(status.error);
    if (status !== 'ahead' && status !== 'identical') {
      return refuse(`train commit ${sha}: its second parent ${train.tip} is not on ${SOURCE} (compare status ${status})`);
    }
    if (typeof verifyTrain !== 'function') return refuse(`train commit ${sha}: no train tree verifier in this job; nothing promoted`);
    let verdict;
    try {
      verdict = await verifyTrain(sha);
    } catch (error) {
      return refuse(`train commit ${sha}: the tree check failed to run (${error.message})`);
    }
    if (!verdict?.ok) return refuse(`train commit ${sha}: ${verdict?.reason || 'its tree is not its second parent minus its listed reverts'}`);
    // G2': a green Release compile of this exact commit in nightly-next-train.yml.
    if (!(await admittedTrain(github, owner, repo, sha, { attempts: admissionAttempts, delayMs: admissionDelayMs, sleep, core }))) {
      return refuse(`train commit ${sha} has no ${TRAIN_WORKFLOW} dispatch run on a ${TRAIN_REF_PREFIX}* ref in ${owner}/${repo} with a successful "${TRAIN_GATE_JOB}" job`);
    }
    trainFirstParent = train.firstParent;
  } else {
    // G1: on feat-cmux-next.
    const onSource = await onSourceStatus(sha);
    if (onSource?.error) return refuse(onSource.error);
    if (onSource !== 'ahead' && onSource !== 'identical') {
      return refuse(`${sha} is not on ${SOURCE} (compare status ${onSource})`);
    }

    // G2: the trusted gate. If the requested tip is still compiling, use the
    // newest earlier source commit whose exact Release compile is already green.
    if (!(await admitted(github, owner, repo, sha, { attempts: admissionAttempts, delayMs: admissionDelayMs, sleep, core }))) {
      const fallback = await newestGreenSourceCommit(github, owner, repo, sha, sha);
      if (!fallback) {
        return refuse(`${sha} has no ${GATE_WORKFLOW} push run on ${SOURCE} in ${owner}/${repo} with a successful "${GATE_JOB}" job, and no earlier green source commit was found`);
      }
      core?.notice?.(`The requested tip ${sha} is not Release-green; promoting the newest green source commit ${fallback}.`);
      sha = fallback;
      if (!(await admitted(github, owner, repo, sha, { attempts: 1, delayMs: 0, sleep, core }))) {
        return refuse(`${sha} lost its successful "${GATE_JOB}" result while promotion was being decided`);
      }
    }
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
  if (trainFirstParent !== null && trainFirstParent !== current) {
    return refuse(`train commit ${sha} was made on ${trainFirstParent}, but ${TARGET} is at ${current || 'nothing'}; the next train starts from the new head`, { sha, current });
  }

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
    if (policy.require_non_lander_approver) {
      return refuse(`${TARGET} does not exist; the commit-author exclusion cannot establish a bounded promotion range`, {
        sha, current, surfaceFiles: ['*'],
      });
    }
    return { action: 'needs-ack', reason: `${TARGET} does not exist; the first promotion needs a release approver`, sha, current, surfaceFiles: ['*'], landers: [] };
  }
  const touches = (file) => matches(file.filename) || Boolean(file.previous_filename && matches(file.previous_filename));

  // Every commit in the range, merges and second parents included.
  const commits = await rangeCommits(compare, current, sha);
  if (!commits) {
    return refuse(`the range ${current}...${sha} has more than ${MAX_RANGE_COMMITS} commits (the per-commit read budget) or the compare API did not list them all`, { sha, current });
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
  const detailed = await mapLimit(commits, READ_CONCURRENCY, async (commit) => {
    const full = await retrying(() => commitWithFiles(github, owner, repo, commit.sha), sleep);
    return full || { sha: commit.sha, truncated: true, files: [], parents: commit.parents || [] };
  });
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
  const landerSets = await mapLimit(touching, READ_CONCURRENCY, (commit) => retrying(() => landersOf(github, owner, repo, commit, actors), sleep));
  touching.forEach((commit, index) => {
    const logins = landerSets[index];
    if (!logins) unresolved.push(commit.sha);
    else logins.forEach((login) => landers.add(login));
  });
  if (unresolved.length && policy.require_non_lander_approver) {
    return refuse(`an author, committer, pull-request lander, or push actor is unknown for ${unresolved.join(', ')}; the landers of the release surface change cannot be established`, { sha, current, surfaceFiles });
  }
  return {
    action: 'needs-ack',
    reason: `${surfaceFiles.length} release surface file(s) changed`,
    sha, current, surfaceFiles, landers: [...landers].sort(),
    touching: touching.map((commit) => commit.sha),
  };
}

// The job that waits for the release-surface-ack approval
// (await-release-surface-ack in nightly.yml) is named after its decision, so a
// later request can read what an earlier one waits to promote and from where.
// Keep this pattern and the job's `name:` in nightly.yml in step.
const WAITER_NAME = /^nightly-next promotion ([0-9a-f]{40}) from ([0-9a-f]{40}|none)$/;
const WAITER_RUN_STATUSES = ['waiting', 'queued', 'in_progress'];

// Every other promotion request on main whose await-release-surface-ack job has
// not finished: { runId, sha, current, status }.
export async function pendingPromotions({ github, owner, repo, runId }) {
  const pending = [];
  const seen = new Set();
  for (const status of WAITER_RUN_STATUSES) {
    const { data } = await github.rest.actions.listWorkflowRuns({
      owner, repo, workflow_id: 'nightly.yml', event: 'workflow_dispatch', branch: 'main', status, per_page: 50,
    });
    for (const run of data.workflow_runs || []) {
      if (run.id === runId || seen.has(run.id)) continue;
      seen.add(run.id);
      const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
        owner, repo, run_id: run.id, filter: 'latest', per_page: 100,
      });
      for (const job of jobs) {
        const match = WAITER_NAME.exec(job.name || '');
        if (!match || job.status === 'completed') continue;
        pending.push({ runId: run.id, sha: match[1], current: match[2] === 'none' ? null : match[2], status: job.status });
      }
    }
  }
  return pending;
}

// The promote job runs in one concurrency group (nightly-next-promote) without
// cancel-in-progress, so there is one writer. GitHub keeps only one waiting job
// in that group and cancels it when another request arrives, so a late request
// for an older commit can evict the waiting request for a newer one. Each
// promotion request's run title names its commit (nightly.yml `run-name`); keep
// REQUEST_TITLE and that expression in step. QUEUE_EVICTED is the annotation
// GitHub leaves on an evicted job; a request a person cancelled gets a
// different one and stays cancelled.
const REQUEST_TITLE = /^Promote nightly-next to ([0-9a-f]{40})$/;
const QUEUE_EVICTED = 'Canceling since a higher priority waiting request for nightly-next-promote exists';
const PROMOTE_JOB = 'promote-nightly-next';
const EVICTED_MAX_AGE_MS = 24 * 3_600_000;

// The promotion requests on main that GitHub cancelled in the promote queue in
// the last day (the newest page of cancelled dispatch runs): { runId, sha,
// status: 'evicted' }. Reading the annotation needs `checks: read`.
export async function evictedPromotions({ github, owner, repo, runId, now = () => Date.now(), warn = () => {} }) {
  const { data } = await github.rest.actions.listWorkflowRuns({
    owner, repo, workflow_id: 'nightly.yml', event: 'workflow_dispatch', branch: 'main', status: 'cancelled', per_page: 30,
  });
  const evicted = [];
  for (const run of data.workflow_runs || []) {
    const sha = REQUEST_TITLE.exec(run.display_title || '')?.[1];
    if (!sha || run.id === runId || evicted.some((other) => other.sha === sha)) continue;
    if (now() - Date.parse(run.created_at) > EVICTED_MAX_AGE_MS) continue;
    const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
      owner, repo, run_id: run.id, filter: 'latest', per_page: 100,
    });
    const job = jobs.find((candidate) => candidate.name === PROMOTE_JOB);
    if (!job || job.conclusion !== 'cancelled') continue;
    // One run's unreadable annotations (a 403 or 404) skip that run only; the
    // other evicted requests, the ones this scan exists to keep, still count.
    let annotations;
    try {
      ({ data: annotations } = await github.rest.checks.listAnnotations({ owner, repo, check_run_id: job.id, per_page: 100 }));
    } catch (error) {
      if (error.status !== 403 && error.status !== 404) throw error;
      warn(`Could not read whether promotion request run ${run.id} was cancelled in the promote queue (${error.status}); skipping it.`);
      continue;
    }
    if ((annotations || []).some((annotation) => annotation.message === QUEUE_EVICTED)) {
      evicted.push({ runId: run.id, sha, status: 'evicted' });
    }
  }
  return evicted;
}

// Newest request wins. A request is cheap to repeat but an approval is not, and
// requests arrive out of order (an older commit's Release compile or cmux-tui
// tree can finish after a newer one's). Before deciding, read the requests that
// wait for (or just got) the release-surface-ack approval:
// - when one of them was decided against the current nightly-next and either
//   targets a commit that contains this request's commit or is already
//   approved (its wait job runs), it stays and this request steps aside
//   ("superseded"): that approval promotes everything here, or is about to move
//   nightly-next, and the next request asks again;
// - otherwise this request decides the newest commit among its own and theirs
//   that is not refused (a later request never moves nightly-next to less than
//   a waiting one), and its await-release-surface-ack job, in the shared
//   cancel-in-progress group, cancels the older waiters. A waiter decided
//   against an older nightly-next is dead (ackDecision refuses it), so it never
//   makes this request step aside.
// - requests GitHub evicted from the promote queue (evictedPromotions) count
//   like dead waiters: a newer evicted commit is decided before this request's
//   own, through the same decide() guard, and a refused one falls back to the
//   next newest. It shares this request's debounce. An error reading them
//   leaves a warning and decides without them.
// The scan runs again after deciding, because the previous request's wait job
// is named only a few seconds after its decide job ends. If the scan fails,
// `scanFailed` is set and the workflow waits in a per-run group, which cancels
// nothing (the behavior before this rule). A waiter whose commit cannot be
// compared is skipped.
async function scanWaiters({ github, core, owner, repo, sha, runId, now }) {
  const pending = await pendingPromotions({ github, owner, repo, runId });
  let evicted = [];
  try {
    evicted = await evictedPromotions({ github, owner, repo, runId, now, warn: (message) => core?.warning?.(message) });
  } catch (error) {
    core?.warning?.(`Could not read the promotion requests cancelled in the promote queue (${error.status || error.message}); deciding without them.`);
  }
  let current = null;
  try {
    current = (await github.rest.git.getRef({ owner, repo, ref: `heads/${TARGET}` })).data.object.sha;
  } catch (error) {
    if (error.status !== 404) throw error;
  }
  const live = pending.filter((waiter) => waiter.current === current);
  // Commits that contain the request's commit, newest first.
  const containing = [];
  for (const waiter of [...pending, ...evicted]) {
    if (waiter.sha === sha || containing.some((other) => other.sha === waiter.sha)) continue;
    let status;
    try {
      status = (await github.rest.repos.compareCommitsWithBasehead({ owner, repo, basehead: `${sha}...${waiter.sha}` })).data.status;
    } catch (error) {
      core?.notice?.(`Skipping the ${waiter.status === 'evicted' ? 'evicted' : 'waiting'} request for ${waiter.sha} (run ${waiter.runId}): it cannot be compared with ${sha} (${error.status || error.message}).`);
      continue;
    }
    if (status !== 'ahead') continue;
    let at = containing.length;
    for (let i = 0; i < containing.length; i += 1) {
      const order = (await github.rest.repos.compareCommitsWithBasehead({ owner, repo, basehead: `${containing[i].sha}...${waiter.sha}` })).data.status;
      if (order === 'ahead') { at = i; break; }
    }
    containing.splice(at, 0, waiter);
  }
  const keep = live.find((waiter) => waiter.sha === sha || waiter.status === 'in_progress' || containing.some((other) => other.sha === waiter.sha && other.runId === waiter.runId));
  return { current, keep, candidates: containing.map((waiter) => waiter.sha) };
}

export async function decideNewest({ github, core, owner, repo, sha, runId, ...rest }) {
  const superseded = (keep, current) => ({
    action: 'superseded',
    reason: `run ${keep.runId} already waits to promote ${keep.sha} from ${current || 'nothing'}${keep.status === 'in_progress' ? ' and is approved' : `, which contains ${sha}`}; that request stays`,
    sha: keep.sha, current,
  });
  let decision = null;
  let seen = new Set();
  for (let round = 0; round < 2; round += 1) {
    let scan;
    try {
      scan = await scanWaiters({ github, core, owner, repo, sha, runId, now: rest.now });
    } catch (error) {
      core?.warning?.(`Could not read the other nightly-next promotion requests (${error.status || error.message}); deciding ${sha} without cancelling them.`);
      return { decision: decision || await decide({ github, core, owner, repo, sha, ...rest }), requested: sha, scanFailed: true };
    }
    if (scan.keep) return { decision: superseded(scan.keep, scan.current), requested: sha, scanFailed: false };
    const order = [...scan.candidates, sha];
    // Round two re-decides only when a waiter commit appeared since round one.
    if (decision && order.every((target) => seen.has(target))) break;
    seen = new Set(order);
    decision = null;
    for (const target of order) {
      if (target !== sha) core?.notice?.(`A waiting or evicted request targets ${target}, which contains ${sha}; deciding ${target}.`);
      const attempt = await decide({ github, core, owner, repo, sha: target, ...rest });
      if (attempt.action !== 'refuse' || target === sha) { decision = attempt; break; }
      core?.notice?.(`${target} is refused (${attempt.reason}); trying the next commit.`);
    }
  }
  return { decision, requested: sha, scanFailed: false };
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
