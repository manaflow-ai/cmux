import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { artifactDigest } from "../services/runs/model";
import type { Sql } from "postgres";
import type * as RunRepository from "../services/runs/repository";

const dbEnabled = process.env.CMUX_DB_TEST === "1";
const dbTest = dbEnabled ? test : test.skip;
let sql: Sql | null = null;
let repository: typeof RunRepository | null = null;

function databaseURL(): string {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  return url;
}

beforeAll(async () => {
  if (!dbEnabled) return;
  const [{ default: postgres }, loaded] = await Promise.all([
    import("postgres"),
    import("../services/runs/repository"),
  ]);
  sql = postgres(databaseURL(), { max: 1 });
  repository = loaded;
});

afterAll(async () => {
  if (dbEnabled) await (await import("../db/client")).closeCloudDbForTests();
  await sql?.end();
});

function request(userId: string, recipe = "parallel-review") {
  const value = {
    source: { repository: "manaflow-ai/cmux", commit: "a".repeat(40) },
    recipe,
    desiredAttempts: 2,
  };
  return {
    userId,
    billingTeamId: null,
    idempotencyKey: `run-test-${randomUUID()}`,
    requestDigest: runRepositoryModule().requestDigest(value),
    ...value,
  } as const;
}

function runRepositoryModule(): typeof RunRepository {
  if (!repository) throw new Error("Run repository was not loaded");
  return repository;
}

async function deleteRuns(userId: string): Promise<void> {
  await sql!`delete from runs where user_id = ${userId}`;
}

describe("durable Run repository", () => {
  dbTest("creates attempts once and replays an idempotent request", async () => {
    const userId = `run-test-${randomUUID()}`;
    const input = request(userId);
    try {
      const first = await runRepositoryModule().createRun(input);
      const retry = await runRepositoryModule().createRun(input);
      expect(retry.run.id).toBe(first.run.id);
      expect(retry.attempts.map((attempt) => attempt.ordinal)).toEqual([0, 1]);

      const differentRequest = { ...input, recipe: "different-recipe", requestDigest: runRepositoryModule().requestDigest({ ...input, recipe: "different-recipe" }) };
      await expect(runRepositoryModule().createRun(differentRequest)).rejects.toBeInstanceOf(runRepositoryModule().RunIdempotencyConflictError);
      const events = await runRepositoryModule().listRunEvents({ runId: first.run.id, userId, afterSequence: 0 });
      expect(events.events).toHaveLength(1);
      expect(events.events[0]?.kind).toBe("run.created");
      expect(events.events[0]?.sequence).toBe(1);
    } finally {
      await deleteRuns(userId);
    }
  });

  dbTest("deduplicates event retries and replays the journal in sequence order", async () => {
    const userId = `run-test-${randomUUID()}`;
    const input = request(userId);
    try {
      const created = await runRepositoryModule().createRun(input);
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create attempt 0");
      const lease = await runRepositoryModule().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "worker-a" });
      const output = await runRepositoryModule().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "worker-event-output-1",
        attemptSequence: 1,
        kind: "attempt.output",
        payload: { stream: "stdout", text: "first" },
      });
      const duplicate = await runRepositoryModule().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "worker-event-output-1",
        attemptSequence: 1,
        kind: "attempt.output",
        payload: { stream: "stdout", text: "replayed" },
      });
      expect(duplicate.id).toBe(output.id);
      expect(duplicate.payload).toEqual(output.payload);

      const started = await runRepositoryModule().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "worker-event-started-1",
        attemptSequence: 2,
        kind: "attempt.started",
      });
      const succeeded = await runRepositoryModule().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "worker-event-succeeded-1",
        attemptSequence: 3,
        kind: "attempt.succeeded",
        payload: { summary: "ok" },
      });
      // A late, reordered event from the old worker cannot move a terminal
      // attempt backwards because the terminal receipt clears its lease.
      await expect(runRepositoryModule().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "worker-event-late-started",
        attemptSequence: 4,
        kind: "attempt.started",
      })).rejects.toBeInstanceOf(runRepositoryModule().RunLeaseConflictError);
      const firstPage = await runRepositoryModule().listRunEvents({ runId: created.run.id, userId, afterSequence: 1, limit: 1 });
      expect(firstPage.events.map((event) => event.id)).toEqual([output.id]);
      expect(firstPage.nextSequence).toBe(2);
      const replay = await runRepositoryModule().listRunEvents({ runId: created.run.id, userId, afterSequence: firstPage.nextSequence ?? 0 });
      expect(replay.events.map((event) => event.id)).toEqual([started.id, succeeded.id]);
      expect(replay.events.map((event) => event.sequence)).toEqual([3, 4]);
      expect(replay.nextSequence).toBeNull();
      const snapshot = await runRepositoryModule().getRun(created.run.id, userId);
      expect(snapshot.attempts[0]?.status).toBe("succeeded");
    } finally {
      await deleteRuns(userId);
    }
  });

  dbTest("fences an expired lease before accepting events or artifacts", async () => {
    const userId = `run-test-${randomUUID()}`;
    const input = request(userId);
    try {
      const created = await runRepositoryModule().createRun(input);
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create attempt 0");
      const firstLease = await runRepositoryModule().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "worker-a" });
      const acceptedEvent = await runRepositoryModule().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: firstLease.leaseToken,
        leaseGeneration: firstLease.leaseGeneration,
        externalId: "stale-event",
        attemptSequence: 1,
        kind: "attempt.output",
        payload: { text: "accepted" },
      });
      const bytes = new TextEncoder().encode("artifact");
      const acceptedArtifact = await runRepositoryModule().recordRunArtifact({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: firstLease.leaseToken,
        leaseGeneration: firstLease.leaseGeneration,
        name: "report.txt",
        sizeBytes: bytes.byteLength,
        digest: artifactDigest(bytes),
        uri: "run://stale/report.txt",
        bytes,
      });
      await sql!`update run_attempts set lease_expires_at = now() - interval '1 second' where id = ${attempt.id}`;
      const secondLease = await runRepositoryModule().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "worker-b" });
      expect(secondLease.leaseGeneration).toBe(firstLease.leaseGeneration + 1);
      await expect(runRepositoryModule().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: firstLease.leaseToken,
        leaseGeneration: firstLease.leaseGeneration,
        externalId: "stale-event",
        attemptSequence: 1,
        kind: "attempt.output",
        payload: { text: "stale" },
      })).rejects.toBeInstanceOf(runRepositoryModule().RunLeaseConflictError);
      await expect(runRepositoryModule().recordRunArtifact({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: firstLease.leaseToken,
        leaseGeneration: firstLease.leaseGeneration,
        name: "report.txt",
        sizeBytes: bytes.byteLength,
        digest: artifactDigest(bytes),
        uri: "run://stale/report.txt",
        bytes,
      })).rejects.toBeInstanceOf(runRepositoryModule().RunLeaseConflictError);
      expect(acceptedEvent.payload).toEqual({ text: "accepted" });
      expect(acceptedArtifact.name).toBe("report.txt");
    } finally {
      await deleteRuns(userId);
    }
  });

  dbTest("verifies artifact bytes and makes the manifest immutable by name", async () => {
    const userId = `run-test-${randomUUID()}`;
    const input = request(userId);
    try {
      const created = await runRepositoryModule().createRun(input);
      const attempt = created.attempts[0];
      if (!attempt) throw new Error("run did not create attempt 0");
      const lease = await runRepositoryModule().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "worker-a" });
      const bytes = new TextEncoder().encode("artifact");
      const digest = artifactDigest(bytes);
      const artifact = await runRepositoryModule().recordRunArtifact({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        name: "report.txt",
        mediaType: "text/plain",
        sizeBytes: bytes.byteLength,
        digest,
        uri: "run://artifact/report.txt",
        bytes,
      });
      const retry = await runRepositoryModule().recordRunArtifact({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        name: "report.txt",
        mediaType: "text/plain",
        sizeBytes: bytes.byteLength,
        digest,
        uri: "run://artifact/report.txt",
        bytes,
      });
      expect(retry.id).toBe(artifact.id);
      const changed = new TextEncoder().encode("changed");
      await expect(runRepositoryModule().recordRunArtifact({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        name: "report.txt",
        mediaType: "text/plain",
        sizeBytes: changed.byteLength,
        digest: artifactDigest(changed),
        uri: "run://artifact/changed.txt",
        bytes: changed,
      })).rejects.toBeInstanceOf(runRepositoryModule().RunArtifactConflictError);
      await expect(runRepositoryModule().recordRunArtifact({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        name: "bad.txt",
        sizeBytes: bytes.byteLength,
        digest,
        uri: "run://artifact/bad.txt",
        bytes: changed,
      })).rejects.toThrow("artifact size does not match bytes");
    } finally {
      await deleteRuns(userId);
    }
  });
});

