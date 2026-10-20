import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import type { Sql } from "postgres";
type RunRepositoryModule = typeof import("../services/runs/repository");

const dbEnabled = process.env.CMUX_DB_TEST === "1";
const dbTest = dbEnabled ? test : test.skip;
let sql: Sql | null = null;
let repository: RunRepositoryModule | null = null;

beforeAll(async () => {
  if (!dbEnabled) return;
  const [{ default: postgres }, loaded] = await Promise.all([
    import("postgres"),
    import("../services/runs/repository"),
  ]);
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

function input(userId: string) {
  const value = {
    source: { repository: "manaflow-ai/cmux", commit: "b".repeat(40) },
    recipe: "parallel-review",
    desiredAttempts: 1,
  } as const;
  return {
    userId,
    billingTeamId: userId,
    idempotencyKey: `retention-test-${randomUUID()}`,
    requestDigest: repo().requestDigest(value),
    ...value,
  } as const;
}

async function removeRuns(userId: string): Promise<void> {
  await sql!`delete from runs where user_id = ${userId}`;
}

describe("cloud Run terminal retention and cancellation", () => {
  dbTest("persists provider handles and a bounded attach TTL after completion", async () => {
    const userId = `retention-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create an attempt");
      const lease = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "retention-worker" });
      await repo().recordAttemptProviderHandle({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        providerVmId: "vm-retained",
        providerWorkspaceId: "workspace-retained",
        providerTerminalId: "terminal-retained",
      });
      await repo().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "terminal-succeeded",
        attemptSequence: 1,
        kind: "attempt.succeeded",
        payload: { providerVmId: "vm-retained" },
      });
      const snapshot = await repo().getRun(created.run.id, userId);
      const retained = snapshot.attempts[0];
      expect(retained?.providerWorkspaceId).toBe("workspace-retained");
      expect(retained?.providerTerminalId).toBe("terminal-retained");
      expect(retained?.terminalRetainUntil?.getTime()).toBeGreaterThan(Date.now());
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("fences active workers and completes cancellation without a stuck status", async () => {
    const userId = `cancel-retention-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create an attempt");
      const lease = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "cancel-worker" });
      await repo().recordAttemptProviderHandle({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        providerVmId: "vm-cancelled",
        providerWorkspaceId: "workspace-cancelled",
        providerTerminalId: "terminal-cancelled",
      });
      await repo().cancelRun(created.run.id, userId);
      await repo().finalizeAttemptCancellation({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
      });
      const snapshot = await repo().getRun(created.run.id, userId);
      expect(snapshot.run.status).toBe("cancelled");
      expect(snapshot.attempts[0]?.status).toBe("cancelled");
      expect(snapshot.attempts[0]?.leaseToken).toBeNull();
      await expect(repo().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "late-worker-event",
        attemptSequence: 2,
        kind: "attempt.succeeded",
      })).rejects.toBeInstanceOf(repo().RunLeaseConflictError);
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("schedules cleanup for a VM whose create returned after cancellation fenced the worker", async () => {
    const userId = `cancel-during-create-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create an attempt");
      const lease = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "creating-worker" });
      // Cancel lands while createVm is in flight: no VM id is stored yet, and
      // the cancel bumps the lease generation, fencing the worker.
      await repo().cancelRun(created.run.id, userId);
      await repo().finalizeAttemptCancellation({ runId: created.run.id, attemptId: attempt.id });
      const cancelled = (await repo().getRun(created.run.id, userId)).attempts[0];
      expect(cancelled?.status).toBe("cancelled");
      expect(cancelled?.providerVmId).toBeNull();

      // createVm returns; the worker's attempt.started ingest is fenced, and
      // its finally block hands the VM it now knows about to retention.
      await expect(repo().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "attempt-started",
        attemptSequence: 0,
        kind: "attempt.started",
        payload: { providerVmId: "vm-created-during-cancel" },
      })).rejects.toBeInstanceOf(repo().RunLeaseConflictError);
      await repo().scheduleAttemptRetention({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        providerVmId: "vm-created-during-cancel",
      });

      const adopted = (await repo().getRun(created.run.id, userId)).attempts[0];
      expect(adopted?.status).toBe("cancelled");
      expect(adopted?.providerVmId).toBe("vm-created-during-cancel");
      expect(adopted?.leaseGeneration).toBe(lease.leaseGeneration + 1);
      const claims = await repo().claimExpiredAttemptCleanups({ now: new Date(Date.now() + 60 * 60 * 1000), limit: 100 });
      const claim = claims.find((candidate) => candidate.attempt.id === attempt.id);
      expect(claim?.attempt.providerVmId).toBe("vm-created-during-cancel");
      for (const other of claims) {
        await repo().finishAttemptCleanup({ attemptId: other.attempt.id, cleanupLeaseToken: other.cleanupLeaseToken, succeeded: false });
      }
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("does not hand a stale worker's VM back to retention after the reaper destroyed it", async () => {
    const userId = `cancel-after-reap-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create an attempt");
      const lease = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "reaped-worker" });
      await repo().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "attempt-started",
        attemptSequence: 0,
        kind: "attempt.started",
        payload: { providerVmId: "vm-reaped" },
      });
      await repo().cancelRun(created.run.id, userId);
      await repo().finalizeAttemptCancellation({ runId: created.run.id, attemptId: attempt.id });
      // The reaper destroyed the VM and cleared the handles.
      await sql!`update run_attempts set provider_vm_id = null, terminal_retain_until = null where id = ${attempt.id}`;

      await expect(repo().scheduleAttemptRetention({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        providerVmId: "vm-reaped",
      })).rejects.toBeInstanceOf(repo().RunLeaseConflictError);
      const after = (await repo().getRun(created.run.id, userId)).attempts[0];
      expect(after?.providerVmId).toBeNull();
      expect(after?.terminalRetainUntil).toBeNull();
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("does not let a stale worker overwrite a replacement lease's retained terminal", async () => {
    const userId = `stale-retention-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create an attempt");
      const first = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "stale-worker" });
      await repo().recordAttemptProviderHandle({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: first.leaseToken,
        leaseGeneration: first.leaseGeneration,
        providerVmId: "vm-stale",
        providerWorkspaceId: "workspace-stale",
        providerTerminalId: "terminal-stale",
      });
      await sql!`update run_attempts set lease_expires_at = now() - interval '1 second' where id = ${attempt.id}`;
      const replacement = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "replacement-worker" });
      await repo().recordAttemptProviderHandle({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: replacement.leaseToken,
        leaseGeneration: replacement.leaseGeneration,
        providerVmId: "vm-replacement",
        providerWorkspaceId: "workspace-replacement",
        providerTerminalId: "terminal-replacement",
      });
      await repo().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: replacement.leaseToken,
        leaseGeneration: replacement.leaseGeneration,
        externalId: "replacement-succeeded",
        attemptSequence: 1,
        kind: "attempt.succeeded",
        payload: { providerVmId: "vm-replacement" },
      });
      const before = (await repo().getRun(created.run.id, userId)).attempts[0];
      if (!before?.terminalRetainUntil) throw new Error("replacement retention was not scheduled");

      const staleRetention = {
        runId: created.run.id,
        attemptId: attempt.id,
        providerVmId: "vm-stale",
        leaseToken: first.leaseToken,
        leaseGeneration: first.leaseGeneration,
        retentionMs: 60 * 60 * 1000,
      };
      await expect(repo().scheduleAttemptRetention(staleRetention as Parameters<RunRepositoryModule["scheduleAttemptRetention"]>[0])).rejects.toBeInstanceOf(repo().RunLeaseConflictError);

      const after = (await repo().getRun(created.run.id, userId)).attempts[0];
      expect(after?.providerVmId).toBe("vm-replacement");
      expect(after?.providerWorkspaceId).toBe("workspace-replacement");
      expect(after?.providerTerminalId).toBe("terminal-replacement");
      expect(after?.terminalRetainUntil?.getTime()).toBe(before.terminalRetainUntil.getTime());
    } finally {
      await removeRuns(userId);
    }
  });
});
