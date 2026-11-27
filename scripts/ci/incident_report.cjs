'use strict';
// A workflow's own failure report (an incident issue, a comment on it, closing it) must outlive an exhausted
// GitHub token. Runs 45548650589 and 45551813915 (2026-11-25) failed their nightly, then the report itself died on
// "API rate limit exceeded for installation" (403, core 0 of 5000), so about ten failed nightlies paged nobody.
//
// What a reporter gets here, in this order, for every request:
//   1. the job's GITHUB_TOKEN (the repository's Actions installation);
//   2. each spare App token (.github/actions/spare-issue-tokens: cmux-bot, glaeda-route), each its own
//      installation and its own hourly budget, for reads and writes alike;
//   3. upsert and close only: the same issue write through GraphQL, whose budget is separate from REST's core;
//   4. after every token is dry, a wait for the earliest reset (Retry-After, else x-ratelimit-reset), bounded by
//      the caller's deadline, then all of it again;
//   5. past the deadline: the report as an ::error annotation and in the job summary (the runner writes both,
//      with no API call), and the step fails, so the run still says what broke.
//
// From actions/github-script: const ir = require(`${process.env.GITHUB_WORKSPACE}/scripts/ci/incident_report.cjs`);
//   ir.arm(github, { core, getOctokit, spares: [process.env.CMUX_BOT_TOKEN, process.env.ROUTE_TOKEN] });
//   await ir.upsertIncident({ github, core, context, label, title, body });
// Test: node --test tests/incident_report.test.cjs (ci-guards.yml, preflight).

const DEFAULT_DEADLINE_MS = 40 * 60 * 1000;
const MIN_WAIT_MS = 5000;
const MAX_WAIT_MS = 61 * 60 * 1000;

function headersOf(error) {
  return (error && error.response && error.response.headers) || {};
}

// A primary or secondary rate limit: 403/429 with no calls left, a Retry-After, or GitHub's rate limit message.
// GraphQL's own limit answers 200 with a RATE_LIMITED error, or 403.
function isRateLimited(error) {
  if (!error) return false;
  const status = error.status;
  const headers = headersOf(error);
  const message = String(error.message || '');
  if ((status === 403 || status === 429) &&
      (headers['x-ratelimit-remaining'] === '0' || headers['retry-after'] !== undefined || /rate limit/i.test(message))) {
    return true;
  }
  const errors = (error.errors || (error.response && error.response.data && error.response.data.errors) || []);
  return Array.isArray(errors) && errors.some((e) => e && (e.type === 'RATE_LIMITED' || /rate limit/i.test(String(e.message || ''))));
}

// Epoch ms when this limit lifts, or 0 when the answer did not say.
function resetAtMs(error, now) {
  const headers = headersOf(error);
  const retryAfter = Number(headers['retry-after']);
  if (Number.isFinite(retryAfter) && retryAfter > 0) return now + retryAfter * 1000;
  const reset = Number(headers['x-ratelimit-reset']);
  if (Number.isFinite(reset) && reset > 0) return reset * 1000 + 2000;
  return 0;
}

function limitedError(error, resetAt) {
  const out = error instanceof Error ? error : new Error(String(error));
  out.incidentResetAt = resetAt;
  return out;
}

// Each spare token as { name, octokit }: tokens that are empty (the mint failed or the App is not set up) drop out.
function spareClients(getOctokit, spares) {
  const names = ['spare-1', 'spare-2', 'spare-3', 'spare-4'];
  return (spares || [])
    .map((entry, i) => (typeof entry === 'string' ? { name: names[i] || `spare-${i + 1}`, token: entry } : entry))
    .filter((entry) => entry && entry.token)
    .map((entry) => ({ name: entry.name, octokit: getOctokit(entry.token) }));
}

// A request the job token was refused for its rate limit goes again on each spare token; any other error is
// unchanged. The error that leaves (every token dry) carries incidentResetAt, the earliest reset seen.
function arm(github, { core, getOctokit, spares = [], now = Date.now }) {
  const clients = spareClients(getOctokit, spares);
  github.incidentSpares = clients;
  if (!github.hook || typeof github.hook.wrap !== 'function') return clients;
  github.hook.wrap('request', async (request, options) => {
    try {
      return await request(options);
    } catch (error) {
      if (!isRateLimited(error)) throw error;
      let resetAt = resetAtMs(error, now());
      for (const spare of clients) {
        try {
          const { headers: { authorization, ...headers } = {}, request: _hooks, ...route } = options;
          const response = await spare.octokit.request({ ...route, headers });
          core.notice(`GitHub API rate limited (${error.status}) on ${options.method} ${options.url}; sent it with the ${spare.name} token`);
          return response;
        } catch (spareError) {
          if (isRateLimited(spareError)) {
            const r = resetAtMs(spareError, now());
            if (r && (!resetAt || r < resetAt)) resetAt = r;
          } else {
            core.warning(`the ${spare.name} token could not send ${options.method} ${options.url} (${spareError && spareError.status}): ${String(spareError && spareError.message).slice(0, 200)}`);
          }
        }
      }
      throw limitedError(error, resetAt);
    }
  });
  return clients;
}

// Run FN; while it fails for a rate limit, wait for the earliest reset and run it again, until DEADLINE_MS from now.
async function withReset(fn, { core, deadlineMs = DEFAULT_DEADLINE_MS, sleep = (ms) => new Promise((r) => setTimeout(r, ms)), now = Date.now } = {}) {
  const deadline = now() + deadlineMs;
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await fn(attempt);
    } catch (error) {
      if (!isRateLimited(error) && error.incidentResetAt === undefined) throw error;
      const left = deadline - now();
      if (left <= 0) throw error;
      const resetAt = error.incidentResetAt || resetAtMs(error, now());
      let waitMs = resetAt ? resetAt - now() : Math.min(60000 * attempt, 300000);
      waitMs = Math.max(MIN_WAIT_MS, Math.min(waitMs, MAX_WAIT_MS, left));
      core.warning(`every token is rate limited; trying the report again in ${Math.round(waitMs / 1000)} s (attempt ${attempt}, ${Math.round(left / 1000)} s left)`);
      await sleep(waitMs);
    }
  }
}

// The job token's GraphQL client, then each spare's: GraphQL's hourly budget is not REST's core one.
function graphqlClients(github) {
  return [{ name: 'job', graphql: github.graphql }, ...(github.incidentSpares || []).map((s) => ({ name: s.name, graphql: s.octokit.graphql }))]
    .filter((c) => typeof c.graphql === 'function');
}

async function viaGraphql(github, core, what, fn) {
  let last;
  for (const client of graphqlClients(github)) {
    try {
      const out = await fn(client.graphql);
      core.notice(`REST was rate limited on every token; ${what} went through GraphQL with the ${client.name} token`);
      return out;
    } catch (error) {
      last = error;
      core.warning(`GraphQL ${what} with the ${client.name} token failed: ${String(error && error.message).slice(0, 200)}`);
    }
  }
  throw last || new Error(`no GraphQL client for ${what}`);
}

const FIND_QUERY = `query($owner: String!, $name: String!, $label: String!) {
  repository(owner: $owner, name: $name) {
    id
    label(name: $label) { id }
    issues(labels: [$label], states: OPEN, first: 10, orderBy: { field: CREATED_AT, direction: DESC }) { nodes { id number } }
  }
}`;

async function upsertGraphql(graphql, { owner, repo, label, title, body, color, description }) {
  const { repository } = await graphql(FIND_QUERY, { owner, name: repo, label });
  const open = (repository.label && repository.issues.nodes) || [];
  if (open.length > 0) {
    await graphql('mutation($id: ID!, $body: String!) { addComment(input: { subjectId: $id, body: $body }) { clientMutationId } }', { id: open[0].id, body });
    return { number: open[0].number, created: false };
  }
  let labelId = repository.label && repository.label.id;
  if (!labelId) {
    try {
      const made = await graphql('mutation($r: ID!, $n: String!, $c: String!, $d: String) { createLabel(input: { repositoryId: $r, name: $n, color: $c, description: $d }) { label { id } } }',
        { r: repository.id, n: label, c: color, d: description, headers: { accept: 'application/vnd.github.bane-preview+json' } });
      labelId = made.createLabel.label.id;
    } catch (_error) {
      labelId = null; // the issue is still opened, under its title
    }
  }
  const made = await graphql('mutation($r: ID!, $t: String!, $b: String!, $l: [ID!]) { createIssue(input: { repositoryId: $r, title: $t, body: $b, labelIds: $l }) { issue { number } } }',
    { r: repository.id, t: title, b: body, l: labelId ? [labelId] : [] });
  return { number: made.createIssue.issue.number, created: true };
}

async function closeGraphql(graphql, { owner, repo, label, body }) {
  const { repository } = await graphql(FIND_QUERY, { owner, name: repo, label });
  const open = (repository.label && repository.issues.nodes) || [];
  for (const issue of open) {
    await graphql('mutation($id: ID!, $body: String!) { addComment(input: { subjectId: $id, body: $body }) { clientMutationId } }', { id: issue.id, body });
    await graphql('mutation($id: ID!) { closeIssue(input: { issueId: $id }) { clientMutationId } }', { id: issue.id });
  }
  return open.map((i) => i.number);
}

function lastResort(core, heading, body, error) {
  core.error(`${heading}\n\n${body}`.slice(0, 4000), { title: heading });
  if (core.summary && typeof core.summary.addHeading === 'function') {
    try {
      core.summary.addHeading(heading, 3).addRaw(`${body}\n\nNo token could reach GitHub's API: ${String(error && error.message).slice(0, 300)}\n`);
      return core.summary.write().catch(() => {});
    } catch (_error) { /* the annotation above already says it */ }
  }
  return Promise.resolve();
}

// The open issue with LABEL gets BODY as a comment, else a new issue TITLE with LABEL (made when missing).
async function upsertIncident({ github, core, context, label, title, body, color = 'b60205', description = '', deadlineMs, sleep, now }) {
  const { owner, repo } = context.repo;
  try {
    return await withReset(async () => {
      try {
        try {
          await github.rest.issues.getLabel({ owner, repo, name: label });
        } catch (error) {
          if (error.status !== 404) throw error;
          await github.rest.issues.createLabel({ owner, repo, name: label, color, description });
        }
        const open = await github.rest.issues.listForRepo({ owner, repo, labels: label, state: 'open', per_page: 1 });
        if (open.data.length > 0) {
          await github.rest.issues.createComment({ owner, repo, issue_number: open.data[0].number, body });
          return { number: open.data[0].number, created: false };
        }
        const { data } = await github.rest.issues.create({ owner, repo, title, labels: [label], body });
        return { number: data.number, created: true };
      } catch (error) {
        if (!isRateLimited(error) && error.incidentResetAt === undefined) throw error;
        try {
          return await viaGraphql(github, core, 'the incident report', (graphql) => upsertGraphql(graphql, { owner, repo, label, title, body, color, description }));
        } catch (_graphqlError) {
          throw error;
        }
      }
    }, { core, deadlineMs, sleep, now });
  } catch (error) {
    await lastResort(core, title, body, error);
    throw error;
  }
}

// Every open issue with LABEL gets BODY as a comment and is closed.
async function closeIncidents({ github, core, context, label, body, deadlineMs, sleep, now }) {
  const { owner, repo } = context.repo;
  return withReset(async () => {
    try {
      const open = await github.rest.issues.listForRepo({ owner, repo, labels: label, state: 'open', per_page: 10 });
      for (const issue of open.data) {
        await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body });
        await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'closed' });
      }
      return open.data.map((i) => i.number);
    } catch (error) {
      if (!isRateLimited(error) && error.incidentResetAt === undefined) throw error;
      try {
        return await viaGraphql(github, core, 'closing the incident', (graphql) => closeGraphql(graphql, { owner, repo, label, body }));
      } catch (_graphqlError) {
        throw error;
      }
    }
  }, { core, deadlineMs, sleep, now });
}

module.exports = { arm, withReset, upsertIncident, closeIncidents, isRateLimited, resetAtMs, lastResort };
