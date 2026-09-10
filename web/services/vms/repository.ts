import { randomUUID } from "node:crypto";
import { and, asc, count, desc, eq, gt, gte, inArray, isNotNull, isNull, lt, ne, or, sql } from "drizzle-orm";
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
  cloudVmAccessGrants,
  cloudVmAccessGrantSessions,
  cloudVmSessions,
  cloudVmTunnels,
  cloudVmTunnelEnrollmentLocks,
  cloudVms,
  cloudVmUsageEvents,
} from "../../db/schema";
import {
  accountDeletionAdvisoryLockKey,
  accountDeletionUserHash,
  isBlockingAccountDeletionTombstone,
} from "../account/deletionLock";
import type { ProviderId } from "./drivers";
import { allocateVmSlug } from "./vmNaming";
import {
  VmCreateDisabledError,
  VmCreateInProgressError,
  VmAccountDeletionInProgressError,
  VmDatabaseError,
  VmLimitExceededError,
  VmResizeInProgressError,
  LEGACY_MODEL_PLANE_ENTITLEMENT_FAILURE_CODE,
  VM_MODEL_PLANE_FAILURE_CODES,
  isVmAccountDeletionInProgressError,
  isVmCreateDisabledError,
  isVmCreateInProgressError,
  isVmLimitExceededError,
  isVmResizeInProgressError,
} from "./errors";
import {
  DEFAULT_VM_RESOURCE_RESERVATION,
  VM_DISK_MB_DEFAULT,
  VM_DISK_MB_MAX,
  VM_RESOURCE_RESERVATION_METADATA_KEY,
  VM_RESOURCE_FORK_PENDING_METADATA_KEY,
  VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY,
  VM_RESOURCE_RESIZE_PENDING_METADATA_KEY,
  VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY,
  hasVmResourceReservationMetadata,
  vmResourceReservationFromMetadata,
  vmResourceReconcileRetryFromMetadata,
  vmResourceResizePendingFromMetadata,
  vmResourceResizeUnconfirmedFromMetadata,
  withVmResourceReservationMetadata,
  type VmResourceReservation,
} from "./machineSpec";

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
export type CloudVmAccessGrantRow = typeof cloudVmAccessGrants.$inferSelect;
export type CloudVmAccessGrantSessionRow = typeof cloudVmAccessGrantSessions.$inferSelect;
export type CloudVmTunnelRow = typeof cloudVmTunnels.$inferSelect;
export type CloudVmTunnelEnrollmentLockRow = typeof cloudVmTunnelEnrollmentLocks.$inferSelect;
export type CloudVmLeaseKind = typeof cloudVmLeases.$inferInsert.kind;
export type VmResourceReservationInput = VmResourceReservation;
export type VmResizeReservation = {
  readonly previousDiskMb: number;
  readonly reservedDiskMb: number;
  /** The disk size requested by this operation. */
  readonly requestedDiskMb?: number;
  /** Unique resize generation used by confirmation and rollback. */
  readonly operationId: string;
};
export type CloudVmStatus = CloudVmRow["status"];
export type CloudVmSessionStatus = CloudVmSessionRow["status"];
// Reaper batches are capped at 100. Keep repository calls bounded even if a
// future caller passes a malformed or oversized name list.
const VM_REAPER_REFERENCE_NAME_LIMIT = 100;
const LIVE_VM_RESOURCE_STATUSES = ["provisioning", "running", "paused"] as const;

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
  readonly findAccessGrant?: (input: {
    readonly userId: string;
    readonly accessGrantId?: string;
    readonly deviceId?: string;
  }) => Effect.Effect<CloudVmAccessGrantRow | null, VmDatabaseError>;
  readonly findBlockingRevokedAccessGrant?: (input: {
    readonly userId: string;
    readonly deviceId: string;
    readonly stackSessionId: string;
    readonly sessionIssuedAt: Date;
  }) => Effect.Effect<CloudVmAccessGrantRow | null, VmDatabaseError>;
  readonly listUserAccessGrants?: (userId: string) => Effect.Effect<CloudVmAccessGrantRow[], VmDatabaseError>;
  readonly upsertAccessGrant?: (input: {
    readonly userId: string;
    readonly deviceId: string;
    readonly reportedName?: string | null;
    readonly modelIdentifier?: string | null;
    readonly osVersion?: string | null;
    readonly architecture?: string | null;
    readonly cmuxVersion?: string | null;
    readonly cmuxBuild?: string | null;
    readonly cmuxChannel?: string | null;
  }) => Effect.Effect<CloudVmAccessGrantRow, VmDatabaseError>;
  readonly upsertAccessGrantSession?: (input: {
    readonly accessGrantId: string;
    readonly userId: string;
    readonly stackSessionId: string;
    readonly sessionIssuedAt: Date;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly listAccessGrantSessionIds?: (accessGrantId: string) => Effect.Effect<string[], VmDatabaseError>;
  readonly renameAccessGrant?: (input: {
    readonly id: string;
    readonly userId: string;
    readonly displayName: string | null;
  }) => Effect.Effect<CloudVmAccessGrantRow | null, VmDatabaseError>;
  readonly listAccessGrantTunnels?: (accessGrantId: string) => Effect.Effect<CloudVmTunnelRow[], VmDatabaseError>;
  readonly claimAccessGrantMutation?: (input: {
    readonly id: string;
    readonly leaseId: string;
    readonly now: Date;
    readonly leaseExpiresAt: Date;
  }) => Effect.Effect<boolean, VmDatabaseError>;
  readonly releaseAccessGrantMutation?: (input: {
    readonly id: string;
    readonly leaseId: string;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly revokeAccessGrant?: (id: string) => Effect.Effect<boolean, VmDatabaseError>;
  /** The live (unrevoked) tunnel row for one of the owner's devices. */
  readonly findTunnel?: (input: {
    readonly userId: string;
    readonly deviceFingerprint: string;
    readonly tunnelPurpose: "terminal" | "browser";
  }) => Effect.Effect<CloudVmTunnelRow | null, VmDatabaseError>;
  readonly listUserTunnels?: (userId: string) => Effect.Effect<CloudVmTunnelRow[], VmDatabaseError>;
  readonly insertTunnel?: (input: {
    readonly userId: string;
    readonly networkId: string;
    readonly provider: ProviderId;
    readonly providerTunnelId: string;
    readonly accessGrantId: string;
    readonly deviceFingerprint: string;
    readonly tunnelPurpose: "terminal" | "browser";
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
   * Cross-instance lease around provider-side tunnel enrollment. The lease is
   * keyed by account and device, and the owner token fences release so an
   * expired request cannot release a newer request's lease.
   */
  readonly acquireTunnelEnrollmentLock?: (input: {
    readonly userId: string;
    readonly deviceFingerprint: string;
    readonly ownerToken: string;
    readonly expiresAt: Date;
  }) => Effect.Effect<boolean, VmDatabaseError>;
  readonly releaseTunnelEnrollmentLock?: (input: {
    readonly userId: string;
    readonly deviceFingerprint: string;
    readonly ownerToken: string;
  }) => Effect.Effect<void, VmDatabaseError>;
  /** Extend an owned lease. False means a successor already owns it. */
  readonly renewTunnelEnrollmentLock?: (input: {
    readonly userId: string;
    readonly deviceFingerprint: string;
    readonly ownerToken: string;
    readonly expiresAt: Date;
  }) => Effect.Effect<boolean, VmDatabaseError>;
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
    /** The individual machine shape used for fork, snapshot, and resize recovery. */
    readonly resourceReservation?: VmResourceReservation;
    /** Mark an unfinished provider clone for shape reconciliation. */
    readonly forkPending?: boolean;
    /** Minimum source shape retained when a temporary fork claim is recovered. */
    readonly forkMinimumResourceReservation?: VmResourceReservation;
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
    readonly resourceReservation?: VmResourceReservation;
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
    readonly resourceReservation?: VmResourceReservation;
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
  /** Live rows whose resource claim predates the resource marker. */
  readonly legacyResourceReservationCandidates?: (input: {
    /** Optional owner scope. Omit both fields for the background migration batch. */
    readonly userId?: string;
    readonly billingTeamId?: string | null;
    /** Keep provider reconciliation bounded. */
    readonly limit: number;
  }) => Effect.Effect<CloudVmRow[], VmDatabaseError>;
  /** Defer a legacy resource read without losing its place in the batch. */
  readonly deferResourceReservation?: (input: {
    readonly id: string;
    readonly nextAttemptAt: Date;
  }) => Effect.Effect<void, VmDatabaseError>;
  /** Persist a provider-confirmed claim for a legacy VM row. */
  readonly setResourceReservation?: (input: {
    readonly id: string;
    readonly reservation: VmResourceReservation;
    /** Replace this exact temporary claim, used by native fork finalization. */
    readonly expectedReservation?: VmResourceReservation;
    /** Clear a pending resize only when this generation owns it. */
    readonly expectedResizeOperationId?: string;
    /** Clear an unconfirmed resize only when this generation owns it. */
    readonly expectedResizeUnconfirmedOperationId?: string;
  }) => Effect.Effect<boolean, VmDatabaseError>;
  readonly reservePausedResume: (input: {
    readonly id: string;
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly providerVmId: string;
    readonly maxActiveVms: number | null;
  }) => Effect.Effect<CloudVmRow | null, VmDatabaseError | VmLimitExceededError>;
  /** Reserve a grow-only disk change before provider I/O. Live shape always provides this. */
  readonly reserveVmResize?: (input: {
    readonly id: string;
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly providerVmId: string;
    /** Provider-confirmed current disk, used to repair legacy reservations. */
    readonly currentDiskMb?: number;
    readonly storageMb: number;
    readonly maxActiveVms?: number | null;
  }) => Effect.Effect<VmResizeReservation | null, VmDatabaseError | VmResizeInProgressError>;
  /** Persist the provider-confirmed disk claim after a successful resize. */
  readonly confirmVmResize?: (input: {
    readonly id: string;
    /** The claim written before provider I/O. A newer claim wins the race. */
    readonly expectedDiskMb: number;
    /** The requested size; legacy pending markers may hold a larger size. */
    readonly minimumDiskMb?: number;
    readonly confirmedDiskMb: number;
    /** Unique generation returned by reserveVmResize. */
    readonly operationId: string;
  }) => Effect.Effect<boolean, VmDatabaseError>;
  /** Persist a conservative claim while a completed resize awaits provider stats. */
  readonly markVmResizeUnconfirmed?: (input: {
    readonly id: string;
    /** The claim written before provider I/O. A newer claim wins the race. */
    readonly expectedDiskMb: number;
    /** The requested size; legacy pending markers may hold a larger size. */
    readonly minimumDiskMb?: number;
    /** The claim to restore if the provider never reaches the request. */
    readonly previousDiskMb: number;
    /** Unique generation returned by reserveVmResize. */
    readonly operationId: string;
  }) => Effect.Effect<boolean, VmDatabaseError>;
  /** Restore a reservation when the provider rejected the resize. */
  readonly restoreVmResize?: (input: {
    readonly id: string;
    readonly expectedDiskMb: number;
    readonly previousDiskMb: number;
    /** Unique generation returned by reserveVmResize. */
    readonly operationId: string;
  }) => Effect.Effect<void, VmDatabaseError>;
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
  /** Return the durable resource claim for an owned snapshot, or null when absent. */
  readonly ownedSnapshotResourceReservation?: (input: {
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly provider: ProviderId;
    readonly snapshotId: string;
  }) => Effect.Effect<VmResourceReservation | null, VmDatabaseError>;
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
  readonly recordUsageEvent: (input: VmUsageEventInput) => Effect.Effect<void, VmDatabaseError>;
  readonly recordUsageEvents: (inputs: readonly VmUsageEventInput[]) => Effect.Effect<void, VmDatabaseError>;
};

/**
 * One usage-ledger row. Persisted to `cloud_vm_usage_events` and, for the
 * allowlisted lifecycle types, mirrored to PostHog (services/vms/productAnalytics.ts).
 */
export type VmUsageEventInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly billingPlanId?: string | null;
  readonly vmId?: string | null;
  readonly eventType: string;
  readonly provider?: ProviderId;
  readonly imageId?: string;
  readonly metadata?: Record<string, unknown>;
  /**
   * The machine's `createdAt`, supplied by destroy sites so analytics can
   * report the machine's lifetime. Not persisted: the ledger row already
   * joins to `cloud_vms` by `vmId`.
   */
  readonly vmCreatedAt?: Date | null;
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

/** Statuses whose rows hold their slug (mirrors the partial unique index). */
const SLUG_LIVE_STATUSES = ["provisioning", "running", "paused"] as const;

/**
 * Picks the new row's three-word name inside the create transaction. Takes
 * the billing-team advisory lock first (re-entrant for beginCreate, which
 * already holds it; new for the base paths, whose own lock is per base), so
 * every create in the team serializes here and a free candidate is still
 * free at insert. The partial unique index stays as the backstop.
 */
async function allocateSlugInTx(tx: CloudDbTransaction, billingTeamId: string): Promise<string> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${billingTeamId}, 0))`);
  return allocateVmSlug(async (candidate) => {
    const [taken] = await tx
      .select({ id: cloudVms.id })
      .from(cloudVms)
      .where(
        and(
          eq(cloudVms.billingTeamId, billingTeamId),
          eq(cloudVms.slug, candidate),
          inArray(cloudVms.status, [...SLUG_LIVE_STATUSES]),
        ),
      )
      .limit(1);
    return !!taken;
  });
}

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

function positiveReservationInteger(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
    ? value
    : null;
}

/** SQL predicate for a complete, bounded reservation marker. */
function validResourceReservationMarkerSql() {
  const markerKey = sql.raw(`'${VM_RESOURCE_RESERVATION_METADATA_KEY}'`);
  const marker = sql`coalesce(${cloudVms.providerMetadata}, '{}'::jsonb)->${markerKey}`;
  const field = (key: "vcpus" | "memoryMb" | "diskMb") =>
    sql<string | null>`${marker}->>${sql.raw(`'${key}'`)}`;
  const boundedPositiveInteger = (value: ReturnType<typeof field>) => sql`
    ${value} ~ '^[1-9][0-9]{0,9}$'
    and (length(${value}) < 10 or ${value} <= '2147483647')`;
  return sql`jsonb_typeof(${marker}) = 'object'
    and ${boundedPositiveInteger(field("vcpus"))}
    and ${boundedPositiveInteger(field("memoryMb"))}
    and ${boundedPositiveInteger(field("diskMb"))}`;
}

/** Compare a control-plane reservation marker field by field for CAS updates. */
function resourceReservationMarkerEqualsSql(expected: VmResourceReservation) {
  const markerKey = sql.raw(`'${VM_RESOURCE_RESERVATION_METADATA_KEY}'`);
  const marker = sql`coalesce(${cloudVms.providerMetadata}, '{}'::jsonb)->${markerKey}`;
  const field = (key: "vcpus" | "memoryMb" | "diskMb") =>
    sql<string | null>`${marker}->>${sql.raw(`'${key}'`)}`;
  return sql`
    ${field("vcpus")} = ${String(expected.vcpus)}
    and ${field("memoryMb")} = ${String(expected.memoryMb)}
    and ${field("diskMb")} = ${String(expected.diskMb)}`;
}

/** Store each machine's shape independently, including an unfinished native fork. */
function reservationMetadataForInput(
  reservation: VmResourceReservation | undefined,
  forkPending = false,
  forkMinimumReservation?: VmResourceReservation,
): Record<string, unknown> {
  if (!reservation) return {};
  const metadata = withVmResourceReservationMetadata({}, reservation);
  return forkPending
    ? { ...metadata, [VM_RESOURCE_FORK_PENDING_METADATA_KEY]: forkMinimumReservation ?? reservation }
    : metadata;
}

/** Provider responses cannot write control-plane reservation markers. */
function providerMetadataPatchForPersistence(
  metadata: Record<string, unknown> | null | undefined,
): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(metadata ?? {}).filter(([key]) =>
      key !== VM_RESOURCE_RESERVATION_METADATA_KEY &&
      key !== VM_RESOURCE_FORK_PENDING_METADATA_KEY &&
      key !== VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY &&
      key !== VM_RESOURCE_RESIZE_PENDING_METADATA_KEY &&
      key !== VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY,
    ),
  );
}

/** Build trusted numeric claim JSON without binding a JSON string as a JSON scalar. */
function reservationMetadataJsonb(reservation: VmResourceReservation) {
  return sql`jsonb_build_object(
    ${sql.raw(`'${VM_RESOURCE_RESERVATION_METADATA_KEY}'`)},
    jsonb_build_object(
      'vcpus', ${reservation.vcpus}::integer,
      'memoryMb', ${reservation.memoryMb}::integer,
      'diskMb', ${reservation.diskMb}::integer
    )
  )`;
}

function resizePendingMetadataJsonb(input: {
  readonly operationId: string;
  readonly requestedDiskMb: number;
  readonly previousDiskMb: number;
  readonly createdAtMs: number;
}) {
  return sql`jsonb_build_object(
    'operationId', ${input.operationId}::text,
    'requestedDiskMb', ${input.requestedDiskMb}::integer,
    'previousDiskMb', ${input.previousDiskMb}::integer,
    'createdAtMs', ${input.createdAtMs}::bigint
  )`;
}

function resizeUnconfirmedMetadataJsonb(input: {
  readonly operationId: string;
  readonly requestedDiskMb: number;
  readonly previousDiskMb: number;
  readonly markedAtMs: number;
}) {
  return sql`jsonb_build_object(
    ${sql.raw(`'${VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY}'`)},
    jsonb_build_object(
      'operationId', ${input.operationId}::text,
      'requestedDiskMb', ${input.requestedDiskMb}::integer,
      'previousDiskMb', ${input.previousDiskMb}::integer,
      'markedAtMs', ${input.markedAtMs}::bigint
    )
  )`;
}

function resourceReconcileRetryMetadataJsonb(nextAttemptAtMs: number) {
  return sql`jsonb_build_object(
    ${sql.raw(`'${VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY}'`)},
    jsonb_build_object(
      'nextAttemptAtMs', ${nextAttemptAtMs}::bigint
    )
  )`;
}

/** SQL predicate that keeps deferred rows out until their retry time. */
function resourceReconcileRetryEligibleSql(nowMs: number) {
  const metadata = sql`coalesce(${cloudVms.providerMetadata}, '{}'::jsonb)`;
  const retryAt = sql<string | null>`${metadata}->${sql.raw(`'${VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY}'`)}->>'nextAttemptAtMs'`;
  // The CASE keeps malformed provider metadata from reaching a numeric cast.
  // Invalid markers are eligible immediately so the background pass can heal
  // them instead of starving newer rows.
  return sql`case
    when ${retryAt} ~ '^[0-9]{1,16}$' then
      case
        when (${retryAt})::numeric <= 9007199254740991 then (${retryAt})::numeric
        else 0
      end
    else 0
  end <= ${nowMs}`;
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

/** Repository methods for the cross-instance tunnel enrollment lease. */
const tunnelEnrollmentRepositoryMethods: Pick<
  VmRepositoryShape,
  "acquireTunnelEnrollmentLock" | "releaseTunnelEnrollmentLock" | "renewTunnelEnrollmentLock"
> = {
  acquireTunnelEnrollmentLock: (input) =>
    dbEffect("acquireTunnelEnrollmentLock", async () => {
      const db = cloudDb();
      const now = new Date();
      const [row] = await db
        .insert(cloudVmTunnelEnrollmentLocks)
        .values({
          userId: input.userId,
          deviceFingerprint: input.deviceFingerprint,
          ownerToken: input.ownerToken,
          expiresAt: input.expiresAt,
          createdAt: now,
          updatedAt: now,
        })
        .onConflictDoUpdate({
          target: [
            cloudVmTunnelEnrollmentLocks.userId,
            cloudVmTunnelEnrollmentLocks.deviceFingerprint,
          ],
          // A crashed request leaves an expired lease. Only that lease may be
          // replaced; a live owner remains authoritative on every instance.
          setWhere: sql`${cloudVmTunnelEnrollmentLocks.expiresAt} <= ${now}`,
          set: {
            ownerToken: input.ownerToken,
            expiresAt: input.expiresAt,
            updatedAt: now,
          },
        })
        .returning({ ownerToken: cloudVmTunnelEnrollmentLocks.ownerToken });
      return row?.ownerToken === input.ownerToken;
    }),

  releaseTunnelEnrollmentLock: (input) =>
    dbEffect("releaseTunnelEnrollmentLock", async () => {
      const db = cloudDb();
      await db
        .delete(cloudVmTunnelEnrollmentLocks)
        .where(and(
          eq(cloudVmTunnelEnrollmentLocks.userId, input.userId),
          eq(cloudVmTunnelEnrollmentLocks.deviceFingerprint, input.deviceFingerprint),
          eq(cloudVmTunnelEnrollmentLocks.ownerToken, input.ownerToken),
        ));
    }),

  renewTunnelEnrollmentLock: (input) =>
    dbEffect("renewTunnelEnrollmentLock", async () => {
      const db = cloudDb();
      const now = new Date();
      const [row] = await db
        .update(cloudVmTunnelEnrollmentLocks)
        .set({ expiresAt: input.expiresAt, updatedAt: now })
        .where(and(
          eq(cloudVmTunnelEnrollmentLocks.userId, input.userId),
          eq(cloudVmTunnelEnrollmentLocks.deviceFingerprint, input.deviceFingerprint),
          eq(cloudVmTunnelEnrollmentLocks.ownerToken, input.ownerToken),
          gt(cloudVmTunnelEnrollmentLocks.expiresAt, now),
        ))
        .returning({ ownerToken: cloudVmTunnelEnrollmentLocks.ownerToken });
      return row?.ownerToken === input.ownerToken;
    }),
};

/** The Postgres-backed repository. Workflows wrap it with the analytics sink (see workflows.ts). */
export const vmRepositoryLiveShape: VmRepositoryShape = {
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

  findAccessGrant: (input) =>
    dbEffect("findAccessGrant", async () => {
      const db = cloudDb();
      const selector = input.accessGrantId
        ? eq(cloudVmAccessGrants.id, input.accessGrantId)
        : input.deviceId
          ? eq(cloudVmAccessGrants.deviceId, input.deviceId)
          : sql`false`;
      const [row] = await db
        .select()
        .from(cloudVmAccessGrants)
        .where(and(
          eq(cloudVmAccessGrants.userId, input.userId),
          selector,
          isNull(cloudVmAccessGrants.revokedAt),
        ))
        .limit(1);
      return row ?? null;
    }),

  findBlockingRevokedAccessGrant: (input) =>
    dbEffect("findBlockingRevokedAccessGrant", async () => {
      const db = cloudDb();
      const [result] = await db
        .select({ accessGrant: cloudVmAccessGrants })
        .from(cloudVmAccessGrants)
        .leftJoin(
          cloudVmAccessGrantSessions,
          eq(cloudVmAccessGrantSessions.accessGrantId, cloudVmAccessGrants.id),
        )
        .where(and(
          eq(cloudVmAccessGrants.userId, input.userId),
          isNotNull(cloudVmAccessGrants.revokedAt),
          or(
            eq(cloudVmAccessGrantSessions.stackSessionId, input.stackSessionId),
            and(
              eq(cloudVmAccessGrants.deviceId, input.deviceId),
              gte(cloudVmAccessGrants.revokedAt, input.sessionIssuedAt),
            ),
          ),
        ))
        .orderBy(desc(cloudVmAccessGrants.revokedAt))
        .limit(1);
      return result?.accessGrant ?? null;
    }),

  listUserAccessGrants: (userId) =>
    dbEffect("listUserAccessGrants", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(cloudVmAccessGrants)
        .where(and(
          eq(cloudVmAccessGrants.userId, userId),
          isNull(cloudVmAccessGrants.revokedAt),
        ))
        .orderBy(desc(cloudVmAccessGrants.lastControlPlaneAt));
    }),

  upsertAccessGrant: (input) =>
    dbEffect("upsertAccessGrant", async () => {
      const db = cloudDb();
      const now = new Date();
      const [row] = await db
        .insert(cloudVmAccessGrants)
        .values({
          userId: input.userId,
          deviceId: input.deviceId,
          reportedName: input.reportedName ?? null,
          modelIdentifier: input.modelIdentifier ?? null,
          osVersion: input.osVersion ?? null,
          architecture: input.architecture ?? null,
          cmuxVersion: input.cmuxVersion ?? null,
          cmuxBuild: input.cmuxBuild ?? null,
          cmuxChannel: input.cmuxChannel ?? null,
          lastControlPlaneAt: now,
        })
        .onConflictDoUpdate({
          target: [cloudVmAccessGrants.userId, cloudVmAccessGrants.deviceId],
          targetWhere: sql`${cloudVmAccessGrants.revokedAt} is null`,
          set: {
            reportedName: input.reportedName ?? null,
            modelIdentifier: input.modelIdentifier ?? null,
            osVersion: input.osVersion ?? null,
            architecture: input.architecture ?? null,
            cmuxVersion: input.cmuxVersion ?? null,
            cmuxBuild: input.cmuxBuild ?? null,
            cmuxChannel: input.cmuxChannel ?? null,
            lastControlPlaneAt: now,
            updatedAt: now,
          },
        })
        .returning();
      if (!row) throw new Error("upsertAccessGrant returned no row");
      return row;
    }),

  upsertAccessGrantSession: (input) =>
    dbEffect("upsertAccessGrantSession", async () => {
      const db = cloudDb();
      const now = new Date();
      await db
        .insert(cloudVmAccessGrantSessions)
        .values({
          accessGrantId: input.accessGrantId,
          userId: input.userId,
          stackSessionId: input.stackSessionId,
          sessionIssuedAt: input.sessionIssuedAt,
          lastSeenAt: now,
        })
        .onConflictDoUpdate({
          target: [cloudVmAccessGrantSessions.accessGrantId, cloudVmAccessGrantSessions.stackSessionId],
          set: { sessionIssuedAt: input.sessionIssuedAt, lastSeenAt: now },
        });
    }),

  listAccessGrantSessionIds: (accessGrantId) =>
    dbEffect("listAccessGrantSessionIds", async () => {
      const db = cloudDb();
      const rows = await db
        .select({ stackSessionId: cloudVmAccessGrantSessions.stackSessionId })
        .from(cloudVmAccessGrantSessions)
        .where(eq(cloudVmAccessGrantSessions.accessGrantId, accessGrantId));
      return rows.map((row) => row.stackSessionId);
    }),

  renameAccessGrant: (input) =>
    dbEffect("renameAccessGrant", async () => {
      const db = cloudDb();
      const [row] = await db
        .update(cloudVmAccessGrants)
        .set({ displayName: input.displayName, updatedAt: new Date() })
        .where(and(
          eq(cloudVmAccessGrants.id, input.id),
          eq(cloudVmAccessGrants.userId, input.userId),
          isNull(cloudVmAccessGrants.revokedAt),
        ))
        .returning();
      return row ?? null;
    }),

  listAccessGrantTunnels: (accessGrantId) =>
    dbEffect("listAccessGrantTunnels", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(cloudVmTunnels)
        .where(and(
          eq(cloudVmTunnels.accessGrantId, accessGrantId),
          isNull(cloudVmTunnels.revokedAt),
        ))
        .orderBy(asc(cloudVmTunnels.createdAt));
    }),

  claimAccessGrantMutation: (input) =>
    dbEffect("claimAccessGrantMutation", async () => {
      const db = cloudDb();
      const rows = await db
        .update(cloudVmAccessGrants)
        .set({
          mutationLeaseId: input.leaseId,
          mutationLeaseExpiresAt: input.leaseExpiresAt,
          updatedAt: input.now,
        })
        .where(and(
          eq(cloudVmAccessGrants.id, input.id),
          isNull(cloudVmAccessGrants.revokedAt),
          or(
            isNull(cloudVmAccessGrants.mutationLeaseId),
            lt(cloudVmAccessGrants.mutationLeaseExpiresAt, input.now),
            eq(cloudVmAccessGrants.mutationLeaseId, input.leaseId),
          ),
        ))
        .returning({ id: cloudVmAccessGrants.id });
      return rows.length > 0;
    }),

  releaseAccessGrantMutation: (input) =>
    dbEffect("releaseAccessGrantMutation", async () => {
      const db = cloudDb();
      await db
        .update(cloudVmAccessGrants)
        .set({
          mutationLeaseId: null,
          mutationLeaseExpiresAt: null,
          updatedAt: new Date(),
        })
        .where(and(
          eq(cloudVmAccessGrants.id, input.id),
          eq(cloudVmAccessGrants.mutationLeaseId, input.leaseId),
        ));
    }),

  revokeAccessGrant: (id) =>
    dbEffect("revokeAccessGrant", async () => {
      const db = cloudDb();
      const rows = await db
        .update(cloudVmAccessGrants)
        .set({ revokedAt: new Date(), updatedAt: new Date() })
        .where(and(eq(cloudVmAccessGrants.id, id), isNull(cloudVmAccessGrants.revokedAt)))
        .returning({ id: cloudVmAccessGrants.id });
      return rows.length > 0;
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
          eq(cloudVmTunnels.tunnelPurpose, input.tunnelPurpose),
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
          accessGrantId: input.accessGrantId,
          deviceFingerprint: input.deviceFingerprint,
          tunnelPurpose: input.tunnelPurpose,
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
      // Reservation and resize-generation markers are control-plane state.
      // Provider metadata patches may add addresses and network ids, but cannot
      // overwrite either quota claim or in-flight operation marker.
      const patch = providerMetadataPatchForPersistence(input.patch);
      await db
        .update(cloudVms)
        .set({
          // jsonb || jsonb merges at the top level: patch keys win, others stay.
          providerMetadata: sql`${cloudVms.providerMetadata} || ${JSON.stringify(patch)}::jsonb`,
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
                providerMetadata: reservationMetadataForInput(
                  input.resourceReservation,
                  input.forkPending,
                  input.forkMinimumResourceReservation ?? input.resourceReservation,
                ),
                slug: await allocateSlugInTx(tx, input.billingTeamId),
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
          // oxlint-disable-next-line complexity -- This transaction keeps Base locks, idempotency, and generation writes atomic.
          return await db.transaction(async (tx) => {
            await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`${scope.scopeType}:${scope.scopeId}:${name}`}, 0))`);
            await assertAccountVmCreateAllowed(tx, {
              userId: input.userId,
              provider: input.provider,
            });
            await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.billingTeamId}, 0))`);

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
                providerMetadata: reservationMetadataForInput(
                  input.resourceReservation,
                ),
                slug: await allocateSlugInTx(tx, input.billingTeamId),
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
        // oxlint-disable-next-line complexity -- This transaction keeps Base locks, limits, and generation writes atomic.
        return await db.transaction(async (tx) => {
          await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`${scope.scopeType}:${scope.scopeId}:${name}`}, 0))`);
          await assertAccountVmCreateAllowed(tx, {
            userId: input.userId,
            provider: input.provider,
          });
          await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.billingTeamId}, 0))`);
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
              providerMetadata: reservationMetadataForInput(
                input.resourceReservation,
              ),
              slug: await allocateSlugInTx(tx, input.billingTeamId),
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
      catch: (cause) => isVmCreateDisabledError(cause) || isVmAccountDeletionInProgressError(cause) || isVmLimitExceededError(cause) || isVmCreateInProgressError(cause)
        ? cause
        : new VmDatabaseError({ operation: "beginBaseReset", cause }),
    }),

  markBaseCreateRunning: (input) =>
    dbEffect("markBaseCreateRunning", async () => {
      const db = cloudDb();
      const providerMetadata = providerMetadataPatchForPersistence(input.providerMetadata);
      return await db.transaction(async (tx) => {
        const now = new Date();
        const [vm] = await tx
          .update(cloudVms)
          .set({
            providerVmId: input.providerVmId,
            imageId: input.image,
            imageVersion: input.imageVersion ?? null,
            // Provider metadata is additive. Keep the reservation written by
            // beginBaseOpen/reset even if a driver omits it or returns a stale
            // copy in its handle.
            providerMetadata: sql`(
              coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) || ${JSON.stringify(providerMetadata)}::jsonb
            ) || case
              when ${cloudVms.providerMetadata}->'${sql.raw(VM_RESOURCE_RESERVATION_METADATA_KEY)}' is null then '{}'::jsonb
              else jsonb_build_object('${sql.raw(VM_RESOURCE_RESERVATION_METADATA_KEY)}', ${cloudVms.providerMetadata}->'${sql.raw(VM_RESOURCE_RESERVATION_METADATA_KEY)}')
            end`,
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

  legacyResourceReservationCandidates: (input) =>
    dbEffect("legacyResourceReservationCandidates", async () => {
      const db = cloudDb();
      const nowMs = Date.now();
      const scope = input.billingTeamId?.trim()
        ? eq(cloudVms.billingTeamId, input.billingTeamId.trim())
        : input.userId
          ? and(
            eq(cloudVms.userId, input.userId),
            or(isNull(cloudVms.billingTeamId), eq(cloudVms.billingTeamId, input.userId)),
          )
          : null;
      const predicates = [
        inArray(cloudVms.status, LIVE_VM_RESOURCE_STATUSES),
        isNotNull(cloudVms.providerVmId),
        ...(scope ? [scope] : []),
      ];
      const rows = await db
        .select()
        .from(cloudVms)
        .where(
          and(
            ...predicates,
            resourceReconcileRetryEligibleSql(nowMs),
            or(
              sql`coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) ? ${VM_RESOURCE_RESIZE_PENDING_METADATA_KEY}`,
              sql`coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) ? ${VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY}`,
              sql`coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) ? ${VM_RESOURCE_FORK_PENDING_METADATA_KEY}`,
              sql`not coalesce((${validResourceReservationMarkerSql()}), false)`,
            ),
          ),
        )
        .orderBy(asc(cloudVms.updatedAt))
        .limit(input.limit);
      // Keep a runtime check as a second boundary for adapters that return
      // rows from a different SQL dialect or a stale read replica.
      return rows.filter((row) => {
        const retry = vmResourceReconcileRetryFromMetadata(row.providerMetadata);
        if (retry && retry.nextAttemptAtMs > nowMs) return false;
        return Object.prototype.hasOwnProperty.call(row.providerMetadata ?? {}, VM_RESOURCE_RESIZE_PENDING_METADATA_KEY) ||
          Object.prototype.hasOwnProperty.call(row.providerMetadata ?? {}, VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY) ||
          Object.prototype.hasOwnProperty.call(row.providerMetadata ?? {}, VM_RESOURCE_FORK_PENDING_METADATA_KEY) ||
          !hasVmResourceReservationMetadata(row.providerMetadata);
      });
    }),

  deferResourceReservation: (input) =>
    dbEffect("deferResourceReservation", async () => {
      const nextAttemptAtMs = input.nextAttemptAt.getTime();
      if (!Number.isSafeInteger(nextAttemptAtMs) || nextAttemptAtMs <= 0) {
        throw new Error("resource reconciliation retry time must be a positive timestamp");
      }
      const db = cloudDb();
      await db.transaction(async (tx) => {
        const [initial] = await tx
          .select({ userId: cloudVms.userId, billingTeamId: cloudVms.billingTeamId })
          .from(cloudVms)
          .where(eq(cloudVms.id, input.id))
          .limit(1);
        if (!initial) return;
        const lockKey = initial.billingTeamId?.trim() || `user:${initial.userId}`;
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`);
        await tx
          .update(cloudVms)
          .set({
            // Keep retry state in the row so every worker observes the same
            // backoff and a permanently failing provider cannot monopolize a
            // bounded oldest-first batch.
            providerMetadata: sql`coalesce(${cloudVms.providerMetadata}, '{}'::jsonb)
              || ${resourceReconcileRetryMetadataJsonb(nextAttemptAtMs)}`,
            updatedAt: new Date(),
          })
          .where(and(
            eq(cloudVms.id, input.id),
            inArray(cloudVms.status, LIVE_VM_RESOURCE_STATUSES),
          ));
      });
    }),

  setResourceReservation: (input) =>
    Effect.tryPromise({
      try: async () => {
        const db = cloudDb();
        return await db.transaction(async (tx) => {
          const [initial] = await tx
            .select({
              userId: cloudVms.userId,
              billingTeamId: cloudVms.billingTeamId,
              status: cloudVms.status,
            })
            .from(cloudVms)
            .where(eq(cloudVms.id, input.id))
            .limit(1);
          if (!initial) return false;
          if (!(LIVE_VM_RESOURCE_STATUSES as readonly string[]).includes(initial.status)) return false;
          const lockKey = initial.billingTeamId?.trim() || `user:${initial.userId}`;
          await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`);

          if (input.expectedResizeOperationId !== undefined && input.expectedResizeUnconfirmedOperationId !== undefined) {
            throw new Error("resource repair cannot target two resize generations");
          }
          if (input.expectedReservation !== undefined &&
            (input.expectedResizeOperationId !== undefined || input.expectedResizeUnconfirmedOperationId !== undefined)) {
            throw new Error("resource replacement cannot target a resize generation");
          }
          // A normal legacy repair must not lower an in-flight resize. A pending
          // or unconfirmed repair is a compare-and-set on its generation, so a
          // stale provider read cannot clear a newer marker. A native fork uses
          // the same compare-and-set shape for its pending shape.
          const resizeMarkerPredicate = input.expectedResizeOperationId !== undefined
            ? sql`coalesce(${cloudVms.providerMetadata}, '{}'::jsonb)->${sql.raw(`'${VM_RESOURCE_RESIZE_PENDING_METADATA_KEY}'`)}->>'operationId' = ${input.expectedResizeOperationId}`
            : input.expectedResizeUnconfirmedOperationId !== undefined
              ? sql`coalesce(${cloudVms.providerMetadata}, '{}'::jsonb)->${sql.raw(`'${VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY}'`)}->>'operationId' = ${input.expectedResizeUnconfirmedOperationId}
                and not (coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) ? ${VM_RESOURCE_RESIZE_PENDING_METADATA_KEY})`
              : input.expectedReservation !== undefined
                ? sql`not (coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) ? ${VM_RESOURCE_RESIZE_PENDING_METADATA_KEY})
                  and not (coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) ? ${VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY})`
                : sql`not (coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) ? ${VM_RESOURCE_RESIZE_PENDING_METADATA_KEY})
                  and not (coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) ? ${VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY})`;
          const markerPredicate = input.expectedReservation !== undefined
            ? resourceReservationMarkerEqualsSql(input.expectedReservation)
            : input.expectedResizeOperationId === undefined && input.expectedResizeUnconfirmedOperationId === undefined
              ? sql`not coalesce((${validResourceReservationMarkerSql()}), false)`
              : sql`true`;

          const rows = await tx
            .update(cloudVms)
            .set({
              // Keep provider metadata and the control-plane claim in one JSON
              // document without allowing a stale read to drop other fields.
              providerMetadata: sql`(
                coalesce(${cloudVms.providerMetadata}, '{}'::jsonb)
                || ${reservationMetadataJsonb(input.reservation)}
              ) #- '{${sql.raw(VM_RESOURCE_RESIZE_PENDING_METADATA_KEY)}}'
                #- '{${sql.raw(VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY)}}'
                #- '{${sql.raw(VM_RESOURCE_FORK_PENDING_METADATA_KEY)}}'
                #- '{${sql.raw(VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY)}}'`,
              updatedAt: new Date(),
            })
            .where(and(
              eq(cloudVms.id, input.id),
              inArray(cloudVms.status, LIVE_VM_RESOURCE_STATUSES),
              resizeMarkerPredicate,
              markerPredicate,
            ))
            .returning({ id: cloudVms.id });
          return rows.length > 0;
        });
      },
      catch: (cause) => new VmDatabaseError({ operation: "setResourceReservation", cause }),
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

  reserveVmResize: (input) =>
    Effect.tryPromise({
      try: async () => {
        const db = cloudDb();
        // oxlint-disable-next-line complexity -- The transaction keeps resize generations and recovery markers atomic.
        return await db.transaction(async (tx) => {
          const requestedTeamId = input.billingTeamId?.trim();
          const lockKey = requestedTeamId || `user:${input.userId}`;
          await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`);

          const [current] = await tx
            .select()
            .from(cloudVms)
            .where(and(
              eq(cloudVms.id, input.id),
              accountScopeWhere({ userId: input.userId, billingTeamId: requestedTeamId }),
              eq(cloudVms.providerVmId, input.providerVmId),
            ))
            .limit(1);
          if (!current || current.status === "destroyed") return null;

          const hasPendingMarker = Object.prototype.hasOwnProperty.call(
            current.providerMetadata ?? {},
            VM_RESOURCE_RESIZE_PENDING_METADATA_KEY,
          );
          if (hasPendingMarker) {
            const pending = vmResourceResizePendingFromMetadata(current.providerMetadata);
            // A malformed marker cannot identify an active owner. The locked
            // update below replaces it with a fresh generation.
            if (pending) throw new VmResizeInProgressError({ vmId: current.id });
          }

          const previous = vmResourceReservationFromMetadata(current.providerMetadata);
          const unconfirmed = vmResourceResizeUnconfirmedFromMetadata(current.providerMetadata);
          const isNoopResize = input.currentDiskMb !== undefined && input.storageMb === input.currentDiskMb;
          // An unconfirmed resize deliberately holds the maximum disk claim.
          // A later no-op retry must use the marker's prior/current size, not
          // that temporary maximum, or it can clear the marker while keeping a
          // permanent 256 GB reservation.
          const previousDiskMb = unconfirmed
            ? Math.max(
              unconfirmed.previousDiskMb ?? VM_DISK_MB_DEFAULT,
              input.currentDiskMb ?? 0,
            )
            : Math.max(previous.diskMb, input.currentDiskMb ?? 0);
          const requestedDiskMb = Math.max(previousDiskMb, input.storageMb);
          const requested = {
            ...previous,
            // A stale provider read must never make the durable reservation
            // shrink. The workflow already validates grow-only semantics.
            diskMb: requestedDiskMb,
          };
          const unconfirmedStillPending = isNoopResize &&
            unconfirmed !== null &&
            (input.currentDiskMb ?? 0) < unconfirmed.requestedDiskMb;
          if (unconfirmedStillPending) {
            // The observed provider size is still below the requested resize.
            // Leave the conservative marker for the background recovery pass.
            return {
              previousDiskMb,
              reservedDiskMb: previous.diskMb,
              requestedDiskMb: unconfirmed.requestedDiskMb,
              operationId: unconfirmed.operationId,
            };
          }
          // A resize owns only this machine's pending size. Other machines
          // may create or resize concurrently without consuming its resources.
          const operationId = randomUUID();
          const createdAtMs = Date.now();
          const diskMb = requestedDiskMb;
          const reserved = { ...requested, diskMb };

          await tx
            .update(cloudVms)
            .set({
              providerMetadata: isNoopResize
                ? sql`(
                  coalesce(${cloudVms.providerMetadata}, '{}'::jsonb)
                  || ${reservationMetadataJsonb(reserved)}
                ) #- '{${sql.raw(VM_RESOURCE_RESIZE_PENDING_METADATA_KEY)}}'
                  #- '{${sql.raw(VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY)}}'
                  #- '{${sql.raw(VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY)}}'`
                : sql`(
                  jsonb_set(
                    coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) || ${reservationMetadataJsonb(reserved)},
                    '{${sql.raw(VM_RESOURCE_RESIZE_PENDING_METADATA_KEY)}}',
                    ${resizePendingMetadataJsonb({ operationId, requestedDiskMb, previousDiskMb, createdAtMs })},
                    true
                  )
                ) #- '{${sql.raw(VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY)}}'
                  #- '{${sql.raw(VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY)}}'`,
              updatedAt: new Date(),
            })
            .where(and(eq(cloudVms.id, current.id), ne(cloudVms.status, "destroyed")));
          return {
            previousDiskMb,
            reservedDiskMb: reserved.diskMb,
            requestedDiskMb,
            operationId,
          };
        });
      },
      catch: (cause) => isVmResizeInProgressError(cause)
        ? cause
        : new VmDatabaseError({ operation: "reserveVmResize", cause }),
    }),

  confirmVmResize: (input) =>
    dbEffect("confirmVmResize", async () => {
      const confirmedDiskMb = positiveReservationInteger(input.confirmedDiskMb);
      const expectedDiskMb = positiveReservationInteger(input.expectedDiskMb);
      const minimumDiskMb = input.minimumDiskMb === undefined
        ? expectedDiskMb
        : positiveReservationInteger(input.minimumDiskMb);
      if (confirmedDiskMb === null || expectedDiskMb === null || minimumDiskMb === null) {
        throw new Error("resize disk claims must be positive integers");
      }
      const operationId = typeof input.operationId === "string" ? input.operationId.trim() : "";
      if (operationId.length === 0 || operationId.length > 200) {
        throw new Error("resize operation id must be a non-empty string");
      }
      // Keep a larger pre-resize claim when a provider returns a stale or
      // rounded-down stat. The compare-and-set predicate prevents a late
      // response from overwriting a newer concurrent resize reservation.
      const diskMb = Math.max(minimumDiskMb, confirmedDiskMb);
      const db = cloudDb();
      return await db.transaction(async (tx) => {
        // The resize request runs outside SQL, so confirmation must take the
        // same team lock as create and reserveVmResize before lowering the
        // pending resize shape.
        const [initial] = await tx
          .select({ userId: cloudVms.userId, billingTeamId: cloudVms.billingTeamId })
          .from(cloudVms)
          .where(eq(cloudVms.id, input.id))
          .limit(1);
        if (!initial) return false;
        const lockKey = initial.billingTeamId?.trim() || `user:${initial.userId}`;
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`);

        const rows = await tx
          .update(cloudVms)
          .set({
            providerMetadata: sql`(
              jsonb_set(
                coalesce(${cloudVms.providerMetadata}, '{}'::jsonb),
                '{cmuxResourceReservation,diskMb}',
                to_jsonb(${diskMb}::integer),
                true
              )
            ) #- '{${sql.raw(VM_RESOURCE_RESIZE_PENDING_METADATA_KEY)}}'
              #- '{${sql.raw(VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY)}}'
              #- '{${sql.raw(VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY)}}'`,
            updatedAt: new Date(),
          })
          .where(and(
            eq(cloudVms.id, input.id),
            inArray(cloudVms.status, LIVE_VM_RESOURCE_STATUSES),
            sql`${cloudVms.providerMetadata}->'cmuxResourceReservation'->>'diskMb' = ${String(expectedDiskMb)}`,
            sql`${cloudVms.providerMetadata}->${sql.raw(`'${VM_RESOURCE_RESIZE_PENDING_METADATA_KEY}'`)}->>'operationId' = ${operationId}`,
          ))
          .returning({ id: cloudVms.id });
        return rows.length > 0;
      });
    }),

  markVmResizeUnconfirmed: (input) =>
    dbEffect("markVmResizeUnconfirmed", async () => {
      const expectedDiskMb = positiveReservationInteger(input.expectedDiskMb);
      const minimumDiskMb = input.minimumDiskMb === undefined
        ? expectedDiskMb
        : positiveReservationInteger(input.minimumDiskMb);
      const previousDiskMb = positiveReservationInteger(input.previousDiskMb);
      const operationId = typeof input.operationId === "string" ? input.operationId.trim() : "";
      if (
        expectedDiskMb === null ||
        minimumDiskMb === null ||
        previousDiskMb === null ||
        operationId.length === 0 ||
        operationId.length > 200
      ) {
        throw new Error("invalid unconfirmed resize claim");
      }
      const db = cloudDb();
      return await db.transaction(async (tx) => {
        const [initial] = await tx
          .select({ userId: cloudVms.userId, billingTeamId: cloudVms.billingTeamId })
          .from(cloudVms)
          .where(eq(cloudVms.id, input.id))
          .limit(1);
        if (!initial) return false;
        const lockKey = initial.billingTeamId?.trim() || `user:${initial.userId}`;
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`);
        const rows = await tx
          .update(cloudVms)
          .set({
            // Keep the pending resize shape until a later provider
            // read confirms the real size. The generation check prevents a
            // late stats failure from replacing a newer resize.
            providerMetadata: sql`(
              jsonb_set(
                coalesce(${cloudVms.providerMetadata}, '{}'::jsonb),
                '{cmuxResourceReservation,diskMb}',
                to_jsonb(${VM_DISK_MB_MAX}::integer),
                true
            )
              || ${resizeUnconfirmedMetadataJsonb({
                operationId,
                requestedDiskMb: minimumDiskMb,
                previousDiskMb,
                markedAtMs: Date.now(),
              })}
            ) #- '{${sql.raw(VM_RESOURCE_RESIZE_PENDING_METADATA_KEY)}}'
              #- '{${sql.raw(VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY)}}'`,
            updatedAt: new Date(),
          })
          .where(and(
            eq(cloudVms.id, input.id),
            inArray(cloudVms.status, LIVE_VM_RESOURCE_STATUSES),
            sql`${cloudVms.providerMetadata}->'${sql.raw(VM_RESOURCE_RESERVATION_METADATA_KEY)}'->>'diskMb' = ${String(expectedDiskMb)}`,
            sql`${cloudVms.providerMetadata}->${sql.raw(`'${VM_RESOURCE_RESIZE_PENDING_METADATA_KEY}'`)}->>'operationId' = ${operationId}`,
          ))
          .returning({ id: cloudVms.id });
        return rows.length > 0;
      });
    }),

  restoreVmResize: (input) =>
    dbEffect("restoreVmResize", async () => {
      const operationId = typeof input.operationId === "string" ? input.operationId.trim() : "";
      const previousDiskMb = positiveReservationInteger(input.previousDiskMb);
      const expectedDiskMb = positiveReservationInteger(input.expectedDiskMb);
      if (operationId.length === 0 || operationId.length > 200 || previousDiskMb === null || expectedDiskMb === null) {
        throw new Error("invalid resize rollback claim");
      }
      const db = cloudDb();
      await db.transaction(async (tx) => {
        const [initial] = await tx
          .select()
          .from(cloudVms)
          .where(eq(cloudVms.id, input.id))
          .limit(1);
        if (!initial || initial.status === "destroyed") return;
        const lockKey = initial.billingTeamId?.trim() || `user:${initial.userId}`;
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`);
        const [current] = await tx
          .select()
          .from(cloudVms)
          .where(eq(cloudVms.id, input.id))
          .limit(1);
        if (!current || current.status === "destroyed") return;
        const reservation = vmResourceReservationFromMetadata(current.providerMetadata);
        if (reservation.diskMb !== expectedDiskMb) return;
        await tx
          .update(cloudVms)
          .set({
            providerMetadata: sql`(
              coalesce(${cloudVms.providerMetadata}, '{}'::jsonb)
              || ${reservationMetadataJsonb({
                ...reservation,
                diskMb: previousDiskMb,
              })}
            ) #- '{${sql.raw(VM_RESOURCE_RESIZE_PENDING_METADATA_KEY)}}'
              #- '{${sql.raw(VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY)}}'
              #- '{${sql.raw(VM_RESOURCE_RECONCILE_RETRY_METADATA_KEY)}}'`,
            updatedAt: new Date(),
          })
          .where(and(
            eq(cloudVms.id, input.id),
            ne(cloudVms.status, "destroyed"),
            sql`${cloudVms.providerMetadata}->${sql.raw(`'${VM_RESOURCE_RESIZE_PENDING_METADATA_KEY}'`)}->>'operationId' = ${operationId}`,
          ));
      });
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
      const providerMetadata = providerMetadataPatchForPersistence(input.providerMetadata);
      const [vm] = await db
        .update(cloudVms)
        .set({
          providerVmId: input.providerVmId,
          imageId: input.image,
          imageVersion: input.imageVersion ?? null,
          // Keep the reservation from the transactional create claim. It is
          // the control-plane accounting record, not provider metadata.
          providerMetadata: sql`(
            coalesce(${cloudVms.providerMetadata}, '{}'::jsonb) || ${JSON.stringify(providerMetadata)}::jsonb
          ) || case
            when ${cloudVms.providerMetadata}->'${sql.raw(VM_RESOURCE_RESERVATION_METADATA_KEY)}' is null then '{}'::jsonb
            else jsonb_build_object('${sql.raw(VM_RESOURCE_RESERVATION_METADATA_KEY)}', ${cloudVms.providerMetadata}->'${sql.raw(VM_RESOURCE_RESERVATION_METADATA_KEY)}')
          end`,
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

  ownedSnapshotResourceReservation: (input) =>
    dbEffect("ownedSnapshotResourceReservation", async () => {
      const db = cloudDb();
      const [event] = await db
        .select({
          metadata: cloudVmUsageEvents.metadata,
          sourceMetadata: cloudVms.providerMetadata,
        })
        .from(cloudVmUsageEvents)
        .leftJoin(cloudVms, eq(cloudVmUsageEvents.vmId, cloudVms.id))
        .where(
          and(
            accountUsageScopeWhere({ userId: input.userId, billingTeamId: input.billingTeamId }),
            eq(cloudVmUsageEvents.provider, input.provider),
            eq(cloudVmUsageEvents.eventType, "vm.snapshot.created"),
            sql`${cloudVmUsageEvents.metadata}->>'snapshotId' = ${input.snapshotId}`,
          ),
        )
        .orderBy(desc(cloudVmUsageEvents.createdAt), desc(cloudVmUsageEvents.id))
        .limit(1);
      if (!event) return null;

      const conservativeFallback = {
        ...DEFAULT_VM_RESOURCE_RESERVATION,
        diskMb: VM_DISK_MB_MAX,
      };
      const source = vmResourceReservationFromMetadata(event.sourceMetadata, conservativeFallback);
      const recordedVcpus = positiveReservationInteger(event.metadata?.vcpus);
      const recordedMemoryMb = positiveReservationInteger(event.metadata?.memoryMb);
      const recordedDiskMb = positiveReservationInteger(event.metadata?.diskMb);
      return {
        // New snapshot events record the provider-confirmed shape. For a
        // legacy source, a recorded dimension is authoritative; an absent
        // dimension uses the source claim or the conservative fallback.
        vcpus: recordedVcpus ?? source.vcpus,
        memoryMb: recordedMemoryMb ?? source.memoryMb,
        diskMb: recordedDiskMb ?? source.diskMb,
      };
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
};

// Compose this capability after the legacy shape so existing repository
// functions keep their reviewed complexity fingerprints. The lease methods
// remain one independently testable cross-instance capability.
Object.assign(vmRepositoryLiveShape, tunnelEnrollmentRepositoryMethods);

export const VmRepositoryLive = Layer.succeed(VmRepository, vmRepositoryLiveShape);
