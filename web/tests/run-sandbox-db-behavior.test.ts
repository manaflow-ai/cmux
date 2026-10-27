import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import type { Sql } from "postgres";
type RunRepositoryModule = typeof import("../services/runs/repository");

// A sandboxed Run (hq#3367) keeps nothing: each terminal path makes its VM due for destroy now,
// and the reaper fails a sandbox whose launcher died. Runs against a real database.
const dbEnabled = process.env.CMUX_DB_TEST === "1";
const dbTest = dbEnabled ? test : test.skip;
let sql: Sql | null = null;
let repository: RunRepositoryModule | null = null;

beforeAll(async () => {
  if (!dbEnabled) return;
  const [{ default: postgres }, loaded] = await Promise.all([import("postgres"), import("../services/runs/repository")]);
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 1 });
  repository = loaded;
});

afterAll(async () => {
  if (dbEnabled) await (await import("../db/client")).closeCloudDbForTests();
  await sql?.end();
});

function repo(): RunRepositoryModule {
  if (!repository) throw new Error("Run repository was not loaded");
  return repository;
}

function input(userId: string, environment: "sandboxed" | "persistent" = "sandboxed") {
  const value = environment === "sandboxed"
    ? { source: {}, recipe: "sandbox-task", desiredAttempts: 1, environment, imageId: "sh-test-image", imageVersion: "test-version" } as const
    : { source: { repository: "manaflow-ai/cmux", commit: "c".repeat(40) }, recipe: "parallel-review", desiredAttempts: 1, environment } as const;
  return {
    userId,
    billingTeamId: userId,
    idempotencyKey: `sandbox-test-${randomUUID()}`,
    requestDigest: repo().requestDigest({ ...value, nonce: randomUUID() }),
    ...value,
  };
}

async function startedAttempt(userId: string, environment: "sandboxed" | "persistent" = "sandboxed") {
  const created = await repo().createRun(input(userId, environment));
  const attempt = created.attempts[0];
  if (!attempt) throw new Error("run did not create an attempt");
  const lease = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "sandbox-worker" });
  await repo().ingestRunEvent({
    runId: created.run.id, attemptId: attempt.id, leaseToken: lease.leaseToken, leaseGeneration: lease.leaseGeneration,
    externalId: "attempt-started", attemptSequence: 0, kind: "attempt.started", payload: { providerVmId: `vm-${attempt.id}` },
  });
  return { runId: created.run.id, attemptId: attempt.id, lease };
}

/** A VM row as the sandbox launcher leaves it: its create key and the matching server-set marker. */
async function insertSandboxVm(userId: string, key: string, providerVmId: string, marked = true): Promise<void> {
  await sql!`insert into cloud_vms (user_id, billing_team_id, provider, image_id, status, idempotency_key, provider_vm_id, provider_metadata)
    values (${userId}, ${userId}, 'freestyle', 'sh-test-image', 'running', ${key}, ${providerVmId}, ${sql!.json(marked ? { cmuxSandboxRun: key } : {})})`;
}

/** The launcher's end: the terminal event, then the handoff that makes the VM due at once. */
async function finishAttempt(target: { runId: string; attemptId: string; lease: { leaseToken: string; leaseGeneration: number } }, kind: "attempt.succeeded" | "attempt.failed" = "attempt.succeeded"): Promise<void> {
  await repo().ingestRunEvent({ runId: target.runId, attemptId: target.attemptId, ...target.lease, externalId: "end", attemptSequence: 1, kind, payload: kind === "attempt.failed" ? { error: "x" } : {} });
  await repo().scheduleAttemptRetention({ runId: target.runId, attemptId: target.attemptId, ...target.lease, retentionMs: 0 });
}

async function removeRuns(userId: string): Promise<void> {
  await sql!`delete from runs where user_id = ${userId}`;
}

describe("sandboxed Run lifecycle in the repository", () => {
  dbTest("a sandboxed Run needs exactly one attempt and a pinned image", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      await expect(repo().createRun({ ...input(userId), imageId: null })).rejects.toThrow("pinned image");
      await expect(repo().createRun({ ...input(userId), desiredAttempts: 2 })).rejects.toThrow("exactly one attempt");
      await expect(repo().createRun({ ...input(userId), billingTeamId: null })).rejects.toThrow("billing team");
      const created = await repo().createRun(input(userId));
      expect(created.run).toMatchObject({ environment: "sandboxed", imageId: "sh-test-image", imageVersion: "test-version" });
      const constraint = await sql!`update runs set desired_attempts = 2 where id = ${created.run.id}`.then(() => null, (error: unknown) => error);
      expect(String(constraint)).toContain("runs_sandboxed_single_attempt_check");
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("success and failure make the VM due now; a persistent Run keeps its attach window", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      for (const kind of ["attempt.succeeded", "attempt.failed"] as const) {
        const { runId, attemptId, lease } = await startedAttempt(userId);
        await repo().ingestRunEvent({ runId, attemptId, ...lease, externalId: `end-${kind}`, attemptSequence: 1, kind });
        // The launcher's handoff window: not yet the reaper's.
        expect(await repo().claimExpiredAttemptCleanups({ runId })).toEqual([]);
        // The launcher's handoff makes it due at once.
        await repo().scheduleAttemptRetention({ runId, attemptId, ...lease, retentionMs: 0 });
        const claims = await repo().claimExpiredAttemptCleanups({ runId });
        expect(claims.map((claim) => claim.attempt.id)).toEqual([attemptId]);
        await repo().finishAttemptCleanup({ attemptId, cleanupLeaseToken: claims[0]!.cleanupLeaseToken, succeeded: true });
        const snapshot = await repo().getRun(runId, userId);
        expect(snapshot.attempts[0]?.providerVmId).toBeNull();
        // Once the VM is gone, the launcher's lease is gone with it.
        expect(snapshot.attempts[0]?.leaseToken).toBeNull();
      }
      const persistent = await startedAttempt(userId, "persistent");
      await repo().ingestRunEvent({ runId: persistent.runId, attemptId: persistent.attemptId, ...persistent.lease, externalId: "end", attemptSequence: 1, kind: "attempt.succeeded" });
      expect(await repo().claimExpiredAttemptCleanups({ runId: persistent.runId })).toEqual([]);
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("cancel makes the VM due now and the scoped claim takes only that Run's VM", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const cancelled = await startedAttempt(userId);
      const other = await startedAttempt(userId);
      await repo().cancelRun(cancelled.runId, userId);
      await repo().finalizeAttemptCancellation({ runId: cancelled.runId, attemptId: cancelled.attemptId, leaseToken: cancelled.lease.leaseToken, leaseGeneration: cancelled.lease.leaseGeneration });
      await finishAttempt(other);
      const claims = await repo().claimExpiredAttemptCleanups({ runId: cancelled.runId });
      expect(claims.map((claim) => claim.attempt.id)).toEqual([cancelled.attemptId]);
      expect((await repo().getRun(cancelled.runId, userId)).run.status).toBe("cancelled");
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("a sandboxed attempt is never attachable, and only its own marked VM row is its VM", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const { toRunSnapshotView } = await import("../services/runs/view");
      const sandbox = await startedAttempt(userId);
      const persistent = await startedAttempt(userId, "persistent");
      for (const target of [sandbox, persistent]) {
        await sql!`update run_attempts set provider_workspace_id = 'ws-1', provider_terminal_id = 'term-1' where id = ${target.attemptId}`;
        // The terminal event opens the handoff window (sandbox) or the attach window (persistent).
        await repo().ingestRunEvent({ runId: target.runId, attemptId: target.attemptId, ...target.lease, externalId: "end", attemptSequence: 1, kind: "attempt.succeeded" });
      }
      await expect(repo().mintRunAttachTicket({ runId: sandbox.runId, attemptId: sandbox.attemptId, userId })).rejects.toThrow("sandboxed");
      expect(toRunSnapshotView(await repo().getRun(sandbox.runId, userId)).attempts[0]?.attachable).toBe(false);
      expect(toRunSnapshotView(await repo().getRun(persistent.runId, userId)).attempts[0]?.attachable).toBe(true);
      expect((await repo().mintRunAttachTicket({ runId: persistent.runId, attemptId: persistent.attemptId, userId })).ticket).toBeTruthy();

      // A VM id from an event is the attempt's VM only with the launcher's keyed, marked row for that user.
      const owned = { providerVmId: `vm-${sandbox.attemptId}`, runId: sandbox.runId, attemptId: sandbox.attemptId, userId };
      expect(await repo().sandboxVmOwnedByAttempt(owned)).toBe(false);
      const key = `sandbox-run:${sandbox.runId}:attempt:${sandbox.attemptId}`;
      // Another user's row with that VM id and key is not this attempt's VM.
      await insertSandboxVm(`other-${userId}`, key, owned.providerVmId);
      expect(await repo().sandboxVmOwnedByAttempt(owned)).toBe(false);
      // This user's row without the server-set marker is not either.
      await sql!`update cloud_vms set user_id = ${userId}, billing_team_id = ${userId}, provider_metadata = '{}'::jsonb where provider_vm_id = ${owned.providerVmId}`;
      expect(await repo().sandboxVmOwnedByAttempt(owned)).toBe(false);
      await sql!`update cloud_vms set provider_metadata = ${sql!.json({ cmuxSandboxRun: key })} where provider_vm_id = ${owned.providerVmId}`;
      expect(await repo().sandboxVmOwnedByAttempt(owned)).toBe(true);
    } finally {
      await sql!`delete from cloud_vms where user_id in ${sql!([userId, `other-${userId}`])}`;
      await removeRuns(userId);
    }
  });

  dbTest("forced cancellation of a vanished launcher makes the VM due now", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const { runId, attemptId } = await startedAttempt(userId);
      await repo().cancelRun(runId, userId);
      await repo().forceFinalizeRunCancellation(runId, userId);
      expect((await repo().claimExpiredAttemptCleanups({ runId })).map((claim) => claim.attempt.id)).toEqual([attemptId]);
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("the reaper fails a sandbox whose launcher died, and its VM becomes due", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const lapsed = await startedAttempt(userId);
      const live = await startedAttempt(userId);
      const persistent = await startedAttempt(userId, "persistent");
      const queued = await repo().createRun(input(userId));
      await sql!`update run_attempts set lease_expires_at = now() - interval '10 minutes' where id in ${sql!([lapsed.attemptId, persistent.attemptId])}`;
      await sql!`update runs set created_at = now() - interval '1 hour' where id = ${queued.run.id}`;

      // Other test files share the table, so assert on this user's rows rather than the count.
      await repo().failAbandonedSandboxAttempts({ limit: 100 });

      const failed = await repo().getRun(lapsed.runId, userId);
      expect(failed.run.status).toBe("failed");
      expect(failed.attempts[0]).toMatchObject({ status: "failed", leaseToken: null });
      expect(failed.attempts[0]?.terminalRetainUntil?.getTime()).toBeLessThanOrEqual(Date.now());
      expect((await repo().claimExpiredAttemptCleanups({ runId: lapsed.runId })).map((claim) => claim.attempt.id)).toEqual([lapsed.attemptId]);
      const events = await repo().listRunEvents({ runId: lapsed.runId, userId });
      expect(events.events.map((event) => event.kind)).toContain("run.completed");

      const neverLeased = await repo().getRun(queued.run.id, userId);
      expect(neverLeased.run.status).toBe("failed");
      expect(neverLeased.attempts[0]).toMatchObject({ status: "failed", providerVmId: null, terminalRetainUntil: null });

      expect((await repo().getRun(live.runId, userId)).attempts[0]?.status).toBe("running");
      expect((await repo().getRun(persistent.runId, userId)).attempts[0]?.status).toBe("running");

      // A second pass finds nothing more to do for these rows.
      await repo().failAbandonedSandboxAttempts({ limit: 100 });
      expect((await repo().listRunEvents({ runId: lapsed.runId, userId })).events.filter((event) => event.kind === "run.completed")).toHaveLength(1);
    } finally {
      await removeRuns(userId);
    }
  });
});
