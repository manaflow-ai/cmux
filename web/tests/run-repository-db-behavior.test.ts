import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { artifactDigest, type RunEventKind } from "../services/runs/model";
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
      // jsonb equality ignores key order, so a re-serialized retry still matches.
      const duplicate = await runRepositoryModule().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "worker-event-output-1",
        attemptSequence: 1,
        kind: "attempt.output",
        payload: { text: "first", stream: "stdout" },
      });
      expect(duplicate.id).toBe(output.id);
      expect(duplicate.payload).toEqual(output.payload);
      expect(Object.keys(duplicate)).not.toContain("writerLeaseTokenHash");
      await expect(runRepositoryModule().ingestRunEvent({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        externalId: "worker-event-output-1",
        attemptSequence: 1,
        kind: "attempt.output",
        payload: { stream: "stdout", text: "replayed" },
      })).rejects.toBeInstanceOf(runRepositoryModule().RunEventConflictError);

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

  // Retry rule: a reused event id or artifact name gets the stored row back
  // only for the lease that wrote it and only for an identical request. Every
  // other reuse is a 409: content conflict for the live holder or the writer,
  // lease conflict for anyone else.

  type Lease = { readonly leaseToken: string; readonly leaseGeneration: number };

  async function replacedLeases(userId: string) {
    const created = await runRepositoryModule().createRun(request(userId));
    const attempt = created.attempts[0];
    if (!attempt) throw new Error("run did not create attempt 0");
    const first = await runRepositoryModule().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "worker-a" });
    const event = (lease: Lease, externalId: string, attemptSequence: number, payload: Record<string, unknown>, kind: RunEventKind = "attempt.output") => runRepositoryModule().ingestRunEvent({
      runId: created.run.id,
      attemptId: attempt.id,
      leaseToken: lease.leaseToken,
      leaseGeneration: lease.leaseGeneration,
      externalId,
      attemptSequence,
      kind,
      payload,
    });
    const replace = async () => {
      await sql!`update run_attempts set lease_expires_at = now() - interval '1 second' where id = ${attempt.id}`;
      return runRepositoryModule().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "worker-b" });
    };
    return { created, attempt, first, event, replace };
  }

  async function attemptEventCount(attemptId: string): Promise<number> {
    const rows = (await sql!`select count(*)::text as count from run_events where attempt_id = ${attemptId}`) as unknown as { count: string }[];
    return Number(rows[0]?.count ?? 0);
  }

  dbTest("answers the writer's identical retry after its lease was replaced, without writing", async () => {
    const userId = `run-test-${randomUUID()}`;
    try {
      const { attempt, first, event, replace } = await replacedLeases(userId);
      const accepted = await event(first, "a-output-1", 1, { text: "accepted" });
      const second = await replace();
      expect(second.leaseGeneration).toBe(first.leaseGeneration + 1);
      const before = await attemptEventCount(attempt.id);

      const retry = await event(first, "a-output-1", 1, { text: "accepted" });
      expect(retry.id).toBe(accepted.id);
      expect(await attemptEventCount(attempt.id)).toBe(before);
      // The same writer cannot change what it wrote under that id.
      await expect(event(first, "a-output-1", 1, { text: "changed" })).rejects.toBeInstanceOf(runRepositoryModule().RunEventConflictError);
    } finally {
      await deleteRuns(userId);
    }
  });

  dbTest("rejects a stale holder's new event after a replacement took the lease", async () => {
    const userId = `run-test-${randomUUID()}`;
    try {
      const { created, attempt, first, event, replace } = await replacedLeases(userId);
      await event(first, "a-output-1", 1, { text: "accepted" });
      const second = await replace();
      await event(second, "b-started", 2, { workerId: "worker-b" }, "attempt.started");

      await expect(event(first, "a-succeeded", 3, { summary: "stale" }, "attempt.succeeded")).rejects.toBeInstanceOf(runRepositoryModule().RunLeaseConflictError);
      // Reusing an id the replacement wrote is fenced before content is compared.
      await expect(event(first, "b-started", 2, { workerId: "worker-b" }, "attempt.started")).rejects.toBeInstanceOf(runRepositoryModule().RunLeaseConflictError);
      const snapshot = await runRepositoryModule().getRun(created.run.id, userId);
      expect(snapshot.attempts.find((row) => row.id === attempt.id)?.status).toBe("running");
      expect(snapshot.attempts.find((row) => row.id === attempt.id)?.leaseGeneration).toBe(second.leaseGeneration);
    } finally {
      await deleteRuns(userId);
    }
  });

  dbTest("does not hand a replacement holder another lease's stored event", async () => {
    const userId = `run-test-${randomUUID()}`;
    try {
      const { created, attempt, first, event, replace } = await replacedLeases(userId);
      await event(first, "attempt-started", 1, { workerId: "worker" }, "attempt.started");
      const second = await replace();
      // An identical id and payload from the live holder is still not its row:
      // returning it would report a start that never happened for this lease.
      await expect(event(second, "attempt-started", 1, { workerId: "worker" }, "attempt.started")).rejects.toBeInstanceOf(runRepositoryModule().RunEventConflictError);
      const snapshot = await runRepositoryModule().getRun(created.run.id, userId);
      expect(snapshot.attempts.find((row) => row.id === attempt.id)?.status).toBe("leased");
    } finally {
      await deleteRuns(userId);
    }
  });

  dbTest("answers an identical terminal retry after the terminal event and the retention handoff cleared the lease", async () => {
    const userId = `run-test-${randomUUID()}`;
    try {
      const { created, attempt, first, event } = await replacedLeases(userId);
      const succeeded = await event(first, "a-succeeded", 1, { summary: "ok" }, "attempt.succeeded");
      const before = await attemptEventCount(attempt.id);

      const afterTerminal = await event(first, "a-succeeded", 1, { summary: "ok" }, "attempt.succeeded");
      expect(afterTerminal.id).toBe(succeeded.id);
      await runRepositoryModule().scheduleAttemptRetention({ runId: created.run.id, attemptId: attempt.id, leaseToken: first.leaseToken, leaseGeneration: first.leaseGeneration });
      const afterRetention = await event(first, "a-succeeded", 1, { summary: "ok" }, "attempt.succeeded");
      expect(afterRetention.id).toBe(succeeded.id);
      expect(await attemptEventCount(attempt.id)).toBe(before);
      // A new id still needs a live lease.
      await expect(event(first, "a-late-output", 2, { text: "late" })).rejects.toBeInstanceOf(runRepositoryModule().RunLeaseConflictError);
      const snapshot = await runRepositoryModule().getRun(created.run.id, userId);
      expect(snapshot.attempts.find((row) => row.id === attempt.id)?.status).toBe("succeeded");
    } finally {
      await deleteRuns(userId);
    }
  });

  dbTest("matches no caller for a stored event with no recorded writer", async () => {
    const userId = `run-test-${randomUUID()}`;
    try {
      const { attempt, first, event, replace } = await replacedLeases(userId);
      await event(first, "legacy-output", 1, { text: "legacy" });
      await sql!`update run_events set writer_lease_generation = null, writer_lease_token_hash = null where attempt_id = ${attempt.id}`;
      await expect(event(first, "legacy-output", 1, { text: "legacy" })).rejects.toBeInstanceOf(runRepositoryModule().RunEventConflictError);
      const second = await replace();
      await expect(event(first, "legacy-output", 1, { text: "legacy" })).rejects.toBeInstanceOf(runRepositoryModule().RunLeaseConflictError);
      await expect(event(second, "legacy-output", 1, { text: "legacy" })).rejects.toBeInstanceOf(runRepositoryModule().RunEventConflictError);
    } finally {
      await deleteRuns(userId);
    }
  });

  dbTest("applies the same retry rule to artifact manifests", async () => {
    const userId = `run-test-${randomUUID()}`;
    try {
      const { created, attempt, first, replace } = await replacedLeases(userId);
      const bytes = new TextEncoder().encode("artifact");
      const manifest = (lease: Lease, name: string, uri = `run://${name}`) => runRepositoryModule().recordRunArtifact({
        runId: created.run.id,
        attemptId: attempt.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        name,
        sizeBytes: bytes.byteLength,
        digest: artifactDigest(bytes),
        uri,
        bytes,
      });
      const accepted = await manifest(first, "report.txt");
      expect(Object.keys(accepted)).not.toContain("writerLeaseTokenHash");
      const writerRows = (await sql!`select writer_lease_generation as generation from run_events where attempt_id = ${attempt.id} and kind = 'attempt.artifact'`) as unknown as { generation: number | null }[];
      expect(writerRows.map((row) => row.generation)).toEqual([first.leaseGeneration]);
      const second = await replace();
      const before = await attemptEventCount(attempt.id);

      expect((await manifest(first, "report.txt")).id).toBe(accepted.id);
      expect(await attemptEventCount(attempt.id)).toBe(before);
      await expect(manifest(first, "report.txt", "run://changed.txt")).rejects.toBeInstanceOf(runRepositoryModule().RunArtifactConflictError);
      await expect(manifest(first, "new.txt")).rejects.toBeInstanceOf(runRepositoryModule().RunLeaseConflictError);
      await expect(manifest(second, "report.txt")).rejects.toBeInstanceOf(runRepositoryModule().RunArtifactConflictError);
      const fresh = await manifest(second, "b-report.txt");
      await expect(manifest(first, "b-report.txt")).rejects.toBeInstanceOf(runRepositoryModule().RunLeaseConflictError);
      expect(fresh.name).toBe("b-report.txt");
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

