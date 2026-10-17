import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import type { Sql } from "postgres";
import type * as RunRepository from "../services/runs/repository";

const dbEnabled = process.env.CMUX_DB_TEST === "1";
const dbTest = dbEnabled ? test : test.skip;
let sql: Sql | null = null;
let repository: typeof RunRepository | null = null;

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

function repo(): typeof RunRepository {
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
});
