import { and, asc, count, desc, eq, gt, inArray, isNotNull, isNull, lt, ne, or, sql } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { cloudDb } from "../../db/client";
import {
  accountDeletionTombstones,
  cloudVmBaseEvents,
  cloudVmBaseGenerations,
  cloudVmBases,
  cloudVmBillingGrants,
  cloudVmLeases,
  cloudVmNetworks,
  cloudVmSessions,
  cloudVmTunnels,
  cloudVms,
  cloudVmUsageEvents,
} from "../../db/schema";
import {
  accountDeletionAdvisoryLockKey,
  accountDeletionUserHash,
  isBlockingAccountDeletionTombstone,
} from "../account/deletionLock";
import type { ProviderId } from "./drivers";
import {
  VmCreateDisabledError,
  VmCreateInProgressError,
  VmAccountDeletionInProgressError,
  VmDatabaseError,
  VmLimitExceededError,
  LEGACY_MODEL_PLANE_ENTITLEMENT_FAILURE_CODE,
  VM_MODEL_PLANE_FAILURE_CODES,
  isVmAccountDeletionInProgressError,
  isVmCreateDisabledError,
  isVmLimitExceededError,
} from "./errors";

export type CloudVmRow = typeof cloudVms.$inferSelect;
export type CloudVmBaseRow = typeof cloudVmBases.$inferSelect;
export type CloudVmBaseGenerationRow = typeof cloudVmBaseGenerations.$inferSelect;
export type CloudVmLeaseRow = typeof cloudVmLeases.$inferSelect;
export type CloudVmIdentityLeaseRow = CloudVmLeaseRow & {
  readonly provider: ProviderId;
};
/** An active endpoint lease together with the provider address it protects. */
export type CloudVmAccessLeaseRow = CloudVmLeaseRow & {
  readonly provider: ProviderId;
  readonly providerVmId: string;
};
export type CloudVmSessionRow = typeof cloudVmSessions.$inferSelect;
export type CloudVmNetworkRow = typeof cloudVmNetworks.$inferSelect;
export type CloudVmTunnelRow = typeof cloudVmTunnels.$inferSelect;
export type CloudVmLeaseKind = typeof cloudVmLeases.$inferInsert.kind;
export type CloudVmStatus = CloudVmRow["status"];
export type CloudVmSessionStatus = CloudVmSessionRow["status"];
// Reaper batches are capped at 100. Keep repository calls bounded even if a
// future caller passes a malformed or oversized name list.
const VM_REAPER_REFERENCE_NAME_LIMIT = 100;

export type BeginCreateResult =
  | { readonly inserted: true; readonly vm: CloudVmRow }
  | { readonly inserted: false; readonly vm: CloudVmRow };

export type BeginBaseCreateResult =
  | {
    readonly kind: "existing";
    readonly base: CloudVmBaseRow;
    readonly generation: CloudVmBaseGenerationRow;
    readonly vm: CloudVmRow;
  }
  | {
    readonly kind: "create";
    readonly base: CloudVmBaseRow;
    readonly generation: CloudVmBaseGenerationRow;
    readonly vm: CloudVmRow;
    readonly previousGeneration: CloudVmBaseGenerationRow | null;
    readonly previousVm: CloudVmRow | null;
  };

export type BillingGrantClaim =
  | { readonly kind: "inserted"; readonly grantId: string }
  | { readonly kind: "already_claimed" };

export type VmRepositoryShape = {
  readonly listUserVms: (userId: string, billingTeamId?: string | null) => Effect.Effect<CloudVmRow[], VmDatabaseError>;
  /**
   * Private-network and tunnel bookkeeping. Optional as a group so test
   * doubles built before the feature keep compiling; the live layer always
   * provides them and workflows treat absence as "no networking".
   */
  /** The owner's private-network row for one provider, or null when they have none yet. */
  readonly findNetwork?: (
    userId: string,
    provider: ProviderId,
  ) => Effect.Effect<CloudVmNetworkRow | null, VmDatabaseError>;
  /**
   * Record the owner's network. Idempotent by (user, provider): concurrent
   * creates resolve to one row, and a re-provisioned network overwrites the
   * provider id rather than adding a second row nobody reads.
   */
  readonly upsertNetwork?: (input: {
    readonly userId: string;
    readonly provider: ProviderId;
    readonly providerNetworkId: string;
    readonly slug?: string | null;
    readonly cidr?: string | null;
    readonly cidrV6?: string | null;
  }) => Effect.Effect<CloudVmNetworkRow, VmDatabaseError>;
  readonly deleteNetwork?: (id: string) => Effect.Effect<void, VmDatabaseError>;
  /** The live (unrevoked) tunnel row for one of the owner's devices. */
  readonly findTunnel?: (input: {
    readonly userId: string;
    readonly deviceFingerprint: string;
  }) => Effect.Effect<CloudVmTunnelRow | null, VmDatabaseError>;
  readonly listUserTunnels?: (userId: string) => Effect.Effect<CloudVmTunnelRow[], VmDatabaseError>;
  readonly insertTunnel?: (input: {
    readonly userId: string;
    readonly networkId: string;
    readonly provider: ProviderId;
    readonly providerTunnelId: string;
    readonly deviceFingerprint: string;
    readonly deviceName?: string | null;
    readonly clientPublicKey: string;
    readonly addressV4?: string | null;
    readonly addressV6?: string | null;
  }) => Effect.Effect<CloudVmTunnelRow, VmDatabaseError>;
  /** Refresh a tunnel row after the provider handed back its current state. */
  readonly updateTunnel?: (input: {
    readonly id: string;
    readonly clientPublicKey?: string;
    readonly deviceName?: string | null;
    readonly addressV4?: string | null;
    readonly addressV6?: string | null;
    readonly configIssued?: boolean;
  }) => Effect.Effect<CloudVmTunnelRow, VmDatabaseError>;
  /** Mark a tunnel revoked, keeping the row for audit. Returns false when already revoked. */
  readonly revokeTunnel?: (id: string) => Effect.Effect<boolean, VmDatabaseError>;
  /**
   * Merge fields into a VM row's providerMetadata (existing keys win only when
   * the patch omits them). Used to backfill data learned after create, e.g.
   * private-network addresses read during an attach.
   */
  readonly mergeProviderMetadata?: (input: {
    readonly id: string;
    readonly patch: Readonly<Record<string, unknown>>;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly claimBillingGrant: (input: {
    readonly billingCustomerType: string;
    readonly billingCustomerId: string;
    readonly billingPlanId: string;
    readonly itemId: string;
    readonly amount: number;
    readonly reason: string;
  }) => Effect.Effect<BillingGrantClaim, VmDatabaseError>;
  readonly markBillingGrantApplied: (id: string) => Effect.Effect<void, VmDatabaseError>;
  readonly deleteBillingGrant: (id: string) => Effect.Effect<void, VmDatabaseError>;
  readonly beginCreate: (input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly maxActiveVms: number | null;
    readonly idempotencyKey?: string;
  }) => Effect.Effect<BeginCreateResult, VmDatabaseError | VmCreateDisabledError | VmAccountDeletionInProgressError | VmLimitExceededError>;
  readonly beginBaseOpen: (input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly billingCustomerType: "team" | "user";
    readonly provider: ProviderId;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly maxActiveVms: number | null;
    readonly baseName?: string;
  }) => Effect.Effect<BeginBaseCreateResult, VmCreateDisabledError | VmAccountDeletionInProgressError | VmDatabaseError | VmLimitExceededError>;
  readonly beginBaseReset: (input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly billingCustomerType: "team" | "user";
    readonly provider: ProviderId;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly maxActiveVms: number | null;
    readonly baseName?: string;
    readonly reason?: string | null;
  }) => Effect.Effect<Extract<BeginBaseCreateResult, { readonly kind: "create" }>, VmCreateDisabledError | VmAccountDeletionInProgressError | VmCreateInProgressError | VmDatabaseError | VmLimitExceededError>;
  readonly markBaseCreateRunning: (input: {
    readonly baseId: string;
    readonly generation: number;
    readonly vmId: string;
    readonly providerVmId: string;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly providerMetadata?: Record<string, unknown>;
    readonly userId: string;
  }) => Effect.Effect<CloudVmRow, VmDatabaseError>;
  readonly markBaseCreateFailed: (input: {
    readonly baseId: string;
    readonly generation: number;
    readonly vmId: string;
    readonly userId: string;
    readonly code: string;
    readonly message: string;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly activeLimitCandidates: (input: {
    readonly userId: string;
    readonly billingTeamId: string;
    /** Maximum number of rows to inspect in the synchronous limit retry. */
    readonly limit: number;
  }) => Effect.Effect<CloudVmRow[], VmDatabaseError>;
  readonly reservePausedResume: (input: {
    readonly id: string;
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly providerVmId: string;
    readonly maxActiveVms: number | null;
  }) => Effect.Effect<CloudVmRow | null, VmDatabaseError | VmLimitExceededError>;
  readonly reconciliationCandidates: (input: {
    readonly limit: number;
  }) => Effect.Effect<CloudVmRow[], VmDatabaseError>;
  /** Live VM rows that currently claim a persistent home volume. */
  readonly listLiveHomeVolumeNames?: (input: {
    readonly provider: ProviderId;
    /** Candidate names only; an empty list must not trigger an unbounded scan. */
    readonly volumeNames: readonly string[];
  }) => Effect.Effect<readonly string[], VmDatabaseError>;
  /** Oldest provisioning rows for the bounded resource reaper. */
  readonly stuckProvisioningCandidates?: (input: {
    readonly before: Date;
    readonly limit: number;
  }) => Effect.Effect<CloudVmRow[], VmDatabaseError>;
  readonly recentReaperReportKeys: (input: {
    readonly eventType: string;
    readonly keys: readonly string[];
    readonly since: Date;
  }) => Effect.Effect<string[], VmDatabaseError>;
  readonly markProviderObservedStatus: (input: {
    readonly id: string;
    readonly providerVmId: string;
    readonly status: CloudVmStatus;
  }) => Effect.Effect<boolean, VmDatabaseError>;
  readonly setDisplayName: (input: {
    readonly id: string;
    readonly displayName: string | null;
  }) => Effect.Effect<boolean, VmDatabaseError>;
  readonly markCreateRunning: (input: {
    readonly id: string;
    readonly providerVmId: string;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly providerMetadata?: Record<string, unknown>;
  }) => Effect.Effect<CloudVmRow, VmDatabaseError>;
  readonly markCreateFailed: (input: {
    readonly id: string;
    readonly code: string;
    readonly message: string;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly hasOwnedSnapshot: (input: {
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly provider: ProviderId;
    readonly snapshotId: string;
  }) => Effect.Effect<boolean, VmDatabaseError>;
  readonly findUserVm: (input: {
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly providerVmId: string;
    readonly provider?: ProviderId;
  }) => Effect.Effect<CloudVmRow | null, VmDatabaseError>;
  readonly markDestroyed: (id: string) => Effect.Effect<void, VmDatabaseError>;
  readonly recordLease: (input: {
    readonly vmId: string;
    readonly userId: string;
    readonly kind: CloudVmLeaseKind;
    readonly tokenHash: string;
    readonly expiresAt: Date;
    readonly providerIdentityHandle?: string;
    readonly sessionId?: string;
    readonly transport?: string;
    readonly metadata?: Record<string, unknown>;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly expiredIdentityLeases?: (input: {
    readonly now: Date;
    readonly limit: number;
  }) => Effect.Effect<CloudVmIdentityLeaseRow[], VmDatabaseError>;
  readonly accountDeletionIdentityLeases: (input: {
    readonly userId: string;
    readonly limit: number;
  }) => Effect.Effect<CloudVmIdentityLeaseRow[], VmDatabaseError>;
  readonly markLeaseRevocationRetry?: (input: {
    readonly id: string;
    readonly retryAfter: Date;
    readonly error: string;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly listVmSessions: (input: {
    readonly userId: string;
    readonly vmId: string;
  }) => Effect.Effect<CloudVmSessionRow[], VmDatabaseError>;
  readonly upsertVmSession: (input: {
    readonly vmId: string;
    readonly userId: string;
    readonly providerSessionId: string;
    readonly title?: string | null;
    readonly status?: CloudVmSessionStatus;
    readonly attachmentCount?: number;
    readonly effectiveCols?: number | null;
    readonly effectiveRows?: number | null;
    readonly lastKnownCols?: number | null;
    readonly lastKnownRows?: number | null;
    readonly scrollbackBytes?: number;
    readonly metadata?: Record<string, unknown>;
  }) => Effect.Effect<CloudVmSessionRow, VmDatabaseError>;
  readonly activeIdentityLeases: (vmId: string, limit?: number) => Effect.Effect<CloudVmLeaseRow[], VmDatabaseError>;
  /** Endpoint leases issued to one signed-in user and still within their TTL. */
  readonly activeAccessLeasesForUser?: (userId: string) => Effect.Effect<CloudVmAccessLeaseRow[], VmDatabaseError>;
  readonly markLeasesRevoked: (ids: readonly string[]) => Effect.Effect<void, VmDatabaseError>;
  readonly recordUsageEvent: (input: {
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly billingPlanId?: string | null;
    readonly vmId?: string | null;
    readonly eventType: string;
    readonly provider?: ProviderId;
    readonly imageId?: string;
    readonly metadata?: Record<string, unknown>;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly recordUsageEvents: (inputs: readonly {
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly billingPlanId?: string | null;
    readonly vmId?: string | null;
    readonly eventType: string;
    readonly provider?: ProviderId;
    readonly imageId?: string;
    readonly metadata?: Record<string, unknown>;
  }[]) => Effect.Effect<void, VmDatabaseError>;
};

export class VmRepository extends Context.Tag("cmux/VmRepository")<
  VmRepository,
  VmRepositoryShape
>() {}

function dbEffect<A>(
  operation: string,
  run: () => Promise<A>,
): Effect.Effect<A, VmDatabaseError> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) => new VmDatabaseError({ operation, cause }),
  });
}

type CloudDbTransaction = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

async function assertAccountVmCreateAllowed(
  tx: CloudDbTransaction,
  input: { readonly userId: string; readonly provider: ProviderId },
): Promise<void> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(input.userId)}, 0))`);
  const userIdHash = accountDeletionUserHash(input.userId);
  const [deletion] = await tx
    .select({
      userIdHash: accountDeletionTombstones.userIdHash,
      status: accountDeletionTombstones.status,
      updatedAt: accountDeletionTombstones.updatedAt,
    })
    .from(accountDeletionTombstones)
    .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
    .limit(1);
  if (
    deletion?.userIdHash !== userIdHash ||
    !isBlockingAccountDeletionTombstone(deletion)
  ) return;
  throw new VmAccountDeletionInProgressError({
    provider: input.provider,
    phase: "create",
  });
}

function pgErrorCode(cause: unknown): string | null {
  if (!cause || typeof cause !== "object") return null;
  const code = (cause as { code?: unknown }).code;
  if (typeof code === "string") return code;
  return pgErrorCode((cause as { cause?: unknown }).cause);
}

async function findByIdempotencyKey(
  billingTeamId: string,
  idempotencyKey: string,
): Promise<CloudVmRow | null> {
  const db = cloudDb();
  const [existing] = await db
    .select()
    .from(cloudVms)
    .where(idempotencyScopeWhere({ billingTeamId, idempotencyKey }))
    .limit(1);
  return existing ?? null;
}

export const FAILED_CREATE_RETRY_WINDOW_MS = 15 * 60 * 1000;

/**
 * failureCode stored when the provider itself failed the create. The HTTP
 * layer reports these as vm_cloud_service_unavailable with retryable: true
 * and retryAfterSeconds ~5, so the idempotency key must honor that contract
 * and let the retry reach the provider again instead of replaying the stored
 * failure for FAILED_CREATE_RETRY_WINDOW_MS (a client with a stable key, like
 * the CLI pinned-slot flow, was bricked for 15 minutes by one transient
 * provider failure).
 */
export const PROVIDER_CREATE_UNAVAILABLE_FAILURE_CODE = "provider_create_unavailable";

const RETRYABLE_FAILED_CREATE_CODES = new Set([
  "billing_credits_insufficient",
  "billing_reserve_failed",
  PROVIDER_CREATE_UNAVAILABLE_FAILURE_CODE,
  // Model-plane failures happen before any provider call: a coderouter outage
  // clears on its own, so a same-key retry must reach provisioning again. The
  // legacy entitlement code is kept for rows written before that gate was
  // removed.
  VM_MODEL_PLANE_FAILURE_CODES.unavailable,
  LEGACY_MODEL_PLANE_ENTITLEMENT_FAILURE_CODE,
]);

function isRetryableFailedCreate(vm: CloudVmRow, now: Date): boolean {
  if (vm.status === "destroyed") return true;
  if (vm.status !== "failed") return false;
  if (vm.failureCode && RETRYABLE_FAILED_CREATE_CODES.has(vm.failureCode)) return true;
  return now.getTime() - vm.updatedAt.getTime() >= FAILED_CREATE_RETRY_WINDOW_MS;
}

function idempotencyScopeWhere(input: {
  readonly billingTeamId: string;
  readonly idempotencyKey: string;
}) {
  return and(
    eq(cloudVms.idempotencyKey, input.idempotencyKey),
    eq(cloudVms.billingTeamId, input.billingTeamId),
  );
}

function accountScopeWhere(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
}) {
  const billingTeamId = input.billingTeamId?.trim();
  if (!billingTeamId) {
    return and(
      eq(cloudVms.userId, input.userId),
      or(isNull(cloudVms.billingTeamId), eq(cloudVms.billingTeamId, input.userId)),
    );
  }
  return eq(cloudVms.billingTeamId, billingTeamId);
}

function accountUsageScopeWhere(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
}) {
  const billingTeamId = input.billingTeamId?.trim();
  if (!billingTeamId) {
    return and(
      eq(cloudVmUsageEvents.userId, input.userId),
      or(isNull(cloudVmUsageEvents.billingTeamId), eq(cloudVmUsageEvents.billingTeamId, input.userId)),
    );
  }
  return eq(cloudVmUsageEvents.billingTeamId, billingTeamId);
}

function baseScope(input: {
  readonly billingCustomerType: "team" | "user";
  readonly billingTeamId: string;
}) {
  const scopeType = input.billingCustomerType === "team" ? "team" : "user";
  return { scopeType, scopeId: input.billingTeamId };
}

function baseName(value: string | null | undefined) {
  const trimmed = value?.trim();
  return trimmed || "base";
}

function boundedReaperVolumeNames(names: readonly string[]): string[] {
  const normalized = [...new Set(names.map((name) => name.trim()).filter(Boolean))];
  if (normalized.length > VM_REAPER_REFERENCE_NAME_LIMIT) {
    throw new Error(
      `VM reaper reference query has ${normalized.length} names; maximum is ${VM_REAPER_REFERENCE_NAME_LIMIT}`,
    );
  }
  return normalized;
}

function boundedReaperKeys(keys: readonly string[]): string[] {
  const normalized = [...new Set(keys.map((key) => key.trim()).filter(Boolean))];
  if (normalized.length > VM_REAPER_REFERENCE_NAME_LIMIT) {
    throw new Error(
      `VM reaper report key query has ${normalized.length} keys; maximum is ${VM_REAPER_REFERENCE_NAME_LIMIT}`,
    );
  }
  return normalized;
}

export const VmRepositoryLive = Layer.succeed(VmRepository, {
  findNetwork: (userId, provider) =>
    dbEffect("findNetwork", async () => {
      const db = cloudDb();
      const [row] = await db
        .select()
        .from(cloudVmNetworks)
        .where(and(eq(cloudVmNetworks.userId, userId), eq(cloudVmNetworks.provider, provider)))
        .limit(1);
      return row ?? null;
    }),

  upsertNetwork: (input) =>
    dbEffect("upsertNetwork", async () => {
      const db = cloudDb();
      const [row] = await db
        .insert(cloudVmNetworks)
        .values({
          userId: input.userId,
          provider: input.provider,
          providerNetworkId: input.providerNetworkId,
          slug: input.slug ?? null,
          cidr: input.cidr ?? null,
          cidrV6: input.cidrV6 ?? null,
        })
        .onConflictDoUpdate({
          target: [cloudVmNetworks.userId, cloudVmNetworks.provider],
          set: {
            providerNetworkId: input.providerNetworkId,
            slug: input.slug ?? null,
            cidr: input.cidr ?? null,
            cidrV6: input.cidrV6 ?? null,
            updatedAt: new Date(),
          },
        })
        .returning();
      if (!row) throw new Error("upsertNetwork returned no row");
      return row;
    }),

  deleteNetwork: (id) =>
    dbEffect("deleteNetwork", async () => {
      const db = cloudDb();
      await db.delete(cloudVmNetworks).where(eq(cloudVmNetworks.id, id));
    }),

  findTunnel: (input) =>
    dbEffect("findTunnel", async () => {
      const db = cloudDb();
      const [row] = await db
        .select()
        .from(cloudVmTunnels)
        .where(and(
          eq(cloudVmTunnels.userId, input.userId),
          eq(cloudVmTunnels.deviceFingerprint, input.deviceFingerprint),
          isNull(cloudVmTunnels.revokedAt),
        ))
        .limit(1);
      return row ?? null;
    }),

  listUserTunnels: (userId) =>
    dbEffect("listUserTunnels", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(cloudVmTunnels)
        .where(and(eq(cloudVmTunnels.userId, userId), isNull(cloudVmTunnels.revokedAt)))
        .orderBy(desc(cloudVmTunnels.createdAt));
    }),

  insertTunnel: (input) =>
    dbEffect("insertTunnel", async () => {
      const db = cloudDb();
      const [row] = await db
        .insert(cloudVmTunnels)
        .values({
          userId: input.userId,
          networkId: input.networkId,
          provider: input.provider,
          providerTunnelId: input.providerTunnelId,
          deviceFingerprint: input.deviceFingerprint,
          deviceName: input.deviceName ?? null,
          clientPublicKey: input.clientPublicKey,
          addressV4: input.addressV4 ?? null,
          addressV6: input.addressV6 ?? null,
          lastConfigIssuedAt: new Date(),
        })
        .returning();
      if (!row) throw new Error("insertTunnel returned no row");
      return row;
    }),

  updateTunnel: (input) =>
    dbEffect("updateTunnel", async () => {
      const db = cloudDb();
      const [row] = await db
        .update(cloudVmTunnels)
        .set({
          ...(input.clientPublicKey ? { clientPublicKey: input.clientPublicKey } : {}),
          ...(input.deviceName === undefined ? {} : { deviceName: input.deviceName }),
          ...(input.addressV4 === undefined ? {} : { addressV4: input.addressV4 }),
          ...(input.addressV6 === undefined ? {} : { addressV6: input.addressV6 }),
          ...(input.configIssued ? { lastConfigIssuedAt: new Date() } : {}),
          updatedAt: new Date(),
        })
        .where(eq(cloudVmTunnels.id, input.id))
        .returning();
      if (!row) throw new Error(`updateTunnel found no tunnel ${input.id}`);
      return row;
    }),

  revokeTunnel: (id) =>
    dbEffect("revokeTunnel", async () => {
      const db = cloudDb();
      const rows = await db
        .update(cloudVmTunnels)
        .set({ revokedAt: new Date(), updatedAt: new Date() })
        .where(and(eq(cloudVmTunnels.id, id), isNull(cloudVmTunnels.revokedAt)))
        .returning({ id: cloudVmTunnels.id });
      return rows.length > 0;
    }),

  mergeProviderMetadata: (input) =>
    dbEffect("mergeProviderMetadata", async () => {
      const db = cloudDb();
      await db
        .update(cloudVms)
        .set({
          // jsonb || jsonb merges at the top level: patch keys win, others stay.
          providerMetadata: sql`${cloudVms.providerMetadata} || ${JSON.stringify(input.patch)}::jsonb`,
          updatedAt: new Date(),
        })
        .where(eq(cloudVms.id, input.id));
    }),

  listUserVms: (userId, billingTeamId) =>
    dbEffect("listUserVms", async () => {
      const db = cloudDb();
      const teamId = billingTeamId?.trim();
      return await db
        .select()
        .from(cloudVms)
        .where(and(
          accountScopeWhere({ userId, billingTeamId: teamId }),
          ne(cloudVms.status, "destroyed"),
        ))
        .orderBy(desc(cloudVms.createdAt));
    }),

  claimBillingGrant: (input) =>
    dbEffect("claimBillingGrant", async () => {
      const db = cloudDb();
      const [inserted] = await db
        .insert(cloudVmBillingGrants)
        .values({
          billingCustomerType: input.billingCustomerType,
          billingCustomerId: input.billingCustomerId,
          billingPlanId: input.billingPlanId,
          itemId: input.itemId,
          amount: input.amount,
          reason: input.reason,
        })
        .onConflictDoNothing({
          target: [
            cloudVmBillingGrants.billingCustomerType,
            cloudVmBillingGrants.billingCustomerId,
            cloudVmBillingGrants.itemId,
            cloudVmBillingGrants.reason,
          ],
        })
        .returning({ id: cloudVmBillingGrants.id });
      if (inserted) {
        return { kind: "inserted" as const, grantId: inserted.id };
      }

      const [existing] = await db
        .select({ id: cloudVmBillingGrants.id })
        .from(cloudVmBillingGrants)
        .where(
          and(
            eq(cloudVmBillingGrants.billingCustomerType, input.billingCustomerType),
            eq(cloudVmBillingGrants.billingCustomerId, input.billingCustomerId),
            eq(cloudVmBillingGrants.itemId, input.itemId),
            eq(cloudVmBillingGrants.reason, input.reason),
          ),
        )
        .limit(1);
      if (!existing) throw new Error("billing grant conflict row missing after insert");
      return { kind: "already_claimed" as const };
    }),

  markBillingGrantApplied: (id) =>
    dbEffect("markBillingGrantApplied", async () => {
      const db = cloudDb();
      await db
        .update(cloudVmBillingGrants)
        .set({ appliedAt: new Date(), updatedAt: new Date() })
        .where(eq(cloudVmBillingGrants.id, id));
    }),

  deleteBillingGrant: (id) =>
    dbEffect("deleteBillingGrant", async () => {
      const db = cloudDb();
      await db
        .delete(cloudVmBillingGrants)
        .where(and(eq(cloudVmBillingGrants.id, id), isNull(cloudVmBillingGrants.appliedAt)));
    }),

  beginCreate: (input) =>
    Effect.tryPromise({
      try: async () => {
        const idempotencyKey = input.idempotencyKey?.trim() || undefined;
        const db = cloudDb();
        try {
          return await db.transaction(async (tx) => {
            await assertAccountVmCreateAllowed(tx, {
              userId: input.userId,
              provider: input.provider,
            });
            if (idempotencyKey) {
              const [existing] = await tx
                .select()
                .from(cloudVms)
                .where(idempotencyScopeWhere({ billingTeamId: input.billingTeamId, idempotencyKey }))
                .limit(1);
              if (existing) {
                if (!isRetryableFailedCreate(existing, new Date())) {
                  return { inserted: false as const, vm: existing };
                }
              }
            }

            await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.billingTeamId}, 0))`);
            if (idempotencyKey) {
              const [existing] = await tx
                .select()
                .from(cloudVms)
                .where(idempotencyScopeWhere({ billingTeamId: input.billingTeamId, idempotencyKey }))
                .limit(1);
              if (existing) {
                if (!isRetryableFailedCreate(existing, new Date())) {
                  return { inserted: false as const, vm: existing };
                }
                await tx
                  .update(cloudVms)
                  .set({ idempotencyKey: null, updatedAt: new Date() })
                  .where(eq(cloudVms.id, existing.id));
              }
            }

            const [active] = await tx
              .select({ total: count() })
              .from(cloudVms)
              .where(
                and(
                  inArray(cloudVms.status, ["provisioning", "running"]),
                  eq(cloudVms.billingTeamId, input.billingTeamId),
                ),
              );
            const activeCount = Number(active?.total ?? 0);
            const limit = input.maxActiveVms;
            if (limit !== null && activeCount >= limit) {
              throw new VmLimitExceededError({
                kind: "active_vms",
                billingTeamId: input.billingTeamId,
                limit,
              });
            }

            const [vm] = await tx
              .insert(cloudVms)
              .values({
                userId: input.userId,
                billingTeamId: input.billingTeamId,
                billingPlanId: input.billingPlanId,
                provider: input.provider,
                imageId: input.image,
                imageVersion: input.imageVersion ?? null,
                status: "provisioning",
                idempotencyKey,
              })
              .returning();
            if (!vm) throw new Error("insert returned no VM row");
            return { inserted: true as const, vm };
          });
        } catch (err) {
          if (idempotencyKey && pgErrorCode(err) === "23505") {
            const existing = await findByIdempotencyKey(input.billingTeamId, idempotencyKey);
            if (existing) return { inserted: false as const, vm: existing };
          }
          throw err;
        }
      },
      catch: (cause) => isVmCreateDisabledError(cause) || isVmAccountDeletionInProgressError(cause) || isVmLimitExceededError(cause)
        ? cause
        : new VmDatabaseError({ operation: "beginCreate", cause }),
    }),

  beginBaseOpen: (input) =>
    Effect.tryPromise({
      try: async () => {
        const db = cloudDb();
        const scope = baseScope(input);
        const name = baseName(input.baseName);
        try {
          return await db.transaction(async (tx) => {
            await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`${scope.scopeType}:${scope.scopeId}:${name}`}, 0))`);
            await assertAccountVmCreateAllowed(tx, {
              userId: input.userId,
              provider: input.provider,
            });

            const [existing] = await tx
              .select({
                base: cloudVmBases,
                generation: cloudVmBaseGenerations,
                vm: cloudVms,
              })
              .from(cloudVmBases)
              .leftJoin(
                cloudVmBaseGenerations,
                and(
                  eq(cloudVmBaseGenerations.baseId, cloudVmBases.id),
                  eq(cloudVmBaseGenerations.generation, cloudVmBases.activeGeneration),
                ),
              )
              .leftJoin(cloudVms, eq(cloudVms.id, cloudVmBases.activeVmId))
              .where(and(
                eq(cloudVmBases.scopeType, scope.scopeType),
                eq(cloudVmBases.scopeId, scope.scopeId),
                eq(cloudVmBases.name, name),
              ))
              .limit(1);

            if (
              existing?.base &&
              existing.generation &&
              existing.vm &&
              existing.vm.status !== "failed" &&
              existing.vm.status !== "destroyed"
            ) {
              await tx
                .update(cloudVmBases)
                .set({ lastOpenedByUserId: input.userId, updatedAt: new Date() })
                .where(eq(cloudVmBases.id, existing.base.id));
              return {
                kind: "existing" as const,
                base: { ...existing.base, lastOpenedByUserId: input.userId, updatedAt: new Date() },
                generation: existing.generation,
                vm: existing.vm,
              };
            }

            const [active] = await tx
              .select({ total: count() })
              .from(cloudVms)
              .where(and(
                inArray(cloudVms.status, ["provisioning", "running"]),
                eq(cloudVms.billingTeamId, input.billingTeamId),
              ));
            const activeCount = Number(active?.total ?? 0);
            const limit = input.maxActiveVms;
            if (limit !== null && activeCount >= limit) {
              throw new VmLimitExceededError({
                kind: "active_vms",
                billingTeamId: input.billingTeamId,
                limit,
              });
            }

            const now = new Date();
            const previousGeneration = existing?.generation ?? null;
            const previousVm = existing?.vm ?? null;
            const nextGeneration = (existing?.base.activeGeneration ?? 0) + 1;
            const idempotencyKey = `base:${scope.scopeType}:${scope.scopeId}:${name}:g${nextGeneration}`;
            const [vm] = await tx
              .insert(cloudVms)
              .values({
                userId: input.userId,
                billingTeamId: input.billingTeamId,
                billingPlanId: input.billingPlanId,
                provider: input.provider,
                imageId: input.image,
                imageVersion: input.imageVersion ?? null,
                status: "provisioning",
                idempotencyKey,
              })
              .returning();
            if (!vm) throw new Error("insert returned no VM row");

            const [base] = existing?.base
              ? await tx
                .update(cloudVmBases)
                .set({
                  activeGeneration: nextGeneration,
                  activeVmId: vm.id,
                  activeProvider: input.provider,
                  activeProviderVmId: null,
                  state: "creating",
                  lastOpenedByUserId: input.userId,
                  updatedAt: now,
                })
                .where(eq(cloudVmBases.id, existing.base.id))
                .returning()
              : await tx
                .insert(cloudVmBases)
                .values({
                  scopeType: scope.scopeType,
                  scopeId: scope.scopeId,
                  name,
                  activeGeneration: nextGeneration,
                  activeVmId: vm.id,
                  activeProvider: input.provider,
                  activeProviderVmId: null,
                  state: "creating",
                  createdByUserId: input.userId,
                  lastOpenedByUserId: input.userId,
                })
                .returning();
            if (!base) throw new Error("base row missing during open");

            if (previousGeneration) {
              await tx
                .update(cloudVmBaseGenerations)
                .set({ state: "retained", retainedAt: now, updatedAt: now })
                .where(eq(cloudVmBaseGenerations.id, previousGeneration.id));
            }

            const [generation] = await tx
              .insert(cloudVmBaseGenerations)
              .values({
                baseId: base.id,
                generation: nextGeneration,
                vmId: vm.id,
                provider: input.provider,
                providerVmId: null,
                state: "creating",
                createdByUserId: input.userId,
              })
              .returning();
            if (!generation) throw new Error("base generation row missing during open");

            await tx.insert(cloudVmBaseEvents).values({
              baseId: base.id,
              userId: input.userId,
              eventType: previousGeneration ? "base.recovered" : "base.created",
              oldGeneration: previousGeneration?.generation ?? null,
              newGeneration: nextGeneration,
              oldVmId: previousVm?.id ?? null,
              newVmId: vm.id,
              oldProviderVmId: previousVm?.providerVmId ?? null,
              newProviderVmId: null,
              metadata: { provider: input.provider, image: input.image },
            });

            return {
              kind: "create" as const,
              base,
              generation,
              vm,
              previousGeneration,
              previousVm,
            };
          });
        } catch (err) {
          if (pgErrorCode(err) === "23505") {
            const [existing] = await db
              .select({
                base: cloudVmBases,
                generation: cloudVmBaseGenerations,
                vm: cloudVms,
              })
              .from(cloudVmBases)
              .innerJoin(
                cloudVmBaseGenerations,
                and(
                  eq(cloudVmBaseGenerations.baseId, cloudVmBases.id),
                  eq(cloudVmBaseGenerations.generation, cloudVmBases.activeGeneration),
                ),
              )
              .innerJoin(cloudVms, eq(cloudVms.id, cloudVmBases.activeVmId))
              .where(and(
                eq(cloudVmBases.scopeType, scope.scopeType),
                eq(cloudVmBases.scopeId, scope.scopeId),
                eq(cloudVmBases.name, name),
              ))
              .limit(1);
            if (existing) {
              return {
                kind: "existing" as const,
                base: existing.base,
                generation: existing.generation,
                vm: existing.vm,
              };
            }
          }
          throw err;
        }
      },
      catch: (cause) => isVmCreateDisabledError(cause) || isVmAccountDeletionInProgressError(cause) || isVmLimitExceededError(cause)
        ? cause
        : new VmDatabaseError({ operation: "beginBaseOpen", cause }),
    }),

  beginBaseReset: (input) =>
    Effect.tryPromise({
      try: async () => {
        const db = cloudDb();
        const scope = baseScope(input);
        const name = baseName(input.baseName);
        return await db.transaction(async (tx) => {
          await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`${scope.scopeType}:${scope.scopeId}:${name}`}, 0))`);
          await assertAccountVmCreateAllowed(tx, {
            userId: input.userId,
            provider: input.provider,
          });
          const [existing] = await tx
            .select({
              base: cloudVmBases,
              generation: cloudVmBaseGenerations,
              vm: cloudVms,
            })
            .from(cloudVmBases)
            .leftJoin(
              cloudVmBaseGenerations,
              and(
                eq(cloudVmBaseGenerations.baseId, cloudVmBases.id),
                eq(cloudVmBaseGenerations.generation, cloudVmBases.activeGeneration),
              ),
            )
            .leftJoin(cloudVms, eq(cloudVms.id, cloudVmBases.activeVmId))
            .where(and(
              eq(cloudVmBases.scopeType, scope.scopeType),
              eq(cloudVmBases.scopeId, scope.scopeId),
              eq(cloudVmBases.name, name),
            ))
            .limit(1);

          const now = new Date();
          const previousGeneration = existing?.generation ?? null;
          const previousVm = existing?.vm ?? null;
          const existingOperationInFlight =
            existing?.base.state === "creating" ||
            existing?.base.state === "opening" ||
            existing?.base.state === "resetting" ||
            previousGeneration?.state === "creating" ||
            previousVm?.status === "provisioning" ||
            (previousVm?.status === "running" && !previousVm.providerVmId);
          if (existingOperationInFlight) {
            throw new VmCreateInProgressError({
              idempotencyKey: previousVm?.idempotencyKey ??
                `base:${scope.scopeType}:${scope.scopeId}:${name}:g${existing?.base.activeGeneration ?? 0}`,
            });
          }
          const nextGeneration = (existing?.base.activeGeneration ?? 0) + 1;
          const idempotencyKey = `base:${scope.scopeType}:${scope.scopeId}:${name}:g${nextGeneration}`;
          const activePredicates = [
            inArray(cloudVms.status, ["provisioning", "running"]),
            eq(cloudVms.billingTeamId, input.billingTeamId),
          ];
          const [active] = await tx
            .select({ total: count() })
            .from(cloudVms)
            .where(and(...activePredicates));
          const activeCount = Number(active?.total ?? 0);
          const limit = input.maxActiveVms;
          if (limit !== null && activeCount >= limit) {
            throw new VmLimitExceededError({
              kind: "active_vms",
              billingTeamId: input.billingTeamId,
              limit,
            });
          }

          const [vm] = await tx
            .insert(cloudVms)
            .values({
              userId: input.userId,
              billingTeamId: input.billingTeamId,
              billingPlanId: input.billingPlanId,
              provider: input.provider,
              imageId: input.image,
              imageVersion: input.imageVersion ?? null,
              status: "provisioning",
              idempotencyKey,
            })
            .returning();
          if (!vm) throw new Error("insert returned no VM row");

          const [base] = existing?.base
            ? await tx
              .update(cloudVmBases)
              .set({
                activeGeneration: nextGeneration,
                activeVmId: vm.id,
                activeProvider: input.provider,
                activeProviderVmId: null,
                state: "resetting",
                lastOpenedByUserId: input.userId,
                updatedAt: now,
              })
              .where(eq(cloudVmBases.id, existing.base.id))
              .returning()
            : await tx
              .insert(cloudVmBases)
              .values({
                scopeType: scope.scopeType,
                scopeId: scope.scopeId,
                name,
                activeGeneration: nextGeneration,
                activeVmId: vm.id,
                activeProvider: input.provider,
                activeProviderVmId: null,
                state: "resetting",
                createdByUserId: input.userId,
                lastOpenedByUserId: input.userId,
              })
              .returning();
          if (!base) throw new Error("base row missing during reset");

          if (previousGeneration) {
            await tx
              .update(cloudVmBaseGenerations)
              .set({ state: "retained", retainedAt: now, updatedAt: now })
              .where(eq(cloudVmBaseGenerations.id, previousGeneration.id));
          }

          const [generation] = await tx
            .insert(cloudVmBaseGenerations)
            .values({
              baseId: base.id,
              generation: nextGeneration,
              vmId: vm.id,
              provider: input.provider,
              providerVmId: null,
              state: "creating",
              createdByUserId: input.userId,
            })
            .returning();
          if (!generation) throw new Error("base generation row missing during reset");

          await tx.insert(cloudVmBaseEvents).values({
            baseId: base.id,
            userId: input.userId,
            eventType: "base.reset",
            oldGeneration: previousGeneration?.generation ?? null,
            newGeneration: nextGeneration,
            oldVmId: previousVm?.id ?? null,
            newVmId: vm.id,
            oldProviderVmId: previousVm?.providerVmId ?? null,
            newProviderVmId: null,
            reason: input.reason?.trim() || null,
            metadata: { provider: input.provider, image: input.image },
          });

          return {
            kind: "create" as const,
            base,
            generation,
            vm,
            previousGeneration,
            previousVm,
          };
        });
      },
      catch: (cause) => isVmCreateDisabledError(cause) || isVmAccountDeletionInProgressError(cause) || isVmLimitExceededError(cause)
        ? cause
        : new VmDatabaseError({ operation: "beginBaseReset", cause }),
    }),

  markBaseCreateRunning: (input) =>
    dbEffect("markBaseCreateRunning", async () => {
      const db = cloudDb();
      return await db.transaction(async (tx) => {
        const now = new Date();
        const [vm] = await tx
          .update(cloudVms)
          .set({
            providerVmId: input.providerVmId,
            imageId: input.image,
            imageVersion: input.imageVersion ?? null,
            providerMetadata: input.providerMetadata ?? {},
            status: "running",
            failureCode: null,
            failureMessage: null,
            updatedAt: now,
          })
          .where(eq(cloudVms.id, input.vmId))
          .returning();
        if (!vm) throw new Error(`vm row missing during base finalization: ${input.vmId}`);

        await tx
          .update(cloudVmBaseGenerations)
          .set({
            provider: vm.provider,
            providerVmId: input.providerVmId,
            state: "active",
            updatedAt: now,
          })
          .where(and(
            eq(cloudVmBaseGenerations.baseId, input.baseId),
            eq(cloudVmBaseGenerations.generation, input.generation),
            eq(cloudVmBaseGenerations.vmId, input.vmId),
          ));

        await tx
          .update(cloudVmBases)
          .set({
            activeVmId: input.vmId,
            activeProvider: vm.provider,
            activeProviderVmId: input.providerVmId,
            state: "ready",
            lastOpenedByUserId: input.userId,
            updatedAt: now,
          })
          .where(and(
            eq(cloudVmBases.id, input.baseId),
            eq(cloudVmBases.activeGeneration, input.generation),
            eq(cloudVmBases.activeVmId, input.vmId),
          ));

        await tx.insert(cloudVmBaseEvents).values({
          baseId: input.baseId,
          userId: input.userId,
          eventType: "base.ready",
          newGeneration: input.generation,
          newVmId: input.vmId,
          newProviderVmId: input.providerVmId,
          metadata: { provider: vm.provider, image: vm.imageId },
        });

        return vm;
      });
    }),

  markBaseCreateFailed: (input) =>
    dbEffect("markBaseCreateFailed", async () => {
      const db = cloudDb();
      await db.transaction(async (tx) => {
        const now = new Date();
        await tx
          .update(cloudVms)
          .set({
            status: "failed",
            failureCode: input.code,
            failureMessage: input.message,
            updatedAt: now,
          })
          .where(eq(cloudVms.id, input.vmId));
        await tx
          .update(cloudVmBaseGenerations)
          .set({ state: "failed", updatedAt: now })
          .where(and(
            eq(cloudVmBaseGenerations.baseId, input.baseId),
            eq(cloudVmBaseGenerations.generation, input.generation),
            eq(cloudVmBaseGenerations.vmId, input.vmId),
          ));
        const [retained] = await tx
          .select({
            generation: cloudVmBaseGenerations,
            vm: cloudVms,
          })
          .from(cloudVmBaseGenerations)
          .innerJoin(cloudVms, eq(cloudVms.id, cloudVmBaseGenerations.vmId))
          .where(and(
            eq(cloudVmBaseGenerations.baseId, input.baseId),
            sql`${cloudVmBaseGenerations.generation} < ${input.generation}`,
            eq(cloudVmBaseGenerations.state, "retained"),
            ne(cloudVms.status, "failed"),
            ne(cloudVms.status, "destroyed"),
          ))
          .orderBy(desc(cloudVmBaseGenerations.generation))
          .limit(1);
        if (retained?.generation && retained.vm) {
          await tx
            .update(cloudVmBaseGenerations)
            .set({ state: "active", updatedAt: now })
            .where(eq(cloudVmBaseGenerations.id, retained.generation.id));
          await tx
            .update(cloudVmBases)
            .set({
              activeGeneration: retained.generation.generation,
              activeVmId: retained.vm.id,
              activeProvider: retained.vm.provider,
              activeProviderVmId: retained.vm.providerVmId,
              state: retained.vm.providerVmId ? "ready" : "creating",
              updatedAt: now,
            })
            .where(and(
              eq(cloudVmBases.id, input.baseId),
              eq(cloudVmBases.activeGeneration, input.generation),
              eq(cloudVmBases.activeVmId, input.vmId),
            ));
        } else {
          await tx
            .update(cloudVmBases)
            .set({ state: "failed", updatedAt: now })
            .where(and(
              eq(cloudVmBases.id, input.baseId),
              eq(cloudVmBases.activeGeneration, input.generation),
              eq(cloudVmBases.activeVmId, input.vmId),
            ));
        }
        await tx.insert(cloudVmBaseEvents).values({
          baseId: input.baseId,
          userId: input.userId,
          eventType: "base.create_failed",
          oldGeneration: retained?.generation.generation ?? null,
          newGeneration: input.generation,
          oldVmId: retained?.vm.id ?? null,
          newVmId: input.vmId,
          oldProviderVmId: retained?.vm.providerVmId ?? null,
          metadata: { code: input.code, message: input.message },
        });
      });
    }),

  activeLimitCandidates: (input) =>
    dbEffect("activeLimitCandidates", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(cloudVms)
        .where(
          and(
            eq(cloudVms.status, "running"),
            isNotNull(cloudVms.providerVmId),
            accountScopeWhere({ userId: input.userId, billingTeamId: input.billingTeamId }),
          ),
        )
        .orderBy(asc(cloudVms.updatedAt))
        .limit(input.limit);
    }),

  reservePausedResume: (input) =>
    Effect.tryPromise({
      try: async () => {
        const db = cloudDb();
        return await db.transaction(async (tx) => {
          const lockKey = input.billingTeamId ?? `user:${input.userId}`;
          await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`);

          const [current] = await tx
            .select()
            .from(cloudVms)
            .where(
              and(
                eq(cloudVms.id, input.id),
                accountScopeWhere({ userId: input.userId, billingTeamId: input.billingTeamId }),
                eq(cloudVms.providerVmId, input.providerVmId),
              ),
            )
            .limit(1);
          if (!current || current.status !== "paused") return current ?? null;

          const teamScope = accountScopeWhere({
            userId: input.userId,
            billingTeamId: input.billingTeamId,
          });
          const [active] = await tx
            .select({ total: count() })
            .from(cloudVms)
            .where(and(inArray(cloudVms.status, ["provisioning", "running"]), teamScope));
          const activeCount = Number(active?.total ?? 0);
          const limit = input.maxActiveVms;
          if (limit !== null && activeCount >= limit) {
            throw new VmLimitExceededError({
              kind: "active_vms",
              billingTeamId: input.billingTeamId ?? input.userId,
              limit,
            });
          }

          const [reserved] = await tx
            .update(cloudVms)
            .set({ status: "running", updatedAt: new Date() })
            .where(
              and(
                eq(cloudVms.id, input.id),
                eq(cloudVms.status, "paused"),
                eq(cloudVms.providerVmId, input.providerVmId),
              ),
            )
            .returning();
          return reserved ?? current;
        });
      },
      catch: (cause) =>
        isVmLimitExceededError(cause)
          ? cause
          : new VmDatabaseError({ operation: "reservePausedResume", cause }),
    }),

  reconciliationCandidates: (input) =>
    dbEffect("reconciliationCandidates", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(cloudVms)
        .where(and(ne(cloudVms.status, "destroyed"), isNotNull(cloudVms.providerVmId)))
        .orderBy(asc(cloudVms.updatedAt))
        .limit(input.limit);
    }),

  listLiveHomeVolumeNames: (input) =>
    dbEffect("listLiveHomeVolumeNames", async () => {
      const volumeNames = boundedReaperVolumeNames(input.volumeNames);
      // Never fall back to the old unbounded inventory query. The reaper
      // supplies a bounded chunk, and an empty chunk is fail-closed.
      if (volumeNames.length === 0) return [];
      const db = cloudDb();
      const homeVolume = sql<string | null>`${cloudVms.providerMetadata}->>'homeVolume'`;
      const rows = await db
        .select({ homeVolume })
        .from(cloudVms)
        .where(and(
          eq(cloudVms.provider, input.provider),
          inArray(homeVolume, volumeNames),
          inArray(cloudVms.status, ["provisioning", "running", "paused"]),
          sql`${homeVolume} is not null and ${homeVolume} <> ''`,
        ));
      return rows
        .map((row) => row.homeVolume?.trim())
        .filter((name): name is string => !!name);
    }),

  recentReaperReportKeys: (input) =>
    dbEffect("recentReaperReportKeys", async () => {
      const keys = boundedReaperKeys(input.keys);
      // An empty key list must never become an unbounded usage-event scan.
      if (keys.length === 0) return [];
      const db = cloudDb();
      // Every orphan-volume event type (base, unknown-attachment,
      // unknown-reference) is a system event keyed by volume name; only
      // VM-row events (stuck provisioning) key by vmId.
      const reportKey = input.eventType.startsWith("vm.reaper.orphan_volume")
        ? sql<string | null>`${cloudVmUsageEvents.metadata}->>'volumeName'`
        : sql<string | null>`${cloudVmUsageEvents.vmId}::text`;
      const rows = await db
        .select({ key: reportKey })
        .from(cloudVmUsageEvents)
        .where(and(
          eq(cloudVmUsageEvents.eventType, input.eventType),
          gt(cloudVmUsageEvents.createdAt, input.since),
          inArray(reportKey, keys),
        ));
      return [...new Set(
        rows
          .map((row) => row.key?.trim())
          .filter((key): key is string => !!key),
      )];
    }),

  stuckProvisioningCandidates: (input) =>
    dbEffect("stuckProvisioningCandidates", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(cloudVms)
        .where(and(
          eq(cloudVms.status, "provisioning"),
          lt(cloudVms.updatedAt, input.before),
        ))
        .orderBy(asc(cloudVms.updatedAt), asc(cloudVms.id))
        .limit(input.limit);
    }),

  markProviderObservedStatus: (input) =>
    dbEffect("markProviderObservedStatus", async () => {
      const db = cloudDb();
      const updated = await db
        .update(cloudVms)
        .set({
          status: input.status,
          destroyedAt: input.status === "destroyed" ? new Date() : null,
          updatedAt: new Date(),
        })
        .where(
          and(
            eq(cloudVms.id, input.id),
            eq(cloudVms.providerVmId, input.providerVmId),
            ne(cloudVms.status, "destroyed"),
          ),
        )
        .returning({ id: cloudVms.id });
      return updated.length > 0;
    }),

  setDisplayName: (input) =>
    dbEffect("setDisplayName", async () => {
      const db = cloudDb();
      const updated = await db
        .update(cloudVms)
        .set({ displayName: input.displayName, updatedAt: new Date() })
        .where(and(eq(cloudVms.id, input.id), ne(cloudVms.status, "destroyed")))
        .returning({ id: cloudVms.id });
      return updated.length > 0;
    }),

  markCreateRunning: (input) =>
    dbEffect("markCreateRunning", async () => {
      const db = cloudDb();
      const [vm] = await db
        .update(cloudVms)
        .set({
          providerVmId: input.providerVmId,
          imageId: input.image,
          imageVersion: input.imageVersion ?? null,
          providerMetadata: input.providerMetadata ?? {},
          status: "running",
          failureCode: null,
          failureMessage: null,
          updatedAt: new Date(),
        })
        .where(eq(cloudVms.id, input.id))
        .returning();
      if (!vm) throw new Error(`vm row missing during create finalization: ${input.id}`);
      return vm;
    }),

  markCreateFailed: (input) =>
    dbEffect("markCreateFailed", async () => {
      const db = cloudDb();
      await db
        .update(cloudVms)
        .set({
          status: "failed",
          failureCode: input.code,
          failureMessage: input.message,
          updatedAt: new Date(),
        })
        .where(eq(cloudVms.id, input.id));
    }),

  hasOwnedSnapshot: (input) =>
    dbEffect("hasOwnedSnapshot", async () => {
      const db = cloudDb();
      const [event] = await db
        .select({ id: cloudVmUsageEvents.id })
        .from(cloudVmUsageEvents)
        .where(
          and(
            accountUsageScopeWhere({ userId: input.userId, billingTeamId: input.billingTeamId }),
            eq(cloudVmUsageEvents.provider, input.provider),
            eq(cloudVmUsageEvents.eventType, "vm.snapshot.created"),
            sql`${cloudVmUsageEvents.metadata}->>'snapshotId' = ${input.snapshotId}`,
          ),
        )
        .limit(1);
      return !!event;
    }),

  findUserVm: (input) =>
    dbEffect("findUserVm", async () => {
      const db = cloudDb();
      const conditions = [
        accountScopeWhere({ userId: input.userId, billingTeamId: input.billingTeamId }),
        eq(cloudVms.providerVmId, input.providerVmId),
        ne(cloudVms.status, "destroyed"),
      ];
      if (input.provider) conditions.push(eq(cloudVms.provider, input.provider));
      const [vm] = await db
        .select()
        .from(cloudVms)
        .where(and(...conditions))
        .limit(1);
      return vm ?? null;
    }),

  markDestroyed: (id) =>
    dbEffect("markDestroyed", async () => {
      const db = cloudDb();
      await db
        .update(cloudVms)
        .set({
          status: "destroyed",
          destroyedAt: new Date(),
          updatedAt: new Date(),
        })
        .where(eq(cloudVms.id, id));
    }),

  recordLease: (input) =>
    dbEffect("recordLease", async () => {
      const db = cloudDb();
      const values = {
        vmId: input.vmId,
        userId: input.userId,
        kind: input.kind,
        tokenHash: input.tokenHash,
        providerIdentityHandle: input.providerIdentityHandle,
        sessionId: input.sessionId,
        transport: input.transport,
        metadata: input.metadata ?? {},
        expiresAt: input.expiresAt,
      };
      try {
        await db.insert(cloudVmLeases).values(values);
      } catch (err) {
        if (pgErrorCode(err) !== "23505") throw err;
        const [existing] = await db
          .select()
          .from(cloudVmLeases)
          .where(eq(cloudVmLeases.tokenHash, input.tokenHash))
          .limit(1);
        if (
          !existing ||
          existing.vmId !== input.vmId ||
          existing.userId !== input.userId ||
          existing.kind !== input.kind
        ) {
          throw err;
        }
        await db
          .update(cloudVmLeases)
          .set({
            providerIdentityHandle: input.providerIdentityHandle,
            sessionId: input.sessionId,
            transport: input.transport,
            metadata: input.metadata ?? {},
            expiresAt: input.expiresAt,
            revokedAt: null,
          })
          .where(eq(cloudVmLeases.tokenHash, input.tokenHash));
      }
    }),

  expiredIdentityLeases: (input) =>
    dbEffect("expiredIdentityLeases", async () => {
      const db = cloudDb();
      return await db
        .select({
          id: cloudVmLeases.id,
          vmId: cloudVmLeases.vmId,
          userId: cloudVmLeases.userId,
          kind: cloudVmLeases.kind,
          tokenHash: cloudVmLeases.tokenHash,
          providerIdentityHandle: cloudVmLeases.providerIdentityHandle,
          sessionId: cloudVmLeases.sessionId,
          transport: cloudVmLeases.transport,
          metadata: cloudVmLeases.metadata,
          expiresAt: cloudVmLeases.expiresAt,
          consumedAt: cloudVmLeases.consumedAt,
          revokedAt: cloudVmLeases.revokedAt,
          createdAt: cloudVmLeases.createdAt,
          provider: cloudVms.provider,
        })
        .from(cloudVmLeases)
        .innerJoin(cloudVms, eq(cloudVmLeases.vmId, cloudVms.id))
        .where(
          and(
            isNotNull(cloudVmLeases.providerIdentityHandle),
            isNull(cloudVmLeases.revokedAt),
            lt(cloudVmLeases.expiresAt, input.now),
            or(
              sql`${cloudVmLeases.metadata}->>'identityCleanupRetryAfter' is null`,
              sql`(${cloudVmLeases.metadata}->>'identityCleanupRetryAfter')::timestamptz <= ${input.now.toISOString()}::timestamptz`,
            ),
          ),
        )
        .orderBy(asc(cloudVmLeases.expiresAt), asc(cloudVmLeases.createdAt), asc(cloudVmLeases.id))
        .limit(input.limit);
    }),

  accountDeletionIdentityLeases: (input) =>
    dbEffect("accountDeletionIdentityLeases", async () => {
      const db = cloudDb();
      return await db
        .select({
          id: cloudVmLeases.id,
          vmId: cloudVmLeases.vmId,
          userId: cloudVmLeases.userId,
          kind: cloudVmLeases.kind,
          tokenHash: cloudVmLeases.tokenHash,
          providerIdentityHandle: cloudVmLeases.providerIdentityHandle,
          sessionId: cloudVmLeases.sessionId,
          transport: cloudVmLeases.transport,
          metadata: cloudVmLeases.metadata,
          expiresAt: cloudVmLeases.expiresAt,
          consumedAt: cloudVmLeases.consumedAt,
          revokedAt: cloudVmLeases.revokedAt,
          createdAt: cloudVmLeases.createdAt,
          provider: cloudVms.provider,
        })
        .from(cloudVmLeases)
        .innerJoin(cloudVms, eq(cloudVmLeases.vmId, cloudVms.id))
        .where(and(
          eq(cloudVmLeases.userId, input.userId),
          isNotNull(cloudVmLeases.providerIdentityHandle),
          isNull(cloudVmLeases.revokedAt),
        ))
        .orderBy(asc(cloudVmLeases.createdAt), asc(cloudVmLeases.id))
        .limit(input.limit);
    }),

  markLeaseRevocationRetry: (input) =>
    dbEffect("markLeaseRevocationRetry", async () => {
      const db = cloudDb();
      await db
        .update(cloudVmLeases)
        .set({
          metadata: sql<Record<string, unknown>>`
            jsonb_set(
              jsonb_set(
                jsonb_set(
                  ${cloudVmLeases.metadata},
                  '{identityCleanupRetryAfter}',
                  to_jsonb(${input.retryAfter.toISOString()}::text),
                  true
                ),
                '{identityCleanupAttempts}',
                to_jsonb((coalesce((${cloudVmLeases.metadata}->>'identityCleanupAttempts')::int, 0) + 1)),
                true
              ),
              '{identityCleanupLastError}',
              to_jsonb(${input.error.slice(0, 240)}::text),
              true
            )
          `,
        })
        .where(eq(cloudVmLeases.id, input.id));
    }),

  listVmSessions: (input) =>
    dbEffect("listVmSessions", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(cloudVmSessions)
        .where(and(
          eq(cloudVmSessions.vmId, input.vmId),
          ne(cloudVmSessions.status, "closed"),
        ))
        .orderBy(desc(cloudVmSessions.updatedAt));
    }),

  upsertVmSession: (input) =>
    dbEffect("upsertVmSession", async () => {
      const db = cloudDb();
      const now = new Date();
      const [session] = await db
        .insert(cloudVmSessions)
        .values({
          vmId: input.vmId,
          userId: input.userId,
          providerSessionId: input.providerSessionId,
          title: input.title ?? null,
          status: input.status ?? "running",
          attachmentCount: input.attachmentCount ?? 1,
          effectiveCols: input.effectiveCols ?? null,
          effectiveRows: input.effectiveRows ?? null,
          lastKnownCols: input.lastKnownCols ?? null,
          lastKnownRows: input.lastKnownRows ?? null,
          scrollbackBytes: input.scrollbackBytes ?? 0,
          metadata: input.metadata ?? {},
          lastAttachedAt: now,
          updatedAt: now,
        })
        .onConflictDoUpdate({
          target: [cloudVmSessions.vmId, cloudVmSessions.providerSessionId],
          set: {
            userId: input.userId,
            title: input.title ?? null,
            status: input.status ?? "running",
            attachmentCount: sql`${cloudVmSessions.attachmentCount} + ${input.attachmentCount ?? 1}`,
            effectiveCols: input.effectiveCols ?? null,
            effectiveRows: input.effectiveRows ?? null,
            lastKnownCols: input.lastKnownCols ?? null,
            lastKnownRows: input.lastKnownRows ?? null,
            scrollbackBytes: input.scrollbackBytes ?? 0,
            metadata: input.metadata ?? {},
            lastAttachedAt: now,
            updatedAt: now,
            closedAt: null,
          },
        })
        .returning();
      if (!session) throw new Error("cloud VM session upsert returned no row");
      return session;
    }),

  activeIdentityLeases: (vmId, limit) =>
    dbEffect("activeIdentityLeases", async () => {
      const db = cloudDb();
      const query = db
        .select()
        .from(cloudVmLeases)
        .where(
          and(
            eq(cloudVmLeases.vmId, vmId),
            isNotNull(cloudVmLeases.providerIdentityHandle),
            isNull(cloudVmLeases.revokedAt),
          ),
        )
        .orderBy(desc(cloudVmLeases.createdAt));
      return typeof limit === "number" && limit > 0
        ? await query.limit(limit)
        : await query;
    }),

  activeAccessLeasesForUser: (userId) =>
    dbEffect("activeAccessLeasesForUser", async () => {
      const db = cloudDb();
      return await db
        .select({
          id: cloudVmLeases.id,
          vmId: cloudVmLeases.vmId,
          userId: cloudVmLeases.userId,
          kind: cloudVmLeases.kind,
          tokenHash: cloudVmLeases.tokenHash,
          providerIdentityHandle: cloudVmLeases.providerIdentityHandle,
          sessionId: cloudVmLeases.sessionId,
          transport: cloudVmLeases.transport,
          metadata: cloudVmLeases.metadata,
          expiresAt: cloudVmLeases.expiresAt,
          consumedAt: cloudVmLeases.consumedAt,
          revokedAt: cloudVmLeases.revokedAt,
          createdAt: cloudVmLeases.createdAt,
          provider: cloudVms.provider,
          providerVmId: cloudVms.providerVmId,
        })
        .from(cloudVmLeases)
        .innerJoin(cloudVms, eq(cloudVmLeases.vmId, cloudVms.id))
        .where(and(
          eq(cloudVmLeases.userId, userId),
          isNull(cloudVmLeases.revokedAt),
          gt(cloudVmLeases.expiresAt, new Date()),
          ne(cloudVms.status, "destroyed"),
          isNotNull(cloudVms.providerVmId),
        ))
        .orderBy(asc(cloudVmLeases.createdAt), asc(cloudVmLeases.id)) as CloudVmAccessLeaseRow[];
    }),

  markLeasesRevoked: (ids) =>
    dbEffect("markLeasesRevoked", async () => {
      if (ids.length === 0) return;
      const db = cloudDb();
      await Promise.all(
        ids.map((id) =>
          db
            .update(cloudVmLeases)
            .set({ revokedAt: new Date() })
            .where(eq(cloudVmLeases.id, id)),
        ),
      );
    }),

  recordUsageEvent: (input) =>
    dbEffect("recordUsageEvent", async () => {
      const db = cloudDb();
      await db.insert(cloudVmUsageEvents).values({
        userId: input.userId,
        billingTeamId: input.billingTeamId ?? null,
        billingPlanId: input.billingPlanId ?? null,
        vmId: input.vmId ?? null,
        eventType: input.eventType,
        provider: input.provider,
        imageId: input.imageId,
        metadata: input.metadata ?? {},
      });
    }),
  recordUsageEvents: (inputs) =>
    dbEffect("recordUsageEvents", async () => {
      if (inputs.length === 0) return;
      const db = cloudDb();
      await db.insert(cloudVmUsageEvents).values(inputs.map((input) => ({
        userId: input.userId,
        billingTeamId: input.billingTeamId ?? null,
        billingPlanId: input.billingPlanId ?? null,
        vmId: input.vmId ?? null,
        eventType: input.eventType,
        provider: input.provider,
        imageId: input.imageId,
        metadata: input.metadata ?? {},
      })));
    }),
});
