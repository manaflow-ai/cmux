// nightly.yml: failure reporting at the workflow commit.
module.exports = async ({github, context, core}) => {
  // A rate-limited request waits for its reset and goes again (run 45776501690 lost its report to one); a
  // refused request did nothing, so a write retries safely. 50 min of waits in all, as decide does.
  const deadline = Date.now() + 50 * 60 * 1000;
  github.hook.wrap('request', async (request, options) => {
    for (let attempt = 1; ; attempt += 1) {
      try { return await request(options); } catch (error) {
        const h = (error.response && error.response.headers) || {};
        if (!((error.status === 403 || error.status === 429) && (h['x-ratelimit-remaining'] === '0' || h['retry-after'] !== undefined || /rate limit/i.test(String(error.message)))) || Date.now() >= deadline) throw error;
        const ms = Math.max(5000, Math.min(Number(h['retry-after']) * 1000 || Number(h['x-ratelimit-reset']) * 1000 - Date.now() + 2000 || 60000 * attempt, deadline - Date.now()));
        core.warning(`GitHub API rate limited (${error.status}) on ${options.method} ${options.url}; retrying in ${Math.round(ms / 1000)} s`);
        await new Promise((resolve) => setTimeout(resolve, ms));
      }
    }
  });
  const { owner, repo } = context.repo;
  // One label per release track (nightly, rc, nightly-next), so a
  // cmux-next result never opens or closes main's NIGHTLY incident.
  const appName = process.env.CHANNEL_APP_NAME;
  const refName = process.env.REF_NAME;
  const label = `${process.env.CHANNEL_RELEASE_TAG}-failure`;
  const runUrl = `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;
  const results = JSON.parse(process.env.RESULTS);
  // A nightly-next build that a newer push replaced while it waited for
  // the shared build slot ends cancelled without ever getting a runner;
  // the newer run builds and reports. Only that case is dropped: a build
  // that started and was cancelled (timeout, by hand) still reports, and
  // so does every other failed job of this run.
  let replaced = false;
  if (refName === 'nightly-next' && results['build-nightly-app']?.result === 'cancelled') {
    try {
      // Latest attempt of each job (the endpoint's default filter).
      const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun,
        { owner, repo, run_id: context.runId, per_page: 100 });
      const build = jobs.find((job) => job.name === 'build-nightly-app');
      const neverStarted = Boolean(build) && !build.runner_name && !(build.steps || []).length;
      // A build cancelled while queued for a runner never started either;
      // only a newer push (the ref moved past this tip) replaces it.
      const { data: ref } = await github.rest.git.getRef({ owner, repo, ref: 'heads/nightly-next' });
      replaced = neverStarted && ref.object.sha !== process.env.TIP_SHA;
    } catch (error) {
      core.warning(`Could not read this run's jobs (${error.message}); reporting the cancelled build.`);
    }
  }
  const failed = Object.entries(results)
    .filter(([k, v]) => (v.result === 'failure' || v.result === 'cancelled') && !(replaced && k === 'build-nightly-app'))
    .map(([k, v]) => `${k} (${v.result})`);
  if (replaced && failed.length === 0 && !process.env.REFUSAL_REASON && process.env.TAG_STATUS !== 'stale') {
    core.info('build-nightly-app was replaced in its slot by a newer nightly-next push before it started; nothing else failed.');
    return;
  }
  // A refused publication succeeds as a job but published nothing.
  if (process.env.REFUSAL_REASON) failed.push(`publish-nightly (refused: ${process.env.REFUSAL_REASON})`);
  // nightly-next: notes jobs that were skipped after a publication
  // (a recovered one skips them on purpose), in the run that ran the tail (run_tail).
  if (process.env.TRACK === 'nightly-next' && results['published-build']?.result === 'success'
      && results['published-build']?.outputs?.run_tail === 'true'
      && results['published-build']?.outputs?.publish_result === 'success' && process.env.PUBLISH_SOURCE !== 'recovered') {
    for (const job of ['sign-release-notes', 'publish-release-notes']) {
      const result = results[job]?.result;
      if (result === 'skipped') failed.push(`${job} (skipped)`);
    }
  }
  const tagStale = process.env.TAG_STATUS === 'stale';
  const publicationLine = tagStale
    ? `${appName} published, tag marker stale for ${process.env.HEAD_SHA} (${refName}). Assets, release metadata, and appcasts are available; only the channel completion marker failed to advance.`
    : `${appName} run ${runUrl} failed on ${process.env.HEAD_SHA} (${refName}) in: ${failed.join(', ')}.`;
  const failedLine = failed.length > 0 ? `Failed jobs: ${failed.join(', ')}.` : 'The tag marker update failed after publication completed.';
  const body = `${publicationLine}\n\n${failedLine}\n\nThe next successful publication will update this incident. Run: ${runUrl}`;
  try {
    await github.rest.issues.getLabel({ owner, repo, name: label });
  } catch (error) {
    if (error.status !== 404) throw error;
    await github.rest.issues.createLabel({ owner, repo, name: label, color: 'b60205', description: `${appName} publish failing` });
  }
  const open = await github.rest.issues.listForRepo({ owner, repo, labels: label, state: 'open', per_page: 1 });
  if (open.data.length > 0) {
    await github.rest.issues.createComment({ owner, repo, issue_number: open.data[0].number, body });
  } else {
    await github.rest.issues.create({ owner, repo, title: `${appName} build is failing on ${refName}`, labels: [label], body });
  }
};
