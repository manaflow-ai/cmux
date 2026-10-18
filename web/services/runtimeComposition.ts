import { randomUUID } from "node:crypto";

import { and, eq, sql } from "drizzle-orm";

import { cloudDb } from "../db/client";
import { persistentWorkspaces, runAttemptPromotions } from "../db/schema";
import {
  configurePersistentWorkspaceService,
  createPersistentWorkspacePromotionRuntimePort,
  createPersistentWorkspaceService,
  persistentWorkspaceProviderFromCloudVm,
  type PersistentWorkspaceProvider,
  type PersistentWorkspaceRecord,
  type PersistentWorkspaceStore,
} from "./vms/persistentWorkspace";
import { CloudVmRunAdapter } from "./vms/cloudVmRunAdapter";
import { getProvider } from "./vms/drivers";
import { DrizzleVmHostLeaseStore } from "./vms/hostLeaseStore";
import {
  createConfiguredHostLeaseAdapters,
  createHugeBlueHostLeaseHttpClient,
  VmHostLeaseTransport,
} from "./vms/hostLeaseTransport";
import { createAgentBrokerLifecycleEffectBroker } from "./vms/lifecycleEffectBroker";
import {
  installRunAttemptPromotionDependencies,
  runRepositoryPromotionSource,
  type AttemptPromotionDependencies,
  type AttemptPromotionStorePort,
  type PromotionView,
} from "./runs/promotion";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DIGEST = /^sha256:[0-9a-f]{64}$/i;

type PersistentWorkspaceRow = typeof persistentWorkspaces.$inferSelect;
type PromotionRow = typeof runAttemptPromotions.$inferSelect;

function requireUuid(value: string, label: string): string {
  if (!UUID.test(value)) throw new Error(`${label} must be a UUID`);
  return value;
}

function workspaceRecord(row: PersistentWorkspaceRow): PersistentWorkspaceRecord {
  if (row.provider !== "freestyle") throw new Error(`unsupported persistent workspace provider ${row.provider}`);
  return {
    runtimeId: requireUuid(row.id, "persistent workspace runtime id"),
    workspaceId: requireUuid(row.workspaceId, "persistent workspace id"),
    tenantId: row.tenantId,
    ownerId: row.ownerId,
    provider: "freestyle",
    lifecycle: row.lifecycle as PersistentWorkspaceRecord["lifecycle"],
    providerVmId: row.providerVmId,
    providerWorkspaceId: row.providerWorkspaceId,
    providerTerminalId: row.providerTerminalId,
    idempotencyKey: row.idempotencyKey,
    requestDigest: row.requestDigest,
    workspaceName: row.workspaceName,
    failureCode: row.failureCode,
    failureMessage: row.failureMessage,
    version: row.version,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

/** Database-backed store for the persistent workspace lifecycle service. */
export class DrizzlePersistentWorkspaceStore implements PersistentWorkspaceStore {
  async createRuntime(input: { readonly record: PersistentWorkspaceRecord }): Promise<{ readonly record: PersistentWorkspaceRecord; readonly created: boolean }> {
    const record = input.record;
    requireUuid(record.runtimeId, "runtimeId");
    requireUuid(record.workspaceId, "workspaceId");
    return cloudDb().transaction(async (tx) => {
      const existing = (await tx.select().from(persistentWorkspaces).where(and(
        eq(persistentWorkspaces.tenantId, record.tenantId),
        eq(persistentWorkspaces.idempotencyKey, record.idempotencyKey),
      )).for("update").limit(1))[0];
      if (existing) {
        if (existing.requestDigest !== record.requestDigest) {
          throw new Error("persistent workspace idempotency key was already used for a different request");
        }
        return { record: workspaceRecord(existing), created: false };
      }
      const [inserted] = await tx.insert(persistentWorkspaces).values({
        id: record.runtimeId,
        workspaceId: record.workspaceId,
        tenantId: record.tenantId,
        ownerId: record.ownerId,
        provider: record.provider,
        lifecycle: record.lifecycle,
        providerVmId: record.providerVmId,
        providerWorkspaceId: record.providerWorkspaceId,
        providerTerminalId: record.providerTerminalId,
        idempotencyKey: record.idempotencyKey,
        requestDigest: record.requestDigest,
        workspaceName: record.workspaceName,
        failureCode: record.failureCode ?? null,
        failureMessage: record.failureMessage ?? null,
        version: record.version ?? 1,
        createdAt: new Date(record.createdAt),
        updatedAt: new Date(record.updatedAt),
      }).onConflictDoNothing().returning();
      if (inserted) return { record: workspaceRecord(inserted), created: true };
      const raced = (await tx.select().from(persistentWorkspaces).where(and(
        eq(persistentWorkspaces.tenantId, record.tenantId),
        eq(persistentWorkspaces.idempotencyKey, record.idempotencyKey),
      )).limit(1))[0];
      if (!raced) throw new Error("persistent workspace reservation was not persisted");
      if (raced.requestDigest !== record.requestDigest) {
        throw new Error("persistent workspace idempotency key was already used for a different request");
      }
      return { record: workspaceRecord(raced), created: false };
    });
  }

  async getRuntime(input: { readonly runtimeId: string }): Promise<PersistentWorkspaceRecord | null> {
    if (!UUID.test(input.runtimeId)) return null;
    const row = (await cloudDb().select().from(persistentWorkspaces).where(eq(persistentWorkspaces.id, input.runtimeId)).limit(1))[0];
    return row ? workspaceRecord(row) : null;
  }

  async updateRuntime(input: {
    readonly runtimeId: string;
    readonly patch: Parameters<PersistentWorkspaceStore["updateRuntime"]>[0]["patch"];
    readonly expectedVersion?: number;
  }): Promise<PersistentWorkspaceRecord> {
    requireUuid(input.runtimeId, "runtimeId");
    const patch = input.patch;
    const values = {
      ...patch,
      version: sql`${persistentWorkspaces.version} + 1`,
      updatedAt: new Date(),
    };
    const conditions = [eq(persistentWorkspaces.id, input.runtimeId)];
    if (input.expectedVersion !== undefined) conditions.push(eq(persistentWorkspaces.version, input.expectedVersion));
    const [updated] = await cloudDb().update(persistentWorkspaces).set(values as never).where(and(...conditions)).returning();
    if (updated) return workspaceRecord(updated);
    throw new Error("persistent workspace version is stale or missing");
  }
}

function promotionFromRow(row: PromotionRow): PromotionView {
  const value = row.promotion;
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("stored promotion is incomplete");
  return value as PromotionView;
}

/** Durable idempotency/claim store for run-attempt promotion. */
export class DrizzleAttemptPromotionStore implements AttemptPromotionStorePort {
  async findByRequestKey(input: { readonly userId: string; readonly requestKey: string }): Promise<PromotionView | null> {
    const row = (await cloudDb().select().from(runAttemptPromotions).where(and(
      eq(runAttemptPromotions.userId, input.userId),
      eq(runAttemptPromotions.requestKey, input.requestKey),
      eq(runAttemptPromotions.status, "completed"),
    )).limit(1))[0];
    return row ? promotionFromRow(row) : null;
  }

  async reserve(input: {
    readonly userId: string;
    readonly runId: string;
    readonly attemptId: string;
    readonly requestKey: string;
  }) {
    return cloudDb().transaction(async (tx) => {
      const byRequest = (await tx.select().from(runAttemptPromotions).where(and(
        eq(runAttemptPromotions.userId, input.userId),
        eq(runAttemptPromotions.requestKey, input.requestKey),
      )).for("update").limit(1))[0];
      if (byRequest) {
        if (byRequest.runId !== input.runId || byRequest.attemptId !== input.attemptId) return { kind: "idempotency_conflict" as const };
        if (byRequest.status === "completed") return { kind: "replay" as const, promotion: promotionFromRow(byRequest) };
        return { kind: "in_progress" as const };
      }

      const byAttempt = (await tx.select().from(runAttemptPromotions).where(and(
        eq(runAttemptPromotions.userId, input.userId),
        eq(runAttemptPromotions.attemptId, input.attemptId),
      )).for("update").limit(1))[0];
      if (byAttempt) {
        if (byAttempt.status === "completed") return { kind: "duplicate" as const, promotion: promotionFromRow(byAttempt) };
        return { kind: "in_progress" as const };
      }

      const claimId = randomUUID();
      const [inserted] = await tx.insert(runAttemptPromotions).values({
        userId: input.userId,
        runId: requireUuid(input.runId, "runId"),
        attemptId: requireUuid(input.attemptId, "attemptId"),
        requestKey: input.requestKey,
        claimId,
        status: "reserved",
        promotion: null,
      }).onConflictDoNothing().returning({ claimId: runAttemptPromotions.claimId });
      if (!inserted) return { kind: "in_progress" as const };
      return { kind: "reserved" as const, reservation: { claimId: inserted.claimId } };
    });
  }

  async complete(input: { readonly reservation: { readonly claimId: string }; readonly promotion: PromotionView }): Promise<PromotionView> {
    const [updated] = await cloudDb().update(runAttemptPromotions).set({
      status: "completed",
      promotion: input.promotion,
      updatedAt: new Date(),
    }).where(and(
      eq(runAttemptPromotions.claimId, input.reservation.claimId),
      eq(runAttemptPromotions.status, "reserved"),
    )).returning();
    if (updated) return promotionFromRow(updated);
    const existing = (await cloudDb().select().from(runAttemptPromotions).where(eq(runAttemptPromotions.claimId, input.reservation.claimId)).limit(1))[0];
    if (existing?.status === "completed") return promotionFromRow(existing);
    throw new Error("promotion reservation is stale or missing");
  }

  async release(reservation: { readonly claimId: string }): Promise<void> {
    await cloudDb().delete(runAttemptPromotions).where(and(
      eq(runAttemptPromotions.claimId, reservation.claimId),
      eq(runAttemptPromotions.status, "reserved"),
    ));
  }
}

export type RuntimeComposition = {
  readonly workspaceService: ReturnType<typeof createPersistentWorkspaceService>;
  readonly promotionDependencies: AttemptPromotionDependencies;
};

/** Install one complete production dependency graph into the route seams. */
export function installRuntimeComposition(input: {
  readonly workspaceStore: PersistentWorkspaceStore;
  readonly workspaceProvider: PersistentWorkspaceProvider;
  readonly promotionStore: AttemptPromotionStorePort;
  readonly evidence?: AttemptPromotionDependencies["evidence"];
}): RuntimeComposition {
  const workspaceService = createPersistentWorkspaceService({
    store: input.workspaceStore,
    provider: input.workspaceProvider,
    identity: () => ({ runtimeId: randomUUID(), workspaceId: randomUUID() }),
  });
  configurePersistentWorkspaceService(workspaceService);
  const promotionDependencies: AttemptPromotionDependencies = {
    source: runRepositoryPromotionSource(),
    store: input.promotionStore,
    runtime: createPersistentWorkspacePromotionRuntimePort({ service: workspaceService }),
    ...(input.evidence ? { evidence: input.evidence } : {}),
  };
  installRunAttemptPromotionDependencies(promotionDependencies);
  return { workspaceService, promotionDependencies };
}

function requiredEnv(name: string): string | null {
  const value = process.env[name]?.trim();
  return value || null;
}

function manifestEvidenceVerifier(): AttemptPromotionDependencies["evidence"] | undefined {
  if (process.env.CMUX_RUNTIME_EVIDENCE_MODE !== "manifest") return undefined;
  return {
    verify: async ({ source }) => source.artifacts.length > 0
      && source.artifacts.every((artifact) => DIGEST.test(artifact.digest) && typeof artifact.uri === "string" && artifact.uri.length > 0),
  };
}

/**
 * Build and install production adapters only when every credential-bearing
 * seam is explicitly configured. Missing configuration leaves both route
 * seams unset, preserving their existing 503/409 fail-closed behavior.
 */
export function configureRuntimeCompositionFromEnv(): { readonly configured: boolean; readonly reason?: string } {
  const image = requiredEnv("CMUX_PERSISTENT_WORKSPACE_IMAGE");
  const leaseUrl = requiredEnv("CMUX_RUNTIME_HOST_LEASE_URL");
  const leaseToken = requiredEnv("CMUX_RUNTIME_HOST_LEASE_TOKEN");
  const workerId = requiredEnv("CMUX_RUNTIME_WORKER_ID");
  const evidenceMode = requiredEnv("CMUX_RUNTIME_EVIDENCE_MODE");
  const freestyleConfigured = Boolean(requiredEnv("FREESTYLE_API_KEY")
    || (requiredEnv("FREESTYLE_STACK_ACCESS_TOKEN") && requiredEnv("FREESTYLE_TEAM_ID")));
  if (!image || !leaseUrl || !leaseToken || !workerId || !freestyleConfigured || evidenceMode !== "manifest") {
    configurePersistentWorkspaceService(null);
    installRunAttemptPromotionDependencies(null);
    return { configured: false, reason: "runtime composition requires image, lease gateway, lease token, worker id, Freestyle credentials, and manifest evidence verification" };
  }
  try {
    const provider = getProvider("freestyle");
    const runAdapter = new CloudVmRunAdapter(provider);
    const hostClass = requiredEnv("CMUX_RUNTIME_HOST_CLASS") ?? "freestyle";
    const hostClient = createHugeBlueHostLeaseHttpClient({ baseUrl: leaseUrl, token: () => leaseToken });
    const hostLeaseTransport = new VmHostLeaseTransport(
      new DrizzleVmHostLeaseStore(),
      createConfiguredHostLeaseAdapters({ additional: [{ provider: hostClass, client: hostClient }] }),
    );
    const effectBroker = createAgentBrokerLifecycleEffectBroker({
      workerId,
      sourceSha: requiredEnv("VERCEL_GIT_COMMIT_SHA") ?? "cmux-runtime-composition",
      scopeRevision: requiredEnv("CMUX_RUNTIME_SCOPE_REVISION") ?? "runtime-composition-v1",
    });
    const workspaceProvider = persistentWorkspaceProviderFromCloudVm({
      provisionVm: async (request) => {
        const handle = await provider.create({
          image: request.providerInput?.image?.trim() || image,
          displayName: request.workspaceName,
          ...(request.providerInput?.memoryMb !== undefined ? { memoryMb: request.providerInput.memoryMb } : {}),
        });
        return { providerVmId: handle.providerVmId };
      },
      vm: {
        resume: (providerVmId) => provider.resume(providerVmId),
        pause: (providerVmId) => provider.pause(providerVmId),
      },
      runAdapter,
      hostLeaseTransport,
      effectBroker,
      hostLeaseProvider: hostClass,
      attach: async (record) => ({
        provider: record.provider,
        vmId: record.providerVmId,
        workspaceId: record.providerWorkspaceId,
        terminalId: record.providerTerminalId,
      }),
    });
    installRuntimeComposition({
      workspaceStore: new DrizzlePersistentWorkspaceStore(),
      workspaceProvider,
      promotionStore: new DrizzleAttemptPromotionStore(),
      evidence: manifestEvidenceVerifier(),
    });
    return { configured: true };
  } catch (error) {
    configurePersistentWorkspaceService(null);
    installRunAttemptPromotionDependencies(null);
    return { configured: false, reason: error instanceof Error ? error.message : "runtime composition could not be configured" };
  }
}
