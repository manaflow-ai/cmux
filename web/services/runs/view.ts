import type { RunSnapshot } from "./repository";

/** Keep flat fields for old callers, with the board's canonical nested snapshot. */
export function runReceipt(snapshot: RunSnapshot) {
  const { run, attempts, events } = snapshot;
  return {
    id: run.id, status: run.status, provider: run.provider, requestDigest: run.requestDigest,
    desiredAttempts: run.desiredAttempts, createdAt: run.createdAt, updatedAt: run.updatedAt, completedAt: run.completedAt,
    run: { id: run.id, status: run.status, source: run.source, recipe: run.recipe, provider: run.provider, desiredAttempts: run.desiredAttempts, specDigest: run.requestDigest, createdAt: run.createdAt, updatedAt: run.updatedAt, error: run.error },
    attempts: attempts.map((attempt) => ({ ...attempt, checkpoint: undefined, leaseId: undefined, workerId: undefined, attachable: attempt.cleanupState === "retained" && (!!attempt.promotedAt || (!!attempt.retainedUntil && attempt.retainedUntil.getTime() > Date.now())), placement: { executionProvider: "cloud-vm", backendProvider: "freestyle" } })),
    events,
    cursor: String(events.at(-1)?.sequence ?? -1),
    artifacts: snapshot.artifacts.map((artifact) => ({ id: artifact.id, attemptId: artifact.attemptId, name: artifact.name, digest: artifact.digest, sizeBytes: artifact.sizeBytes, mediaType: "application/json", uri: `/api/runs/${run.id}/artifacts/${artifact.id}`, createdAt: artifact.createdAt })),
  };
}
