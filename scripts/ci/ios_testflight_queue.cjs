// Upload queue for ios-testflight.yml: ordered uploads with no waiting loop.
//
// App Store Connect needs one upload at a time. Each run keys its own
// concurrency group by run_id (a shared group keeps only one pending run and
// cancels the rest, which would drop queued uploads), so ordering lives here.
//
// A manual dispatch or DEMO run that finds an earlier upload still running no
// longer waits on a runner. Its decide job uploads a small marker artifact
// (DEFERRED_ARTIFACT) and the run ends. A marker is the run's place in line:
// it blocks every later run, and it stays until that run's own upload job is
// done. reconcile() then re-runs the oldest marked run, which keeps its commit,
// its inputs and its variant, so a queued upload ships exactly what it would
// have shipped after waiting. reconcile() runs after every upload and in every
// 20-minute INTERNAL poll that does not upload, so a missed handoff is picked
// up by the next poll.
//
// Every function makes a fixed, small number of API calls and returns. Nothing
// here waits: tests/test_ios_testflight_main_push_filter.py fails on a timer.

'use strict';

const WORKFLOW = 'ios-testflight.yml';
const UPLOAD_JOB = 'Upload to TestFlight';
const DEFERRED_ARTIFACT = 'ios-testflight-deferred';
const QUEUE_EVENTS = ['push', 'schedule', 'workflow_dispatch'];
// A run whose jobs never started after this long is in GitHub's queued limbo
// (cancel, force-cancel and rerun all fail) and is not treated as active.
const DEFUNCT_MINUTES = 120;
// GitHub allows a bounded number of attempts per run. A run deferred this
// many times is stuck for some other reason: drop it loudly, keep the line moving.
const MAX_ATTEMPTS = 25;

function minutesSince(timestamp) {
  const ms = Date.parse(timestamp ?? '');
  return Number.isFinite(ms) ? (Date.now() - ms) / 60_000 : 0;
}

async function listMainRuns({ github, owner, repo }) {
  const response = await github.rest.actions.listWorkflowRuns({
    owner,
    repo,
    workflow_id: WORKFLOW,
    branch: 'main',
    per_page: 100,
  });
  return response.data.workflow_runs || [];
}

// Marker artifacts by run id, oldest run first.
async function listMarkers({ github, owner, repo }) {
  const markers = new Map();
  const perPage = 100;
  for (let page = 1; page <= 10; page += 1) {
    const response = await github.rest.actions.listArtifactsForRepo({
      owner,
      repo,
      name: DEFERRED_ARTIFACT,
      per_page: perPage,
      page,
    });
    const artifacts = response.data.artifacts || [];
    for (const artifact of artifacts) {
      const run = artifact.workflow_run;
      if (artifact.name !== DEFERRED_ARTIFACT || artifact.expired) continue;
      if (run?.head_branch !== 'main' || !run.id) continue;
      const runId = Number(run.id);
      if (!markers.has(runId)) markers.set(runId, []);
      markers.get(runId).push(artifact.id);
    }
    if (artifacts.length < perPage) break;
  }
  return new Map([...markers.entries()].sort(([a], [b]) => a - b));
}

// Whether an active run may still upload: its upload job has not finished.
async function mayStillUpload({ github, owner, repo, core }, run) {
  const jobs = await github.rest.actions.listJobsForWorkflowRun({
    owner,
    repo,
    run_id: run.id,
    per_page: 100,
  });
  const anyJobStarted = jobs.data.jobs.some((job) => job.status !== 'queued');
  const stuckMinutes = minutesSince(run.created_at);
  if (!anyJobStarted && stuckMinutes >= DEFUNCT_MINUTES) {
    core.warning(
      `ignoring defunct TestFlight run ${run.id}: ` +
      `no job started after ${Math.round(stuckMinutes)} minutes`
    );
    return false;
  }
  const uploadJob = jobs.data.jobs.find((job) => job.name === UPLOAD_JOB);
  return !uploadJob || uploadJob.status !== 'completed';
}

function isActive(run) {
  return run.status !== 'completed' && QUEUE_EVENTS.includes(run.event);
}

// One pass over the queue for this run: which earlier runs hold it back.
// Throws on an API error; the caller decides whether to skip or defer.
async function inspect({ github, context, core }) {
  const { owner, repo } = context.repo;
  const currentRunId = Number(context.runId);
  const runs = await listMainRuns({ github, owner, repo });
  const markers = await listMarkers({ github, owner, repo });
  const blockingRuns = [];
  for (const run of runs) {
    if (Number(run.id) >= currentRunId || !isActive(run)) continue;
    if (await mayStillUpload({ github, owner, repo, core }, run)) {
      blockingRuns.push(Number(run.id));
    }
  }
  // An earlier marked run is waiting for its turn, or is already re-running.
  for (const runId of markers.keys()) {
    if (runId < currentRunId && !blockingRuns.includes(runId)) {
      blockingRuns.push(runId);
    }
  }
  blockingRuns.sort((a, b) => a - b);
  return { runs, markers, blockingRuns };
}

async function deleteMarkers({ github, owner, repo }, artifactIds) {
  for (const artifactId of artifactIds) {
    await github.rest.actions.deleteArtifact({ owner, repo, artifact_id: artifactId });
  }
}

// Remove this run's marker once its upload job is done (or it decided not to
// upload). Reads the markers itself unless the caller already has them.
async function release({ github, context, core }, markers) {
  const { owner, repo } = context.repo;
  const currentRunId = Number(context.runId);
  const all = markers ?? (await listMarkers({ github, owner, repo }));
  const own = all.get(currentRunId) ?? [];
  if (own.length === 0) return false;
  await deleteMarkers({ github, owner, repo }, own);
  all.delete(currentRunId);
  core.info(`released the upload queue marker of run ${currentRunId}`);
  return true;
}

// Re-run the oldest queued run when nothing else may be uploading. Returns the
// run id it started, or null. Never throws: the next poll is the retry.
async function reconcile({ github, context, core }, state) {
  const { owner, repo } = context.repo;
  const currentRunId = Number(context.runId);
  try {
    const runs = state?.runs ?? (await listMainRuns({ github, owner, repo }));
    const markers = state?.markers ?? (await listMarkers({ github, owner, repo }));
    const queued = [...markers.keys()].filter((runId) => runId !== currentRunId);
    if (queued.length === 0) return null;
    const byId = new Map(runs.map((run) => [Number(run.id), run]));
    for (const run of runs) {
      if (Number(run.id) === currentRunId || !isActive(run)) continue;
      if (await mayStillUpload({ github, owner, repo, core }, run)) {
        core.info(`upload queue: run ${run.id} may still upload; ${queued.length} queued`);
        return null;
      }
    }
    for (const runId of queued) {
      const run =
        byId.get(runId) ??
        (await github.rest.actions.getWorkflowRun({ owner, repo, run_id: runId })).data;
      if (run.status !== 'completed') {
        // Its re-run is already under way and holds the line.
        return null;
      }
      const jobs = await github.rest.actions.listJobsForWorkflowRun({
        owner,
        repo,
        run_id: runId,
        per_page: 100,
      });
      const uploadJob = jobs.data.jobs.find((job) => job.name === UPLOAD_JOB);
      const uploadRan =
        uploadJob?.status === 'completed' && uploadJob.conclusion !== 'skipped';
      const attempts = Number(run.run_attempt ?? 1);
      if (uploadRan || run.conclusion === 'cancelled' || attempts >= MAX_ATTEMPTS) {
        // Already uploaded (its release failed), cancelled by someone, or
        // stuck: the marker no longer holds a place in line.
        if (!uploadRan) {
          core.warning(
            `dropping queued TestFlight run ${runId} from the upload queue ` +
            `(conclusion ${run.conclusion}, attempt ${attempts})`
          );
        }
        await deleteMarkers({ github, owner, repo }, markers.get(runId));
        continue;
      }
      await github.rest.actions.reRunWorkflow({ owner, repo, run_id: runId });
      core.notice(`started queued TestFlight run ${runId} (attempt ${attempts + 1})`);
      return runId;
    }
    return null;
  } catch (error) {
    // The run page is public, so the warning stays generic.
    core.debug(`upload queue reconcile failed: ${error.message}`);
    core.warning('could not advance the TestFlight upload queue; the next poll retries');
    return null;
  }
}

module.exports = {
  DEFERRED_ARTIFACT,
  UPLOAD_JOB,
  inspect,
  listMarkers,
  reconcile,
  release,
};
