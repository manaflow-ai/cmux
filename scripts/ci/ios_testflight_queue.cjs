// Upload queue for ios-testflight.yml: ordered uploads with no waiting loop.
//
// App Store Connect needs one upload at a time. Each run keys its own
// concurrency group by run_id (a shared group keeps only one pending run and
// cancels the rest, which would drop queued uploads), so ordering lives here.
//
// A manual dispatch or DEMO run that finds an earlier upload still running no
// longer waits on a runner. Its decide job uploads a small marker artifact
// (DEFERRED_ARTIFACT) and the run ends. A marker is the run's place in line:
// it blocks every later run. reconcile() re-runs the oldest marked run once
// nothing earlier may still upload; the re-run keeps its commit, its inputs
// and its variant, so a queued upload ships exactly what it would have shipped
// after waiting. The re-run's decide deletes the marker when it has its answer;
// from then on the active run blocks later runs by itself until its upload job
// is done, like any other run. reconcile() runs after every upload and in
// every 20-minute INTERNAL poll that does not upload, so a missed handoff is
// picked up by the next poll.
//
// Every function makes a fixed, small number of API calls and returns. Nothing
// here waits: tests/test_ios_testflight_main_push_filter.py fails on a timer.

'use strict';

const WORKFLOW = 'ios-testflight.yml';
const UPLOAD_JOB = 'Upload to TestFlight';
const DEFERRED_ARTIFACT = 'ios-testflight-deferred';
const QUEUE_EVENTS = ['push', 'schedule', 'workflow_dispatch'];
// GitHub's cap on attempts of one run. A refused re-run is never skipped: it
// may be another reconciler's re-run still starting.
const MAX_RUN_ATTEMPTS = 50;
// A run whose jobs never started after this long is in GitHub's queued limbo
// (cancel, force-cancel and rerun all fail) and is not treated as active.
const DEFUNCT_MINUTES = 120;

function minutesSince(timestamp) {
  const ms = Date.parse(timestamp ?? '');
  return Number.isFinite(ms) ? (Date.now() - ms) / 60_000 : 0;
}

// GitHub's statuses for a run that has not finished.
const ACTIVE_STATUSES = ['queued', 'in_progress', 'waiting', 'requested', 'pending'];

// The newest 100 main runs (the failed-upload check reads them) plus every
// active main run of any age, every page, newest first. A re-run keeps its
// first attempt's creation time, so no creation window can bound this.
async function listMainRuns({ github, owner, repo }) {
  const perPage = 100;
  const list = (extra) =>
    github.rest.actions.listWorkflowRuns({
      owner,
      repo,
      workflow_id: WORKFLOW,
      branch: 'main',
      per_page: perPage,
      ...extra,
    });
  const byId = new Map();
  const add = (runs) => {
    for (const run of runs) byId.set(Number(run.id), run);
  };
  add((await list({ page: 1 })).data.workflow_runs || []);
  for (const status of ACTIVE_STATUSES) {
    for (let page = 1, pageCount = 1; page <= pageCount; page += 1) {
      const response = await list({ status, page });
      const pageRuns = response.data.workflow_runs || [];
      add(pageRuns);
      const totalCount = Number(response.data.total_count ?? pageRuns.length);
      pageCount = Math.max(1, Math.ceil(totalCount / perPage));
      if (pageRuns.length === 0) break;
    }
  }
  return [...byId.values()].sort((a, b) => Number(b.id) - Number(a.id));
}

// Marker artifacts by run id, oldest run first.
async function listMarkers({ github, owner, repo }) {
  const markers = new Map();
  const perPage = 100;
  // Every page: an omitted older marker would let a newer upload overtake it.
  for (let page = 1, pageCount = 1; page <= pageCount; page += 1) {
    const response = await github.rest.actions.listArtifactsForRepo({
      owner,
      repo,
      name: DEFERRED_ARTIFACT,
      per_page: perPage,
      page,
    });
    const artifacts = response.data.artifacts || [];
    const totalCount = Number(response.data.total_count ?? artifacts.length);
    pageCount = Math.max(1, Math.ceil(totalCount / perPage));
    for (const artifact of artifacts) {
      const run = artifact.workflow_run;
      if (artifact.name !== DEFERRED_ARTIFACT || artifact.expired) continue;
      if (run?.head_branch !== 'main' || !run.id) continue;
      const runId = Number(run.id);
      if (!markers.has(runId)) markers.set(runId, []);
      markers.get(runId).push(artifact.id);
    }
    if (artifacts.length === 0) break;
  }
  return new Map([...markers.entries()].sort(([a], [b]) => a - b));
}

// A run (or a re-run attempt) whose jobs never started in DEFUNCT_MINUTES.
// run_started_at is the current attempt's start; created_at is the first's.
function isDefunct(run, jobs) {
  const anyJobStarted = jobs.some((job) => job.status !== 'queued');
  const stuckMinutes = minutesSince(run.run_started_at ?? run.created_at);
  return !anyJobStarted && stuckMinutes >= DEFUNCT_MINUTES ? stuckMinutes : 0;
}

async function listJobs({ github, owner, repo }, runId) {
  const response = await github.rest.actions.listJobsForWorkflowRun({
    owner,
    repo,
    run_id: runId,
    per_page: 100,
  });
  return response.data.jobs || [];
}

// Whether an active run may still upload: its upload job has not finished.
async function mayStillUpload({ github, owner, repo, core }, run) {
  const jobs = await listJobs({ github, owner, repo }, run.id);
  const stuckMinutes = isDefunct(run, jobs);
  if (stuckMinutes) {
    core.warning(
      `ignoring defunct TestFlight run ${run.id}: ` +
      `no job started after ${Math.round(stuckMinutes)} minutes`
    );
    return false;
  }
  const uploadJob = jobs.find((job) => job.name === UPLOAD_JOB);
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
      const jobs = await listJobs({ github, owner, repo }, runId);
      if (run.status !== 'completed') {
        const stuckMinutes = isDefunct(run, jobs);
        if (!stuckMinutes) {
          // Its re-run is under way and holds the line.
          return null;
        }
        // GitHub's queued limbo: cancel and re-run are refused, so the marker
        // would block every later upload until it expires.
        core.error(
          `dropping queued TestFlight run ${runId} from the upload queue: ` +
          `no job started after ${Math.round(stuckMinutes)} minutes; dispatch it again`
        );
        await deleteMarkers({ github, owner, repo }, markers.get(runId));
        continue;
      }
      const uploadJob = jobs.find((job) => job.name === UPLOAD_JOB);
      const uploadRan =
        uploadJob?.status === 'completed' && uploadJob.conclusion !== 'skipped';
      if (uploadRan || run.conclusion === 'cancelled') {
        // Its turn already came (decide could not delete the marker) or
        // someone cancelled it: the marker no longer holds a place in line.
        if (!uploadRan) {
          core.warning(`dropping cancelled TestFlight run ${runId} from the upload queue`);
        }
        await deleteMarkers({ github, owner, repo }, markers.get(runId));
        continue;
      }
      const attempts = Number(run.run_attempt ?? 1);
      if (attempts >= MAX_RUN_ATTEMPTS) {
        // GitHub allows no further attempt of this run: say so loudly and
        // keep the line moving.
        core.error(
          `dropping queued TestFlight run ${runId} from the upload queue: ` +
          `it is at GitHub's limit of ${MAX_RUN_ATTEMPTS} attempts; dispatch it again`
        );
        await deleteMarkers({ github, owner, repo }, markers.get(runId));
        continue;
      }
      try {
        await github.rest.actions.reRunWorkflow({ owner, repo, run_id: runId });
      } catch (error) {
        // Most likely another reconciler started it a moment ago; if not, the
        // next poll tries again. Never move past it on a refusal.
        core.debug(`re-run of ${runId} refused: ${error.message}`);
        core.warning(`could not re-run queued TestFlight run ${runId}; the next poll retries`);
        return null;
      }
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
