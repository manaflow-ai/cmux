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
import { RuntimeAttemptConflictError } from "../services/vms/runtimeRepository";

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

async function succeededAttempt() {
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
  return { run, attempt, handles };
}

function promote(runId: string, attemptId: string, requestKey: string) {
  return promoteRunAttempt({
    userId: owner,
    runId,
    attemptId,
    requestKey,
    dependencies: {
      source: runRepositoryPromotionSource(),
      store: createRunAttemptPromotionStore(),
      runtime: createRuntimePromotionAdapter(),
    },
  });
}

dbTest("promotes a successful fan-out attempt into a persistent Runtime and replays", async () => {
  const { run, attempt, handles } = await succeededAttempt();
  if (!db) throw new Error("test database not initialized");
  const requestKey = `promote-${randomUUID()}`;
  const promotion = await promote(run.run.id, attempt.id, requestKey);
  expect(promotion.workspace.kind).toBe("persistent-devbox");
  expect(promotion.attach.sessionId).toMatch(/^session_/);
  expect(JSON.stringify(promotion)).not.toContain(handles.providerVmId);

  const replay = await promote(run.run.id, attempt.id, requestKey);
  expect(replay).toEqual(promotion);
  const snapshot = await getRun(run.run.id, owner);
  expect(snapshot.attempts[0].runtimeId).toBe(promotion.runtime.id);
  const [workspace] = await db`select lifecycle, provider_vm_id, provider_workspace_id from cloud_runtime_workspaces where runtime_id = ${promotion.runtime.id}`;
  expect(workspace).toMatchObject({ lifecycle: "running", provider_vm_id: handles.providerVmId, provider_workspace_id: handles.providerWorkspaceId });
});

dbTest("a refused promotion releases its runtime, so a later request can promote", async () => {
  const { run, attempt } = await succeededAttempt();
  if (!db) throw new Error("test database not initialized");
  // The retention reaper holds the attempt's cleanup lease, so the runtime repository refuses it.
  await db`update run_attempts set cleanup_lease_token = ${randomUUID()}, cleanup_lease_expires_at = now() + interval '5 minutes' where id = ${attempt.id}`;
  const refusedKey = `promote-${randomUUID()}`;
  let refused: unknown;
  try {
    await promote(run.run.id, attempt.id, refusedKey);
  } catch (error) {
    refused = error;
  }
  expect(refused).toBeInstanceOf(RuntimeAttemptConflictError);
  const orphans = await db`select id from cloud_runtimes r where owner_team_id = ${owner} and lifecycle_state <> 'released'
    and not exists (select 1 from run_attempts a where a.runtime_id = r.id)`;
  expect(orphans).toHaveLength(0);

  // The reaper gave up without destroying the VM; a new request must not collide with the
  // refused one's runtime over the terminal's journal session id.
  await db`update run_attempts set cleanup_lease_token = null, cleanup_lease_expires_at = null where id = ${attempt.id}`;
  const promotion = await promote(run.run.id, attempt.id, `promote-${randomUUID()}`);
  const snapshot = await getRun(run.run.id, owner);
  expect(snapshot.attempts[0].runtimeId).toBe(promotion.runtime.id);
});
