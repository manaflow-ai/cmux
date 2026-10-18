import { randomUUID } from "node:crypto";

import { and, eq, sql } from "drizzle-orm";

import { cloudDb } from "../db/client";
import { persistentWorkspaces, runAttemptPromotions, runAttempts } from "../db/schema";
import {
  configurePersistentWorkspaceService,
  createPersistentWorkspacePromotionRuntimePort,
  createPersistentWorkspaceService,
  persistentWorkspaceProviderFromCloudVm,
  type PersistentWorkspaceProvider,
  type PersistentWorkspaceRecord,
  type PersistentWorkspaceStore,
} from "./vms/persistentWorkspace";
import {
  installRunAttemptPromotionDependencies,
  runRepositoryPromotionSource,
  type AttemptPromotionDependencies,
  type AttemptPromotionStorePort,
  type PromotionView,
} from "./runs/promotion";
import type { VmEntitlements } from "./vms/entitlements";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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
    requireUuid(input.promotion.runtime.id, "promotion runtime id");
    return cloudDb().transaction(async (tx) => {
      const [updated] = await tx.update(runAttemptPromotions).set({
        status: "completed",
        promotion: input.promotion,
        updatedAt: new Date(),
      }).where(and(
        eq(runAttemptPromotions.claimId, input.reservation.claimId),
        eq(runAttemptPromotions.status, "reserved"),
      )).returning();
      if (updated) {
        const [linked] = await tx.update(runAttempts).set({
          runtimeId: input.promotion.runtime.id,
          updatedAt: new Date(),
        }).where(and(
          eq(runAttempts.id, input.promotion.attemptId),
          eq(runAttempts.runId, input.promotion.runId),
        )).returning();
        if (!linked) throw new Error("promotion attempt could not be linked to the runtime");
        return promotionFromRow(updated);
      }
      const existing = (await tx.select().from(runAttemptPromotions).where(eq(runAttemptPromotions.claimId, input.reservation.claimId)).limit(1))[0];
      if (existing?.status === "completed") return promotionFromRow(existing);
      throw new Error("promotion reservation is stale or missing");
    });
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

/**
 * The authenticated scope that a workspace provider is allowed to use.
 *
 * Workspace persistence is process-wide, but VM provisioning is request
 * scoped: billing, admission, and model-plane ownership are resolved by the
 * authenticated route before this value is constructed. Keeping the resolved
 * entitlement object attached to the provider factory makes it impossible for
 * a startup-only composition to guess a billing owner.
 */
export type RequestScopedWorkspaceContext = {
  readonly userId: string;
  readonly entitlements: VmEntitlements;
};

/**
 * Build the provider only after a route has authenticated and resolved VM
 * entitlements. A missing adapter is an intentional fail-closed result: the
 * caller must return the existing 503 instead of falling back to a direct
 * provider.create call that would bypass policy.
 */
export type RequestScopedWorkspaceProviderFactory = (
  context: RequestScopedWorkspaceContext,
) => PersistentWorkspaceProvider | null;

/**
 * Request-scoped provider assembly inputs. The provisioner is deliberately a
 * callback supplied by the authenticated route; it must call createVm through
 * the normal entitlement/model-plane workflow before returning a provider VM.
 */
export type RequestScopedWorkspaceProviderInfrastructure = Omit<
  Parameters<typeof persistentWorkspaceProviderFromCloudVm>[0],
  "provisionVm"
> & {
  readonly provisionVm: (
    context: RequestScopedWorkspaceContext,
    request: Parameters<typeof persistentWorkspaceProviderFromCloudVm>[0] extends { provisionVm: (request: infer R) => unknown } ? R : never,
  ) => Promise<{ readonly providerVmId: string }>;
};

export function createRequestScopedWorkspaceProviderFactory(
  infrastructure: RequestScopedWorkspaceProviderInfrastructure,
): RequestScopedWorkspaceProviderFactory {
  return (context) => persistentWorkspaceProviderFromCloudVm({
    ...infrastructure,
    provisionVm: (request) => infrastructure.provisionVm(context, request),
  });
}

/**
 * Construct a persistent workspace service for one authenticated request.
 *
 * This helper has no global side effects. In particular, it does not call
 * `configurePersistentWorkspaceService`; route code may safely create one
 * service per request without leaking one user's billing scope into another
 * request. The explicit factory is the only place that may supply provider
 * credentials or invoke the VM workflow.
 */
export function createRequestScopedWorkspaceService(input: {
  readonly context: RequestScopedWorkspaceContext;
  readonly workspaceStore: PersistentWorkspaceStore;
  readonly providerFactory: RequestScopedWorkspaceProviderFactory;
  readonly identity?: Parameters<typeof createPersistentWorkspaceService>[0]["identity"];
}): ReturnType<typeof createPersistentWorkspaceService> | null {
  const userId = input.context.userId.trim();
  const billingTeamId = input.context.entitlements.billingTeamId.trim();
  const planId = input.context.entitlements.planId.trim();
  if (!userId || !billingTeamId || !planId) {
    throw new Error("request-scoped workspace context is incomplete");
  }

  const provider = input.providerFactory(input.context);
  if (!provider) return null;
  return createPersistentWorkspaceService({
    store: input.workspaceStore,
    provider,
    ...(input.identity ? { identity: input.identity } : {}),
  });
}

type RequestScopedWorkspaceInfrastructure = {
  readonly workspaceStore: PersistentWorkspaceStore;
  readonly providerFactory: RequestScopedWorkspaceProviderFactory;
};

let requestScopedInfrastructure: RequestScopedWorkspaceInfrastructure | null = null;

/** Install only provider-neutral request infrastructure; billing remains per request. */
export function configureRequestScopedWorkspaceInfrastructure(
  infrastructure: RequestScopedWorkspaceInfrastructure | null,
): void {
  requestScopedInfrastructure = infrastructure;
}

/** Build a route-local service from the caller's already-resolved entitlements. */
export function requestScopedWorkspaceServiceFor(
  context: RequestScopedWorkspaceContext,
): ReturnType<typeof createPersistentWorkspaceService> | null {
  if (!requestScopedInfrastructure) return null;
  return createRequestScopedWorkspaceService({
    context,
    workspaceStore: requestScopedInfrastructure.workspaceStore,
    providerFactory: requestScopedInfrastructure.providerFactory,
  });
}

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

/**
 * Build and install production adapters only when every credential-bearing
 * seam is explicitly configured. Missing configuration leaves both route
 * seams unset, preserving their existing 503/409 fail-closed behavior.
 */
export function configureRuntimeCompositionFromEnv(): { readonly configured: boolean; readonly reason?: string } {
  // The authenticated createVm workflow is not available from Next startup:
  // it needs the request's entitlement/admission context. Never synthesize a
  // direct provider.create callback here, because that would bypass billing,
  // admission, and model-plane ownership checks. Route/workflow composition
  // must call installRuntimeComposition with that callback explicitly.
  configurePersistentWorkspaceService(null);
  installRunAttemptPromotionDependencies(null);
  return { configured: false, reason: "authenticated createVm workflow composition is required" };
}
