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

  dbTest("reaps the VM of an attempt on its own ephemeral runtime", async () => {
    // launchCloudVmAttempt (dogfood.ts) gives every attempt an ephemeral runtime before its VM
    // exists, so the reaper must still claim those; only a persistent (promoted) runtime keeps it.
    const userId = `retention-ephemeral-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create an attempt");
      const lease = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "ephemeral-worker" });
      await repo().recordAttemptProviderHandle({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        providerVmId: "vm-ephemeral",
        providerWorkspaceId: "workspace-ephemeral",
        providerTerminalId: "terminal-ephemeral",
      });
      await repo().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "ephemeral-succeeded",
        attemptSequence: 1,
        kind: "attempt.succeeded",
        payload: { providerVmId: "vm-ephemeral" },
      });
      const [runtime] = await sql!`insert into cloud_runtimes (owner_team_id, runtime_kind) values (${userId}, 'ephemeral') returning id`;
      await sql!`update run_attempts set runtime_id = ${runtime!.id} where id = ${attempt.id}`;

      const claims = await repo().claimExpiredAttemptCleanups({ now: new Date(Date.now() + 60 * 60 * 1000), limit: 100 });
      expect(claims.some((claim) => claim.attempt.id === attempt.id)).toBe(true);
      for (const claim of claims) {
        await repo().finishAttemptCleanup({ attemptId: claim.attempt.id, cleanupLeaseToken: claim.cleanupLeaseToken, succeeded: false });
      }
    } finally {
      await removeRuns(userId);
      await sql!`delete from cloud_runtimes where owner_team_id = ${userId}`;
    }
  });

  dbTest("refuses to promote an attempt whose VM the reaper has claimed", async () => {
    // The reaper destroys the VM after its claim commits; a promotion in that window would hand
    // the persistent runtime a VM that is about to be destroyed.
    const userId = `retention-race-${randomUUID()}`;
    try {
      const runtimes = await import("../services/vms/runtimeRepository");
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create an attempt");
      const lease = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "race-worker" });
      await repo().recordAttemptProviderHandle({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        providerVmId: "vm-race",
        providerWorkspaceId: "workspace-race",
        providerTerminalId: "terminal-race",
      });
      await repo().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "race-succeeded",
        attemptSequence: 1,
        kind: "attempt.succeeded",
        payload: { providerVmId: "vm-race" },
      });
      const claims = await repo().claimExpiredAttemptCleanups({ now: new Date(Date.now() + 60 * 60 * 1000), limit: 100 });
      expect(claims.some((claim) => claim.attempt.id === attempt.id)).toBe(true);
      const runtime = await runtimes.createRuntime({ ownerTeamId: userId, kind: "persistent", lifecycleState: "running" });
      let refused: unknown;
      try {
        await runtimes.promoteAttemptToRuntime({ ownerTeamId: userId, runId: created.run.id, attemptId: attempt.id, runtimeId: runtime.id });
      } catch (error) {
        refused = error;
      }
      expect(refused).toBeInstanceOf(runtimes.RuntimeAttemptConflictError);
      for (const claim of claims) {
        await repo().finishAttemptCleanup({ attemptId: claim.attempt.id, cleanupLeaseToken: claim.cleanupLeaseToken, succeeded: false });
      }
    } finally {
      await removeRuns(userId);
      await sql!`delete from cloud_runtimes where owner_team_id = ${userId}`;
    }
  });

  dbTest("never reaps the VM of an attempt promoted to a persistent runtime", async () => {
    const userId = `retention-promoted-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create an attempt");
      const lease = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "promoted-worker" });
      await repo().recordAttemptProviderHandle({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        providerVmId: "vm-promoted",
        providerWorkspaceId: "workspace-promoted",
        providerTerminalId: "terminal-promoted",
      });
      await repo().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "promoted-succeeded",
        attemptSequence: 1,
        kind: "attempt.succeeded",
        payload: { providerVmId: "vm-promoted" },
      });
      // Promotion (runtimeRepository.promoteAttemptToRuntime) links the attempt to the runtime
      // that now owns this VM and leaves terminal_retain_until as it was.
      const [runtime] = await sql!`insert into cloud_runtimes (owner_team_id, runtime_kind) values (${userId}, 'persistent') returning id`;
      await sql!`update run_attempts set runtime_id = ${runtime!.id} where id = ${attempt.id}`;

      const claims = await repo().claimExpiredAttemptCleanups({ now: new Date(Date.now() + 60 * 60 * 1000), limit: 100 });
      expect(claims.some((claim) => claim.attempt.id === attempt.id)).toBe(false);
      for (const other of claims) {
        await repo().finishAttemptCleanup({ attemptId: other.attempt.id, cleanupLeaseToken: other.cleanupLeaseToken, succeeded: false });
      }
    } finally {
      await removeRuns(userId);
      await sql!`delete from cloud_runtimes where owner_team_id = ${userId}`;
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

  dbTest("schedules cleanup for a VM whose create outlived its lease after a replacement failed the attempt", async () => {
    const userId = `replaced-during-create-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create an attempt");
      const first = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "slow-create-worker" });
      // createVm can outlast the lease, which is not renewed during the create.
      await sql!`update run_attempts set lease_expires_at = now() - interval '1 second' where id = ${attempt.id}`;
      const replacement = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "replacement-worker" });
      // The replacement fails the attempt before recording any VM, then hands
      // off retention: the row is failed, has no VM id, and has a deadline.
      await repo().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: replacement.leaseToken,
        leaseGeneration: replacement.leaseGeneration,
        externalId: "replacement-failed",
        attemptSequence: 0,
        kind: "attempt.failed",
        payload: { error: "replacement gave up" },
      });
      await repo().scheduleAttemptRetention({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: replacement.leaseToken,
        leaseGeneration: replacement.leaseGeneration,
      });
      const failed = (await repo().getRun(created.run.id, userId)).attempts[0];
      expect(failed?.status).toBe("failed");
      expect(failed?.providerVmId).toBeNull();
      expect(failed?.terminalRetainUntil).not.toBeNull();

      // The first worker's create returns. Its writes are fenced, and its
      // finally block hands the VM to retention.
      await expect(repo().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: first.leaseToken,
        leaseGeneration: first.leaseGeneration,
        externalId: "attempt-started",
        attemptSequence: 1,
        kind: "attempt.started",
        payload: { providerVmId: "vm-outlived-lease" },
      })).rejects.toBeInstanceOf(repo().RunLeaseConflictError);
      const handoff = {
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: first.leaseToken,
        leaseGeneration: first.leaseGeneration,
        providerVmId: "vm-outlived-lease",
      };
      await repo().scheduleAttemptRetention(handoff);

      const adopted = (await repo().getRun(created.run.id, userId)).attempts[0];
      expect(adopted?.status).toBe("failed");
      expect(adopted?.providerVmId).toBe("vm-outlived-lease");
      const claims = await repo().claimExpiredAttemptCleanups({ now: new Date(Date.now() + 60 * 60 * 1000), limit: 100 });
      const claim = claims.find((candidate) => candidate.attempt.id === attempt.id);
      expect(claim?.attempt.providerVmId).toBe("vm-outlived-lease");
      for (const other of claims) {
        await repo().finishAttemptCleanup({ attemptId: other.attempt.id, cleanupLeaseToken: other.cleanupLeaseToken, succeeded: other === claim });
      }

      // The reaper destroyed the adopted VM; a repeated handoff cannot adopt it again.
      await expect(repo().scheduleAttemptRetention(handoff)).rejects.toBeInstanceOf(repo().RunLeaseConflictError);
      const reaped = (await repo().getRun(created.run.id, userId)).attempts[0];
      expect(reaped?.providerVmId).toBeNull();
      expect(reaped?.terminalRetainUntil).toBeNull();
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
