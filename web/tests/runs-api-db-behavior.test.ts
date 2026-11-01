import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash, randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import { and, eq } from "drizzle-orm";
import { closeCloudDbForTests, cloudDb } from "../db/client";
import { runAttempts } from "../db/schema";
import {
  createRunRecord,
  readRunSnapshot,
  readRunArtifact,
  RunAdmissionError,
  RunArtifactConflictError,
  RunIdempotencyConflictError,
  storeRunArtifact,
  type RunScope,
} from "../services/runs/legacy/repository";
import { runAttachTicket } from "../services/runs/legacy/attach";
import { normalizeRunSpec, runSpecDigest, type RunSpec } from "../services/runs/legacy/spec";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const COMMIT = "a".repeat(40);
const DIGEST = "sha256:" + "b".repeat(64);
let sqlClient: Sql | null = null;
const cleanupRunIds: string[] = [];

function db(): Sql {
  if (!sqlClient) throw new Error("database test is not initialized");
  return sqlClient;
}

function scope(suffix: string, team = `team-${suffix}`): RunScope {
  return { userId: `user-${suffix}`, ownerTeamId: team };
}

function spec(operationId: string): RunSpec {
  return normalizeRunSpec({
    schema: "cmux.run/v1",
    operationId,
    source: { repository: "manaflow-ai/cmux", ref: "main", commit: COMMIT, setupManifestDigest: DIGEST },
    intent: { digest: DIGEST },
    recipe: { id: "cloud-vm-dogfood", version: 1 },
    variants: [{ id: "default", label: "Default", instructionDigest: DIGEST }],
    workspace: { kind: "ephemeral" },
    resources: { maxAttempts: 1, maxConcurrent: 1, memoryClass: "standard", cpuClass: "standard", wallTimeoutMs: 30_000, retainMs: 30_000 },
    routing: { executionProvider: "cloud-vm", backend: "freestyle" },
    capabilities: { secretRefs: [] },
    checks: [],
    policy: { mode: "fanout", humanApprovalRequired: false, evidenceKinds: ["patch"] },
  });
}

async function create(scopeValue: RunScope, key: string, runSpec = spec(key)) {
  const result = await createRunRecord({
    ...scopeValue,
    billingTeamId: scopeValue.ownerTeamId,
    idempotencyKey: key,
    requestDigest: runSpecDigest(runSpec),
    spec: runSpec,
  });
  cleanupRunIds.push(result.snapshot.run.id);
  return result;
}

async function expectRunHttpError(action: Promise<unknown>, status: number): Promise<void> {
  await expect(action).rejects.toMatchObject({ status });
}

beforeAll(async () => {
  if (!runDbTests) return;
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sqlClient = postgres(url, { max: 4 });
});

afterAll(async () => {
  if (sqlClient) {
    for (const runId of cleanupRunIds) await sqlClient`delete from runs where id = ${runId}::uuid`;
    await sqlClient.end({ timeout: 5 });
  }
  await closeCloudDbForTests();
});

describe("durable Run API database behavior", () => {
  dbTest("serializes same-team idempotency across users and rejects a changed digest", async () => {
    const team = `team-${randomUUID()}`;
    const firstScope = scope(randomUUID(), team);
    const secondScope = scope(randomUUID(), team);
    const key = `same-${randomUUID()}`;
    const firstSpec = spec(`op-${randomUUID()}`);
    const [first, concurrent] = await Promise.all([
      create(firstScope, key, firstSpec),
      create(secondScope, key, firstSpec),
    ]);
    expect(first.snapshot.run.id).toBe(concurrent.snapshot.run.id);
    expect([first.reused, concurrent.reused].sort()).toEqual([false, true]);

    await expect(create(firstScope, key, spec(`changed-${randomUUID()}`))).rejects.toBeInstanceOf(RunIdempotencyConflictError);
    const rows = await db()`select count(*)::int as count from runs where owner_team_id = ${team} and idempotency_key = ${key}`;
    expect(Number(rows[0]?.count)).toBe(1);
  });

  dbTest("keeps runs isolated across teams and preserves ordered event receipts", async () => {
    const key = `cross-${randomUUID()}`;
    const first = await create(scope(randomUUID(), `team-a-${randomUUID()}`), key);
    const second = await create(scope(randomUUID(), `team-b-${randomUUID()}`), key);
    expect(second.snapshot.run.id).not.toBe(first.snapshot.run.id);
    expect((await readRunSnapshot(first.snapshot.run.id, scope(randomUUID(), first.snapshot.run.ownerTeamId!)))?.run.id).toBe(first.snapshot.run.id);
    expect(await readRunSnapshot(first.snapshot.run.id, scope(randomUUID(), second.snapshot.run.ownerTeamId!))).toBeNull();
    expect(first.snapshot.events.map((event) => [event.sequence, event.kind])).toEqual([
      [0, "run.created"],
      [1, "attempt.queued"],
    ]);
  });

  dbTest("enforces the bounded queued/running admission cap per team", async () => {
    const team = `team-cap-${randomUUID()}`;
    for (let index = 0; index < 16; index += 1) {
      await create(scope(randomUUID(), team), `cap-${index}-${randomUUID()}`);
    }
    await expect(create(scope(randomUUID(), team), `cap-overflow-${randomUUID()}`)).rejects.toBeInstanceOf(RunAdmissionError);
  });

  dbTest("stores an artifact immutably by attempt/name", async () => {
    const created = await create(scope(randomUUID()), `artifact-${randomUUID()}`);
    const attemptId = created.snapshot.attempts[0].id;
    await storeRunArtifact({ runId: created.snapshot.run.id, attemptId, name: "receipt.json", payload: { value: "first" } });
    await expect(storeRunArtifact({ runId: created.snapshot.run.id, attemptId, name: "receipt.json", payload: { value: "second" } })).rejects.toBeInstanceOf(RunArtifactConflictError);
    const snapshot = await readRunSnapshot(created.snapshot.run.id, scope(created.snapshot.run.userId, created.snapshot.run.ownerTeamId!));
    expect(snapshot?.artifacts).toHaveLength(1);
    expect(snapshot?.artifacts[0]?.payload).toEqual({ value: "first" });
    const expectedDigest = createHash("sha256").update(JSON.stringify({ value: "first" })).digest("hex");
    expect(snapshot?.artifacts[0]?.digest).toBe(`sha256:${expectedDigest}`);
  });

  dbTest("persists a canonical receipt digest across JSONB key reordering and idempotent replay", async () => {
    const owner = scope(randomUUID());
    const created = await create(owner, `artifact-canonical-${randomUUID()}`);
    const { id: runId } = created.snapshot.run;
    const attemptId = created.snapshot.attempts[0]!.id;
    await storeRunArtifact({ runId, attemptId, name: "receipt.json", payload: { z: 1, a: 2 } });
    await storeRunArtifact({ runId, attemptId, name: "receipt.json", payload: { a: 2, z: 1 } });
    const snapshot = await readRunSnapshot(runId, owner);
    expect(snapshot?.artifacts).toHaveLength(1);
    const persisted = snapshot?.artifacts[0];
    const canonicalBody = '{"a":2,"z":1}';
    expect(persisted?.digest).toBe(`sha256:${createHash("sha256").update(canonicalBody).digest("hex")}`);
    expect(persisted?.sizeBytes).toBe(Buffer.byteLength(canonicalBody, "utf8"));
    expect(await readRunArtifact({ ...owner, runId, artifactId: persisted!.id })).toMatchObject({
      digest: persisted?.digest, sizeBytes: persisted?.sizeBytes,
    });
  });

  dbTest("scopes Run artifact reads to the matching visible run and immutable artifact id", async () => {
    const originalOwner = scope(randomUUID(), `team-a-${randomUUID()}`);
    const otherOwner = scope(randomUUID(), `team-b-${randomUUID()}`);
    const first = await create(originalOwner, `artifact-read-${randomUUID()}`);
    const second = await create(otherOwner, `artifact-read-${randomUUID()}`);
    const attemptId = first.snapshot.attempts[0]!.id;
    await storeRunArtifact({
      runId: first.snapshot.run.id,
      attemptId,
      name: "receipt.json",
      payload: { status: "done", report: { alpha: 1, beta: 2 } },
    });
    const ownSnapshot = await readRunSnapshot(first.snapshot.run.id, originalOwner);
    const artifactId = ownSnapshot?.artifacts[0]?.id;
    expect(artifactId).toBeDefined();
    const permitted = await readRunArtifact({ ...originalOwner, runId: first.snapshot.run.id, artifactId: artifactId! });
    expect(permitted?.payload).toEqual({ status: "done", report: { alpha: 1, beta: 2 } });
    expect(await readRunArtifact({ ...otherOwner, runId: first.snapshot.run.id, artifactId: artifactId! })).toBeNull();
    expect(await readRunArtifact({ ...originalOwner, runId: second.snapshot.run.id, artifactId: artifactId! })).toBeNull();
    expect(await readRunArtifact({ ...originalOwner, runId: first.snapshot.run.id, artifactId: randomUUID() })).toBeNull();
    // Provider teardown and terminal attach expiry must leave retained artifact bytes addressable.
    await cloudDb().update(runAttempts)
      .set({ cleanupState: "deleted", providerVmId: null, retainedUntil: null })
      .where(and(eq(runAttempts.runId, first.snapshot.run.id), eq(runAttempts.id, attemptId)));
    expect(await readRunArtifact({ ...originalOwner, runId: first.snapshot.run.id, artifactId: artifactId! }))
      .toMatchObject({ id: artifactId });
  });

  dbTest("requires the owning identity for attach tickets, enforces TTL, and allows one redemption", async () => {
    const owner = scope(randomUUID());
    const created = await create(owner, `attach-${randomUUID()}`);
    const attemptId = created.snapshot.attempts[0].id;
    const retainedUntil = new Date(Date.now() + 60_000);
    await cloudDb().update(runAttempts).set({ providerVmId: `vm-${randomUUID()}`, cleanupState: "retained", retainedUntil }).where(and(eq(runAttempts.runId, created.snapshot.run.id), eq(runAttempts.id, attemptId)));

    const minted = await runAttachTicket({ ...owner, runId: created.snapshot.run.id, attemptId, ttlMs: 30_000 });
    expect(minted.redeemed).toBe(false);
    await expectRunHttpError(runAttachTicket({ ...scope(randomUUID(), owner.ownerTeamId), runId: created.snapshot.run.id, attemptId, ticket: minted.ticket }), 410);
    const redeemed = await runAttachTicket({ ...owner, runId: created.snapshot.run.id, attemptId, ticket: minted.ticket });
    expect(redeemed.redeemed).toBe(true);
    await expectRunHttpError(runAttachTicket({ ...owner, runId: created.snapshot.run.id, attemptId, ticket: minted.ticket }), 410);

    const expired = await runAttachTicket({ ...owner, runId: created.snapshot.run.id, attemptId, ttlMs: 1_000 });
    const expiredDigest = createHash("sha256").update(expired.ticket).digest("hex");
    await db()`update run_attach_tickets set expires_at = now() - interval '1 second' where digest = ${expiredDigest}`;
    await expectRunHttpError(runAttachTicket({ ...owner, runId: created.snapshot.run.id, attemptId, ticket: expired.ticket }), 410);
  });
});
