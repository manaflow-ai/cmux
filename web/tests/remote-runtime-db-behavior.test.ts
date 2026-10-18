import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests, cloudDb } from "../db/client";
import { requestDigest as brokerRequestDigest, AGENT_BROKER_PROTOCOL_VERSION, type AgentBrokerEnvelope } from "../services/agent-broker/model";
import * as brokerRepository from "../services/agent-broker/repository";
import { DrizzleVmHostLeaseStore } from "../services/vms/hostLeaseStore";
import {
  RegisteredHostLeaseAdapter,
  VmHostLeaseTransport,
  type VmHostLeaseProvider,
  type VmHostLeaseProviderClient,
} from "../services/vms/hostLeaseTransport";
import {
  attachAttemptToRuntime,
  createRuntime,
  getRuntime,
  leaseRuntime,
  RuntimeLeaseConflictError,
  updateRuntime,
} from "../services/vms/runtimeRepository";
import { persistentWorkspaceStoreFromRuntime } from "../services/vms/runtimeWorkspaceStore";
import { createPersistentWorkspaceService, type PersistentWorkspaceProvider } from "../services/vms/persistentWorkspace";
import { createRun, requestDigest as runRequestDigest } from "../services/runs/repository";
import { createRunAttemptPromotionStore } from "../services/runs/promotionRepository";
import {
  promoteRunAttempt,
  PromotionIdempotencyConflictError,
  PromotionInProgressError,
  runRepositoryPromotionSource,
} from "../services/runs/promotion";
import { createRuntimePromotionAdapter } from "../services/runs/runtimePromotion";

// These are opt-in because the suite mutates a real tenant database. The
// normal local test command leaves them skipped; run-db-behavior-tests enables
// CMUX_DB_TEST and supplies a disposable Postgres or PlanetScale URL.
const databaseUrl = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
const dbEnabled = process.env.CMUX_DB_TEST === "1";
const dbTest = dbEnabled ? test : test.skip;
let sql: Sql | null = null;

beforeAll(() => {
  if (!dbEnabled) return;
  if (!databaseUrl) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseUrl, { max: 8 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end({ timeout: 5 });
});

function brokerEnvelope(tenantId: string, hostClass: string, effectKey: string): AgentBrokerEnvelope {
  const payload = { operation: "build", hostClass, fixture: "cross-host" };
  return {
    protocolVersion: AGENT_BROKER_PROTOCOL_VERSION,
    tenantId,
    effectKey,
    requestDigest: brokerRequestDigest(payload),
    owner: "remote-runtime-db-test",
    sourceSha: "sha256:cross-host-fixture",
    scopeRevision: "db-test-1",
    hostClass,
    payload,
  };
}

type ProviderFixture = {
  readonly provider: VmHostLeaseProvider;
  readonly hostId: string;
  readonly calls: string[];
};

function providerFixture(provider: VmHostLeaseProvider, hostId: string): ProviderFixture & { readonly client: VmHostLeaseProviderClient } {
  const calls: string[] = [];
  const client: VmHostLeaseProviderClient = {
    async acquire(input) {
      calls.push(`${input.provider}:acquire:${input.effectKey}`);
      return { providerLeaseId: `${input.provider}-provider-lease`, generation: input.generation, expiresAtMs: input.nowMs + input.ttlMs };
    },
    async renew(input) {
      calls.push(`${input.provider}:renew:${input.effectKey}`);
      return { providerLeaseId: `${input.provider}-provider-lease`, generation: input.generation, expiresAtMs: input.nowMs + input.ttlMs };
    },
    async release(input) {
      calls.push(`${input.provider}:release:${input.effectKey}`);
      return { providerLeaseId: `${input.provider}-provider-lease`, generation: input.generation, expiresAtMs: input.nowMs };
    },
  };
  return { provider, hostId, calls, client };
}

async function deleteRunsFor(userId: string): Promise<void> {
  if (!sql) return;
  await sql`delete from runs where user_id = ${userId}`;
}

async function createTestRun(userId: string, billingTeamId = userId): Promise<{ runId: string; attemptId: string }> {
  const source = { repository: "manaflow-ai/cmux", ref: "main", commit: "a".repeat(40) };
  const created = await createRun({
    userId,
    billingTeamId,
    idempotencyKey: `remote-runtime-run-${randomUUID()}`,
    requestDigest: runRequestDigest({ source, recipe: "parallel-review", desiredAttempts: 1 }),
    source,
    recipe: "parallel-review",
    desiredAttempts: 1,
  });
  const attempt = created.attempts[0];
  if (!attempt) throw new Error("run did not create an attempt");
  await sql!`update run_attempts
    set status = 'succeeded',
        provider_vm_id = ${`fixture-vm-${randomUUID()}`},
        provider_workspace_id = ${`fixture-workspace-${randomUUID()}`},
        provider_terminal_id = ${`fixture-terminal-${randomUUID()}`},
        terminal_retain_until = now() + interval '10 minutes',
        result = ${JSON.stringify({ evidenceReady: true, fixture: "cross-host" })}::jsonb,
        updated_at = now()
    where id = ${attempt.id} and run_id = ${created.run.id}`;
  return { runId: created.run.id, attemptId: attempt.id };
}

describe("remote broker and VM host leases on a live database", () => {
  dbTest("deduplicates broker effects, fences stale claims, and replays receipts across hosts", async () => {
    const tenantId = `remote-broker-${randomUUID()}`;
    const hosts = ["huge-blue", "freestyle-vm", "mac-mini"] as const;
    try {
      for (const [index, host] of hosts.entries()) {
        const hostClass = `test:${tenantId}:${host}`;
        const envelope = brokerEnvelope(tenantId, hostClass, `broker-effect-${hostClass}-${randomUUID()}`);
        const first = await brokerRepository.enqueueJob(envelope, new Date(`2026-10-17T10:00:0${index}.000Z`));
        const replay = await brokerRepository.enqueueJob(envelope);
        expect(replay.id).toBe(first.id);
        const firstLease = await brokerRepository.claimJob({ workerId: `${hostClass}-worker-a`, hostClass, ttlMs: 5_000, now: new Date("2026-10-17T10:00:10.000Z") });
        expect(firstLease?.job.id).toBe(first.id);
        if (!firstLease) throw new Error(`no lease returned for ${hostClass}`);
        const takeover = await brokerRepository.claimJob({ workerId: `${hostClass}-worker-b`, hostClass, ttlMs: 5_000, now: new Date("2026-10-17T10:00:16.000Z") });
        expect(takeover?.leaseGeneration).toBe(firstLease.leaseGeneration + 1);
        if (!takeover) throw new Error(`no takeover returned for ${hostClass}`);
        await expect(brokerRepository.completeJob({
          jobId: first.id,
          leaseToken: firstLease.leaseToken,
          leaseGeneration: firstLease.leaseGeneration,
          result: { stale: true },
          now: new Date("2026-10-17T10:00:17.000Z"),
        })).rejects.toBeInstanceOf(brokerRepository.AgentBrokerLeaseConflictError);
        await brokerRepository.completeJob({
          jobId: first.id,
          leaseToken: takeover.leaseToken,
          leaseGeneration: takeover.leaseGeneration,
          result: { hostClass, ok: true },
          now: new Date("2026-10-17T10:00:18.000Z"),
        });
        const receipts = await brokerRepository.listJobReceipts({ jobId: first.id, tenantId });
        expect(receipts.receipts.map((receipt) => receipt.state)).toEqual(["queued", "leased", "leased", "completed"]);
      }
    } finally {
      await sql!`delete from agent_broker_jobs where tenant_id = ${tenantId}`;
    }
  });

  dbTest("persists and fences host lease operations for Huge Blue, Freestyle, and Mac mini", async () => {
    const ownerId = `lease-coordinator-${randomUUID()}`;
    const fixtures = [
      providerFixture("huge-blue", `huge-blue:fixture-${randomUUID()}`),
      providerFixture("freestyle", `freestyle:fixture-${randomUUID()}`),
      providerFixture("mac-mini", `mac-mini:fixture-${randomUUID()}`),
    ];
    try {
      for (const fixture of fixtures) {
        const transport = new VmHostLeaseTransport(
          new DrizzleVmHostLeaseStore(),
          new Map([[fixture.provider, new RegisteredHostLeaseAdapter(fixture.provider, fixture.client)]]),
        );
        const input = {
          provider: fixture.provider,
          leaseId: `lease-${fixture.provider}-${randomUUID()}`,
          hostId: fixture.hostId,
          ownerId,
          generation: 1,
          ttlMs: 5_000,
          effectKey: `acquire-${fixture.provider}-${randomUUID()}`,
          nowMs: 1_000,
        } as const;
        const acquired = await transport.acquire(input);
        const replay = await transport.acquire({ ...input, nowMs: 1_100 });
        expect(acquired.replayed).toBe(false);
        expect(replay.replayed).toBe(true);
        expect(replay.provider).toBe(fixture.provider);
        const released = await transport.release({ ...input, effectKey: `release-${fixture.provider}-${randomUUID()}`, nowMs: 1_200 });
        expect(released.state).toBe("released");
        await expect(transport.renew({ ...input, effectKey: `late-renew-${fixture.provider}-${randomUUID()}`, nowMs: 1_300 }))
          .rejects.toMatchObject({ code: "lease_expired" });
        expect(fixture.calls).toEqual([
          `${fixture.provider}:acquire:${input.effectKey}`,
          `${fixture.provider}:release:${released.effectKey}`,
        ]);
        const rows = await sql!`select state, generation from cloud_vm_host_leases where host_id = ${fixture.hostId} and lease_id = ${input.leaseId}`;
        expect(rows).toHaveLength(1);
        expect(rows[0]?.state).toBe("released");
        expect(rows[0]?.generation).toBe(1);
      }
    } finally {
      for (const fixture of fixtures) {
        await sql!`delete from cloud_vm_host_lease_operations where host_id = ${fixture.hostId}`;
        await sql!`delete from cloud_vm_host_leases where host_id = ${fixture.hostId}`;
      }
    }
  });
});

describe("durable runtime/workspace lifecycle on a live database", () => {
  dbTest("creates a runtime, persists a provider workspace, and attaches one run attempt", async () => {
    const ownerTeamId = `runtime-team-${randomUUID()}`;
    const ownerId = `runtime-owner-${randomUUID()}`;
    let runtimeId: string | null = null;
    let runId: string | null = null;
    try {
      const runtime = await createRuntime({ ownerTeamId, kind: "persistent", lifecycleState: "provisioning", idempotencyKey: "runtime-create-1" });
      runtimeId = runtime.id;
      expect((await createRuntime({ ownerTeamId, kind: "persistent", lifecycleState: "provisioning", idempotencyKey: "runtime-create-1" })).id).toBe(runtime.id);
      const running = await updateRuntime({ ownerTeamId, runtimeId: runtime.id, lifecycleState: "running" });
      expect(running.lifecycleState).toBe("running");
      const lease = await leaseRuntime({ ownerTeamId, runtimeId: runtime.id, expectedLeaseGeneration: 0, ttlMs: 30_000 });
      expect(lease.leaseGeneration).toBe(1);
      await expect(updateRuntime({ ownerTeamId, runtimeId: runtime.id, lifecycleState: "stopped", expectedLeaseGeneration: 0 }))
        .rejects.toBeInstanceOf(RuntimeLeaseConflictError);

      const calls: string[] = [];
      const provider: PersistentWorkspaceProvider = {
        async create(input) {
          calls.push(`create:${input.workspaceKey}`);
          return { providerVmId: "freestyle-fixture-vm", providerWorkspaceId: "freestyle-fixture-workspace", providerTerminalId: "freestyle-fixture-terminal" };
        },
        async resume(input) { calls.push(`resume:${input.providerVmId}`); },
        async suspend(input) { calls.push(`suspend:${input.providerVmId}`); },
        async stop(input) { calls.push(`stop:${input.providerVmId}`); },
      };
      const service = createPersistentWorkspaceService({ store: persistentWorkspaceStoreFromRuntime(), provider });
      const workspace = await service.create({ tenantId: ownerTeamId, ownerId, idempotencyKey: "workspace-create-1", workspaceName: "Cross-host fixture" });
      expect(workspace.lifecycle).toBe("running");
      expect((await service.create({ tenantId: ownerTeamId, ownerId, idempotencyKey: "workspace-create-1", workspaceName: "Cross-host fixture" })).runtimeId).toBe(workspace.runtimeId);
      const suspended = await service.suspend({ tenantId: ownerTeamId, ownerId, runtimeId: workspace.runtimeId });
      expect(suspended.lifecycle).toBe("suspended");
      const resumed = await service.resume({ tenantId: ownerTeamId, ownerId, runtimeId: workspace.runtimeId });
      expect(resumed.lifecycle).toBe("running");
      expect(calls.filter((call) => call.startsWith("create:")).length).toBe(1);

      const run = await createTestRun(ownerId, ownerTeamId);
      runId = run.runId;
      const attached = await attachAttemptToRuntime({ ownerTeamId, runId: run.runId, attemptId: run.attemptId, runtimeId: workspace.runtimeId });
      expect(attached.runtimeId).toBe(workspace.runtimeId);
      const persisted = await sql!`select runtime_id from run_attempts where id = ${run.attemptId}`;
      expect(persisted[0]?.runtime_id).toBe(workspace.runtimeId);
      expect((await service.get({ tenantId: ownerTeamId, ownerId, runtimeId: workspace.runtimeId })).attachable).toBe(true);
    } finally {
      if (runId) await deleteRunsFor(ownerId);
      if (sql) {
        await sql!`delete from cloud_runtime_workspaces where owner_team_id = ${ownerTeamId}`;
        await sql!`delete from cloud_runtimes where owner_team_id = ${ownerTeamId}`;
      }
      void runtimeId;
    }
  });
});

describe("run attempt promotion durability on a live database", () => {
  dbTest("replays promotions and fences a pending or wrong-target idempotency key", async () => {
    const userId = `promotion-owner-${randomUUID()}`;
    const billingTeamId = `promotion-team-${randomUUID()}`;
    let firstRun: { runId: string; attemptId: string } | null = null;
    let secondRun: { runId: string; attemptId: string } | null = null;
    try {
      firstRun = await createTestRun(userId, billingTeamId);
      const requestKey = `promotion-${randomUUID()}`;
      const dependencies = {
        source: runRepositoryPromotionSource(),
        store: createRunAttemptPromotionStore(),
        runtime: createRuntimePromotionAdapter(),
      };
      const first = await promoteRunAttempt({ userId, runId: firstRun.runId, attemptId: firstRun.attemptId, requestKey, dependencies });
      const replay = await promoteRunAttempt({ userId, runId: firstRun.runId, attemptId: firstRun.attemptId, requestKey, dependencies });
      expect(replay).toEqual(first);
      const attached = await sql!`select runtime_id from run_attempts where id = ${firstRun.attemptId}`;
      expect(attached[0]?.runtime_id).toBe(first.runtime.id);

      secondRun = await createTestRun(userId, billingTeamId);
      const reservation = await dependencies.store.reserve({ userId, runId: secondRun.runId, attemptId: secondRun.attemptId, requestKey: `pending-${requestKey}` });
      expect(reservation.kind).toBe("reserved");
      if (reservation.kind !== "reserved") throw new Error("promotion reservation was not created");
      await expect(promoteRunAttempt({ userId, runId: secondRun.runId, attemptId: secondRun.attemptId, requestKey: `pending-${requestKey}`, dependencies }))
        .rejects.toBeInstanceOf(PromotionInProgressError);
      await dependencies.store.release(reservation.reservation);
      const second = await promoteRunAttempt({ userId, runId: secondRun.runId, attemptId: secondRun.attemptId, requestKey: `pending-${requestKey}`, dependencies });
      expect(second.runtime.id).not.toBe(first.runtime.id);

      await expect(promoteRunAttempt({ userId, runId: secondRun.runId, attemptId: secondRun.attemptId, requestKey, dependencies }))
        .rejects.toBeInstanceOf(PromotionIdempotencyConflictError);
    } finally {
      await deleteRunsFor(userId);
      if (sql) {
        await sql!`delete from cloud_runtime_workspaces where owner_team_id = ${billingTeamId}`;
        await sql!`delete from cloud_runtimes where owner_team_id = ${billingTeamId}`;
      }
    }
  });
});
