import { afterAll, beforeAll, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  claimAttemptLease,
  createRun,
  createRunAttemptPromotionStore,
  getRun,
  ingestRunEvent,
  recordAttemptProviderHandle,
  requestDigest,
  scheduleAttemptRetention,
} from "../services/runs/repository";
import { promoteRunAttempt, runRepositoryPromotionSource } from "../services/runs/promotion";
import { createRuntimePromotionAdapter } from "../services/runs/runtimePromotion";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
let db: Sql | null = null;
const owner = `runtime-promotion-${randomUUID()}`;

beforeAll(() => {
  if (enabled) db = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 1 });
});

afterAll(async () => {
  if (!db) return;
  await db`delete from runs where user_id = ${owner}`;
  await db`delete from cloud_runtime_workspaces where owner_id = ${owner}`;
  await db`delete from cloud_runtimes where owner_team_id = ${owner}`;
  await closeCloudDbForTests();
  await db.end();
});

dbTest("promotes a successful fan-out attempt into a persistent Runtime and replays", async () => {
  const run = await createRun({
    userId: owner,
    billingTeamId: owner,
    idempotencyKey: `run-${randomUUID()}`,
    requestDigest: requestDigest({ owner }),
    source: { repository: "cmux/test", commit: "0123456789abcdef0123456789abcdef01234567" },
    recipe: "test",
    provider: "cloud-vm",
    desiredAttempts: 1,
  });
  const attempt = run.attempts[0];
  const lease = await claimAttemptLease({
    runId: run.run.id,
    attemptId: attempt.id,
    workerId: `worker-${owner}`,
    ttlMs: 60_000,
  });
  const handles = {
    providerVmId: `vm-${randomUUID()}`,
    providerWorkspaceId: `workspace-${randomUUID()}`,
    providerTerminalId: `terminal-${randomUUID()}`,
  };
  await recordAttemptProviderHandle({
    runId: run.run.id,
    attemptId: attempt.id,
    leaseToken: lease.leaseToken,
    leaseGeneration: lease.leaseGeneration,
    ...handles,
  });
  await ingestRunEvent({
    runId: run.run.id,
    attemptId: attempt.id,
    leaseToken: lease.leaseToken,
    leaseGeneration: lease.leaseGeneration,
    externalId: "started",
    attemptSequence: 0,
    kind: "attempt.started",
    payload: { providerVmId: handles.providerVmId },
  });
  await ingestRunEvent({
    runId: run.run.id,
    attemptId: attempt.id,
    leaseToken: lease.leaseToken,
    leaseGeneration: lease.leaseGeneration,
    externalId: "succeeded",
    attemptSequence: 1,
    kind: "attempt.succeeded",
    payload: { providerVmId: handles.providerVmId, evidenceVerified: true },
  });
  await scheduleAttemptRetention({
    runId: run.run.id,
    attemptId: attempt.id,
    leaseToken: lease.leaseToken,
    leaseGeneration: lease.leaseGeneration,
    providerVmId: handles.providerVmId,
  });
  if (!db) throw new Error("test database not initialized");
  await db`update run_attempts set result = ${JSON.stringify({ evidenceVerified: true })}::jsonb where id = ${attempt.id}`;

  const requestKey = `promote-${randomUUID()}`;
  const promotion = await promoteRunAttempt({
    userId: owner,
    runId: run.run.id,
    attemptId: attempt.id,
    requestKey,
    dependencies: {
      source: runRepositoryPromotionSource(),
      store: createRunAttemptPromotionStore(),
      runtime: createRuntimePromotionAdapter(),
    },
  });
  expect(promotion.workspace.kind).toBe("persistent-devbox");
  expect(promotion.attach.sessionId).toMatch(/^session_/);
  expect(JSON.stringify(promotion)).not.toContain(handles.providerVmId);

  const replay = await promoteRunAttempt({
    userId: owner,
    runId: run.run.id,
    attemptId: attempt.id,
    requestKey,
    dependencies: {
      source: runRepositoryPromotionSource(),
      store: createRunAttemptPromotionStore(),
      runtime: createRuntimePromotionAdapter(),
    },
  });
  expect(replay).toEqual(promotion);
  const snapshot = await getRun(run.run.id, owner);
  expect(snapshot.attempts[0].runtimeId).toBe(promotion.runtime.id);
  const [workspace] = await db`select lifecycle, provider_vm_id, provider_workspace_id from cloud_runtime_workspaces where runtime_id = ${promotion.runtime.id}`;
  expect(workspace).toMatchObject({ lifecycle: "running", provider_vm_id: handles.providerVmId, provider_workspace_id: handles.providerWorkspaceId });
});
