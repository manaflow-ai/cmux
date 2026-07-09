import { and, asc, eq, inArray, isNotNull, isNull, lt, ne, or, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudDbConfig } from "../../db/config";
import {
  accountDeletionTombstones,
  billingEmailClaims,
  cloudVmBaseEvents,
  cloudVmBaseGenerations,
  cloudVmBases,
  cloudVmBillingGrants,
  cloudVmLeases,
  cloudVmNotificationDeliveries,
  cloudVmNotificationEvents,
  cloudVmSessions,
  cloudVmUsageEvents,
  cloudVms,
  deviceTokens,
  devices,
  notificationSendEvents,
  stripeCustomers,
  stripeSubscriptions,
  subrouterTenants,
  vaultCliAuthRequests,
  vaultSessions,
  vaultSnapshots,
  vaultUploadGrants,
  vaultUploadTombstones,
} from "../../db/schema";
import {
  PRO_PLAN_ID,
  TEAM_PLAN_ID,
} from "../billing/pro";
import { isStripeBillingConfigured, stripe } from "../billing/stripe";
import type { ProviderId } from "../vms/drivers";
import { deleteVmSnapshot, destroyAccountOwnedVm, revokeVmIdentityLease, runVmWorkflow } from "../vms/workflows";
import { isVmNotFoundError } from "../vms/errors";
import { deleteObject } from "../vault/storage";
import { withVaultUserQuotaLock } from "../vault/usage";
import {
  createSubrouterClientFromEnv,
  SubrouterClientError,
} from "../subrouter/client";
import {
  accountDeletionAdvisoryLockKey,
  accountDeletionUserHash,
  isBlockingAccountDeletionStatus,
} from "./deletionLock";

const ACCOUNT_DELETION_METADATA_KEY = "cmuxAccountDeletionInProgress";
const ACCOUNT_DELETION_JOB_STALE_MS = 60 * 60 * 1000;
const MAX_ACCOUNT_VM_CLEANUP_PASSES = 3;
const ACCOUNT_VM_SNAPSHOT_CLEANUP_BATCH_SIZE = 50;
const ACCOUNT_VM_LEASE_REVOKE_BATCH_SIZE = 50;
const VAULT_ACCOUNT_DELETION_BATCH_SIZE = 100;

type AccountDeletionWorkflow = unknown;
type AccountDeletionRuntime = {
  readonly cloudDb: typeof cloudDb;
  readonly deleteObject: (key: string) => Promise<void>;
  readonly destroyAccountOwnedVm: (input: {
    readonly userId: string;
    readonly provider: ProviderId;
    readonly providerVmId: string;
  }) => AccountDeletionWorkflow;
  readonly deleteVmSnapshot?: (input: {
    readonly provider: ProviderId;
    readonly snapshotId: string;
  }) => AccountDeletionWorkflow;
  readonly revokeVmIdentityLease?: (input: {
    readonly provider: ProviderId;
    readonly identityHandle: string;
  }) => AccountDeletionWorkflow;
  readonly runVmWorkflow: (workflow: AccountDeletionWorkflow) => Promise<unknown>;
  readonly revokeSubrouterTenant?: (tenantId: string) => Promise<void>;
  readonly isStripeBillingConfigured?: () => boolean;
  readonly stripeClient?: () => ReturnType<typeof stripe>;
};

type AccountDeletionTombstoneRuntime = Pick<AccountDeletionRuntime, "cloudDb">;

const defaultAccountDeletionRuntime: AccountDeletionRuntime = {
  cloudDb,
  deleteObject,
  destroyAccountOwnedVm: (input) => destroyAccountOwnedVm(input),
  deleteVmSnapshot: (input) => deleteVmSnapshot(input),
  revokeVmIdentityLease: (input) => revokeVmIdentityLease(input),
  runVmWorkflow: (workflow) =>
    runVmWorkflow(workflow as Parameters<typeof runVmWorkflow>[0]),
  revokeSubrouterTenant: revokeSubrouterTenantFromEnv,
  isStripeBillingConfigured,
  stripeClient: stripe,
};

type StackJson =
  | null
  | boolean
  | number
  | string
  | readonly StackJson[]
  | { readonly [key: string]: StackJson };
type StackJsonObject = { [key: string]: StackJson };

export type AccountDeletionInput = {
  readonly userId: string;
  readonly ownedTeamIds?: readonly string[];
  readonly retainedTeamBillingOwners?: readonly RetainedTeamBillingOwner[];
};

type AccountDeletionScope = {
  readonly userId: string;
  readonly ownedBillingTeamIds: readonly string[];
  readonly retainedTeamBillingOwners: ReadonlyMap<string, string>;
};

export type RetainedTeamBillingOwner = {
  readonly stackTeamId: string;
  readonly stackUserId: string;
};

export type AccountDeletionStatus =
  | "pending"
  | "in_progress"
  | "stack_delete_pending"
  | "stack_delete_in_progress"
  | "completed"
  | "failed";

export type AccountDeletionRequest = {
  readonly userIdHash: string;
  readonly status: AccountDeletionStatus;
};

export type AccountDeletionJob = {
  readonly userId: string;
  readonly userIdHash: string;
  readonly status: AccountDeletionStatus;
};

export type StackAccountDeletionMetadataUser = {
  readonly clientReadOnlyMetadata?: unknown;
  update(options: { clientReadOnlyMetadata: StackJsonObject }): Promise<void>;
};

export type StackAccountDeletionBlockUser = {
  readonly id: string;
  readonly clientReadOnlyMetadata?: unknown;
};

type AccountDeletionStripeCustomerRow = {
  readonly id: string;
  readonly stackTeamId: string | null;
};

type AccountDeletionStripeSubscriptionRow = {
  readonly id: string;
  readonly plan: string | null;
  readonly scope: string;
  readonly stackTeamId: string | null;
  readonly stackUserId: string | null;
  readonly status: string;
};

export function isStackAccountDeletionInProgress(metadata: unknown): boolean {
  return !!metadata &&
    typeof metadata === "object" &&
    !Array.isArray(metadata) &&
    (metadata as Record<string, unknown>)[ACCOUNT_DELETION_METADATA_KEY] === true;
}

export function isAccountDeletionTombstoneStoreConfigured(): boolean {
  try {
    cloudDbConfig();
    return true;
  } catch (error) {
    if (isMissingCloudDbConfigError(error)) return false;
    throw error;
  }
}

export async function isStackAccountDeletionBlocked(
  user: StackAccountDeletionBlockUser,
  runtime?: AccountDeletionTombstoneRuntime,
): Promise<boolean> {
  if (isStackAccountDeletionInProgress(user.clientReadOnlyMetadata)) return true;
  if (!runtime && !isAccountDeletionTombstoneStoreConfigured()) return false;
  return await hasAccountDeletionTombstone({ userId: user.id }, runtime ?? defaultAccountDeletionRuntime);
}

export async function hasAccountDeletionTombstone(
  input: AccountDeletionInput,
  runtime: AccountDeletionTombstoneRuntime = defaultAccountDeletionRuntime,
): Promise<boolean> {
  const db = runtime.cloudDb();
  const userIdHash = accountDeletionUserHash(input.userId);
  const [row] = await db
    .select({
      userIdHash: accountDeletionTombstones.userIdHash,
      status: accountDeletionTombstones.status,
    })
    .from(accountDeletionTombstones)
    .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
    .limit(1);
  return row?.userIdHash === userIdHash && isBlockingAccountDeletionStatus(row.status);
}

export async function markStackUserDeletionInProgress(
  user: StackAccountDeletionMetadataUser,
): Promise<void> {
  if (isStackAccountDeletionInProgress(user.clientReadOnlyMetadata)) return;
  const metadata = stackJsonObject(user.clientReadOnlyMetadata);
  metadata[ACCOUNT_DELETION_METADATA_KEY] = true;
  await user.update({ clientReadOnlyMetadata: metadata });
}

export async function enqueueAccountDeletion(
  input: AccountDeletionInput,
  runtime: AccountDeletionRuntime = defaultAccountDeletionRuntime,
): Promise<AccountDeletionRequest> {
  const db = runtime.cloudDb();
  const userIdHash = accountDeletionUserHash(input.userId);

  return await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(input.userId)}, 0))`);
    const [existing] = await tx
      .select({
        userIdHash: accountDeletionTombstones.userIdHash,
        status: accountDeletionTombstones.status,
      })
      .from(accountDeletionTombstones)
      .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
      .limit(1);
    if (existing && existing.status !== "failed") return existing;

    const now = new Date();
    if (existing) {
      const [updated] = await tx
        .update(accountDeletionTombstones)
        .set({
          userId: input.userId,
          status: "pending",
          updatedAt: now,
          errorMessage: null,
        })
        .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
        .returning({
          userIdHash: accountDeletionTombstones.userIdHash,
          status: accountDeletionTombstones.status,
        });
      if (!updated) throw new Error("Account deletion request update returned no row");
      return updated;
    }

    const [created] = await tx
      .insert(accountDeletionTombstones)
      .values({
        userIdHash,
        userId: input.userId,
        status: "pending",
        updatedAt: now,
      })
      .returning({
        userIdHash: accountDeletionTombstones.userIdHash,
        status: accountDeletionTombstones.status,
      });
    if (!created) throw new Error("Account deletion request insert returned no row");
    return created;
  });
}

export async function claimAccountDeletionProcessing(
  input: AccountDeletionInput,
  runtime: AccountDeletionRuntime = defaultAccountDeletionRuntime,
): Promise<AccountDeletionStatus | null> {
  const db = runtime.cloudDb();
  const userIdHash = accountDeletionUserHash(input.userId);
  const staleBefore = new Date(Date.now() - ACCOUNT_DELETION_JOB_STALE_MS);

  return await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(input.userId)}, 0))`);
    const [existing] = await tx
      .select({
        status: accountDeletionTombstones.status,
        updatedAt: accountDeletionTombstones.updatedAt,
      })
      .from(accountDeletionTombstones)
      .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
      .limit(1);
    if (!existing || existing.status === "completed") return null;
    if (existing.status === "in_progress" && existing.updatedAt > staleBefore) return null;
    if (existing.status === "stack_delete_in_progress" && existing.updatedAt > staleBefore) return null;

    const now = new Date();
    const processingStatus =
      existing.status === "stack_delete_pending" || existing.status === "stack_delete_in_progress"
        ? "stack_delete_in_progress"
        : "in_progress";
    const [claimed] = await tx
      .update(accountDeletionTombstones)
      .set({
        userId: input.userId,
        status: processingStatus,
        attemptCount: sql`${accountDeletionTombstones.attemptCount} + 1`,
        updatedAt: now,
        startedAt: now,
        errorMessage: null,
      })
      .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
      .returning({ userIdHash: accountDeletionTombstones.userIdHash });
    return claimed ? existing.status : null;
  });
}

export async function listPendingAccountDeletionJobs(
  input: { readonly limit?: number } = {},
  runtime: AccountDeletionRuntime = defaultAccountDeletionRuntime,
): Promise<readonly AccountDeletionJob[]> {
  const db = runtime.cloudDb();
  const limit = Math.max(1, Math.min(input.limit ?? 5, 25));
  const staleBefore = new Date(Date.now() - ACCOUNT_DELETION_JOB_STALE_MS);
  const rows = await db
    .select({
      userId: accountDeletionTombstones.userId,
      userIdHash: accountDeletionTombstones.userIdHash,
      status: accountDeletionTombstones.status,
    })
    .from(accountDeletionTombstones)
    .where(and(
      isNotNull(accountDeletionTombstones.userId),
      or(
        eq(accountDeletionTombstones.status, "pending"),
        eq(accountDeletionTombstones.status, "stack_delete_pending"),
        and(
          eq(accountDeletionTombstones.status, "stack_delete_in_progress"),
          lt(accountDeletionTombstones.updatedAt, staleBefore),
        ),
        and(
          eq(accountDeletionTombstones.status, "in_progress"),
          lt(accountDeletionTombstones.updatedAt, staleBefore),
        ),
      ),
    ))
    .orderBy(asc(accountDeletionTombstones.updatedAt))
    .limit(limit);

  return rows.flatMap((row) =>
    row.userId
      ? [{ userId: row.userId, userIdHash: row.userIdHash, status: row.status }]
      : []
  );
}

export async function markAccountDeletionStackDeletePending(
  input: AccountDeletionInput & { readonly error?: unknown },
  runtime: AccountDeletionRuntime = defaultAccountDeletionRuntime,
): Promise<void> {
  const db = runtime.cloudDb();
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(input.userId)}, 0))`);
    await tx
      .update(accountDeletionTombstones)
      .set({
        userId: input.userId,
        status: "stack_delete_pending",
        updatedAt: now,
        errorMessage: input.error ? accountDeletionErrorMessage(input.error) : null,
      })
      .where(and(
        eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(input.userId)),
        ne(accountDeletionTombstones.status, "completed"),
      ));
  });
}

export async function markAccountDeletionCompleted(
  input: AccountDeletionInput,
  runtime: AccountDeletionRuntime = defaultAccountDeletionRuntime,
): Promise<void> {
  const db = runtime.cloudDb();
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(input.userId)}, 0))`);
    await tx
      .update(accountDeletionTombstones)
      .set({
        userId: null,
        status: "completed",
        updatedAt: now,
        completedAt: now,
        errorMessage: null,
      })
      .where(eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(input.userId)));
  });
}

export async function markAccountDeletionFailed(
  input: AccountDeletionInput & { readonly error: unknown },
  runtime: AccountDeletionRuntime = defaultAccountDeletionRuntime,
): Promise<void> {
  const db = runtime.cloudDb();
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(input.userId)}, 0))`);
    await tx
      .update(accountDeletionTombstones)
      .set({
        userId: input.userId,
        status: "failed",
        updatedAt: now,
        errorMessage: accountDeletionErrorMessage(input.error),
      })
      .where(and(
        eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(input.userId)),
        ne(accountDeletionTombstones.status, "completed"),
      ));
  });
}

export async function markAccountDeletionRetryPending(
  input: AccountDeletionInput & { readonly error: unknown },
  runtime: AccountDeletionRuntime = defaultAccountDeletionRuntime,
): Promise<void> {
  const db = runtime.cloudDb();
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(input.userId)}, 0))`);
    await tx
      .update(accountDeletionTombstones)
      .set({
        userId: input.userId,
        status: "pending",
        updatedAt: now,
        errorMessage: accountDeletionErrorMessage(input.error),
      })
      .where(and(
        eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(input.userId)),
        ne(accountDeletionTombstones.status, "completed"),
      ));
  });
}

export async function assertAccountDeletionCanStart(
  input: AccountDeletionInput,
  runtime: Pick<AccountDeletionRuntime, "cloudDb"> = defaultAccountDeletionRuntime,
): Promise<void> {
  const scope = accountDeletionScope(input);
  const { customerRows, subscriptionRows } = await accountDeletionStripeBillingRows(scope, runtime);
  assertRetainedTeamBillingOwners(scope, customerRows, subscriptionRows);
}

export async function deleteCmuxAccountData(
  input: AccountDeletionInput,
  runtime: AccountDeletionRuntime = defaultAccountDeletionRuntime,
): Promise<void> {
  await assertAccountDeletionCanStart(input, runtime);
  const scope = accountDeletionScope(input);
  const anonymizedUserId = deletedAccountId(input.userId);
  await claimProviderlessAccountVms(scope, runtime);
  await revokeAccountVmIdentityLeases(scope, runtime);
  await destroyProviderBackedAccountVms(scope, runtime);
  await deleteAccountVmSnapshots(scope, runtime);
  await deletePersonalSubrouterTenants(scope, runtime);
  const vaultObjectsDeleted = await withVaultUserQuotaLock(
    runtime.cloudDb(),
    input.userId,
    async (lockedDb) =>
      await deleteAccountVaultObjectBatch(input.userId, {
        ...runtime,
        cloudDb: () => lockedDb,
      }),
    { allowAccountDeletion: true },
  );
  if (!vaultObjectsDeleted) {
    throw new Error("Account deletion vault cleanup has more objects to delete");
  }

  await cancelStripeAccountBilling(scope, anonymizedUserId, runtime);

  const anonymizedEmail = deletedAccountEmail(anonymizedUserId);
  const now = new Date();
  const db = runtime.cloudDb();

  await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(input.userId)}, 0))`);
    await tx.delete(deviceTokens).where(eq(deviceTokens.userId, input.userId));
    await tx.delete(notificationSendEvents).where(eq(notificationSendEvents.userId, input.userId));
    await tx.delete(devices).where(eq(devices.userId, input.userId));

    await tx.delete(vaultUploadGrants).where(eq(vaultUploadGrants.userId, input.userId));
    await tx.delete(vaultUploadTombstones).where(eq(vaultUploadTombstones.userId, input.userId));
    await tx.delete(vaultCliAuthRequests).where(eq(vaultCliAuthRequests.userId, input.userId));
    await tx.delete(vaultSessions).where(eq(vaultSessions.userId, input.userId));

    await tx.delete(cloudVmNotificationDeliveries)
      .where(eq(cloudVmNotificationDeliveries.userId, input.userId));
    await tx.delete(cloudVmNotificationEvents)
      .where(eq(cloudVmNotificationEvents.userId, input.userId));
    await tx.delete(cloudVmSessions).where(eq(cloudVmSessions.userId, input.userId));
    await tx.delete(cloudVmLeases).where(eq(cloudVmLeases.userId, input.userId));
    await tx.delete(cloudVmUsageEvents).where(personalCloudVmUsageEvents(scope));
    await tx.update(cloudVmUsageEvents)
      .set({ userId: anonymizedUserId })
      .where(teamScopedUsageEventsCreatedByUser(scope));
    await tx.delete(cloudVmBaseEvents).where(eq(cloudVmBaseEvents.userId, input.userId));
    await tx.delete(cloudVmBillingGrants).where(or(
      and(
        eq(cloudVmBillingGrants.billingCustomerType, "user"),
        eq(cloudVmBillingGrants.billingCustomerId, input.userId),
      ),
      and(
        eq(cloudVmBillingGrants.billingCustomerType, "team"),
        inArray(cloudVmBillingGrants.billingCustomerId, scope.ownedBillingTeamIds),
      ),
    ));
    await tx.delete(cloudVmBases).where(or(
      and(
        eq(cloudVmBases.scopeType, "user"),
        eq(cloudVmBases.scopeId, input.userId),
      ),
      and(
        eq(cloudVmBases.scopeType, "team"),
        inArray(cloudVmBases.scopeId, scope.ownedBillingTeamIds),
      ),
    ));
    await tx.delete(cloudVms).where(personalCloudVmRows(scope));
    await tx.update(cloudVms)
      .set({ userId: anonymizedUserId, updatedAt: now })
      .where(teamScopedCloudVmRowsCreatedByUser(scope));

    await tx.update(cloudVmBases)
      .set({ createdByUserId: anonymizedUserId, updatedAt: now })
      .where(eq(cloudVmBases.createdByUserId, input.userId));
    await tx.update(cloudVmBases)
      .set({ lastOpenedByUserId: anonymizedUserId, updatedAt: now })
      .where(eq(cloudVmBases.lastOpenedByUserId, input.userId));
    await tx.update(cloudVmBaseGenerations)
      .set({ createdByUserId: anonymizedUserId, updatedAt: now })
      .where(eq(cloudVmBaseGenerations.createdByUserId, input.userId));

    for (const [teamId, ownerUserId] of scope.retainedTeamBillingOwners) {
      await tx.update(stripeCustomers)
        .set({ stackUserId: ownerUserId, email: null, updatedAt: now })
        .where(and(
          eq(stripeCustomers.stackUserId, input.userId),
          eq(stripeCustomers.stackTeamId, teamId),
        ));
      await tx.update(stripeSubscriptions)
        .set({ stackUserId: ownerUserId, raw: null, updatedAt: now })
        .where(and(
          eq(stripeSubscriptions.stackUserId, input.userId),
          eq(stripeSubscriptions.stackTeamId, teamId),
          eq(stripeSubscriptions.scope, "team"),
        ));
    }

    await tx.update(stripeCustomers)
      .set({ stackUserId: anonymizedUserId, email: null, updatedAt: now })
      .where(eq(stripeCustomers.stackUserId, input.userId));
    for (const teamId of scope.ownedBillingTeamIds) {
      await tx.update(stripeCustomers)
        .set({
          stackUserId: anonymizedUserId,
          stackTeamId: deletedOwnedTeamId(teamId),
          email: null,
          updatedAt: now,
        })
        .where(eq(stripeCustomers.stackTeamId, teamId));
    }
    await tx.update(stripeSubscriptions)
      .set({ status: "canceled", cancelAtPeriodEnd: false, raw: null, updatedAt: now })
      .where(or(
        and(
          eq(stripeSubscriptions.stackUserId, input.userId),
          eq(stripeSubscriptions.scope, "user"),
        ),
        and(
          inArray(stripeSubscriptions.stackTeamId, scope.ownedBillingTeamIds),
          eq(stripeSubscriptions.scope, "team"),
        ),
      ));
    await tx.update(stripeSubscriptions)
      .set({ stackUserId: anonymizedUserId, raw: null, updatedAt: now })
      .where(eq(stripeSubscriptions.stackUserId, input.userId));
    for (const teamId of scope.ownedBillingTeamIds) {
      await tx.update(stripeSubscriptions)
        .set({
          stackUserId: anonymizedUserId,
          stackTeamId: deletedOwnedTeamId(teamId),
          raw: null,
          updatedAt: now,
        })
        .where(eq(stripeSubscriptions.stackTeamId, teamId));
    }
    await tx.update(billingEmailClaims)
      .set({ stackUserId: anonymizedUserId, email: anonymizedEmail })
      .where(eq(billingEmailClaims.stackUserId, input.userId));
    await tx.update(billingEmailClaims)
      .set({ claimedByUserId: null })
      .where(eq(billingEmailClaims.claimedByUserId, input.userId));
  });
}

function accountDeletionScope(input: AccountDeletionInput): AccountDeletionScope {
  const ownedBillingTeamIds = uniqueStrings([input.userId, ...(input.ownedTeamIds ?? [])]);
  return {
    userId: input.userId,
    ownedBillingTeamIds,
    retainedTeamBillingOwners: retainedTeamBillingOwnerMap({
      deletedUserId: input.userId,
      ownedBillingTeamIds,
      retainedTeamBillingOwners: input.retainedTeamBillingOwners ?? [],
    }),
  };
}

function retainedTeamBillingOwnerMap(input: {
  readonly deletedUserId: string;
  readonly ownedBillingTeamIds: readonly string[];
  readonly retainedTeamBillingOwners: readonly RetainedTeamBillingOwner[];
}): ReadonlyMap<string, string> {
  const owners = new Map<string, string>();
  for (const entry of input.retainedTeamBillingOwners) {
    const stackTeamId = entry.stackTeamId.trim();
    const stackUserId = entry.stackUserId.trim();
    if (!stackTeamId || !stackUserId) continue;
    if (stackUserId === input.deletedUserId) continue;
    if (input.ownedBillingTeamIds.includes(stackTeamId)) continue;
    if (!owners.has(stackTeamId)) owners.set(stackTeamId, stackUserId);
  }
  return owners;
}

async function deletePersonalSubrouterTenants(
  scope: AccountDeletionScope,
  runtime: AccountDeletionRuntime,
): Promise<void> {
  for (const teamId of scope.ownedBillingTeamIds) {
    await deletePersonalSubrouterTenant(teamId, runtime);
  }
}

async function deletePersonalSubrouterTenant(
  teamId: string,
  runtime: AccountDeletionRuntime,
): Promise<void> {
  const db = runtime.cloudDb();
  const [tenant] = await db
    .select({ tenantId: subrouterTenants.tenantId })
    .from(subrouterTenants)
    .where(eq(subrouterTenants.teamId, teamId))
    .limit(1);
  if (!tenant) return;

  await (runtime.revokeSubrouterTenant ?? revokeSubrouterTenantFromEnv)(tenant.tenantId);
  await db.delete(subrouterTenants).where(eq(subrouterTenants.teamId, teamId));
}

async function claimProviderlessAccountVms(
  scope: AccountDeletionScope,
  runtime: AccountDeletionRuntime,
): Promise<void> {
  const db = runtime.cloudDb();
  const now = new Date();
  const staleBefore = new Date(now.getTime() - ACCOUNT_DELETION_JOB_STALE_MS);
  await db
    .update(cloudVms)
    .set({
      status: "destroyed",
      destroyedAt: now,
      updatedAt: now,
      failureCode: "account_deletion_stale_provisioning",
      failureMessage: "Account deletion cleaned up a stale providerless provisioning VM.",
    })
    .where(and(
      personalCloudVmRows(scope),
      eq(cloudVms.status, "provisioning"),
      isNull(cloudVms.providerVmId),
      lt(cloudVms.updatedAt, staleBefore),
    ));

  const [inFlightCreate] = await db
    .select({ id: cloudVms.id })
    .from(cloudVms)
    .where(and(
      personalCloudVmRows(scope),
      eq(cloudVms.status, "provisioning"),
      isNull(cloudVms.providerVmId),
    ))
    .limit(1);
  if (inFlightCreate) {
    throw new Error("Cloud VM account deletion cleanup is waiting for provisioning VMs to settle");
  }

  await db
    .update(cloudVms)
    .set({
      status: "destroyed",
      destroyedAt: now,
      updatedAt: now,
    })
    .where(and(
      personalCloudVmRows(scope),
      ne(cloudVms.status, "destroyed"),
      ne(cloudVms.status, "provisioning"),
      isNull(cloudVms.providerVmId),
    ));
}

async function revokeSubrouterTenantFromEnv(tenantId: string): Promise<void> {
  try {
    await createSubrouterClientFromEnv().revokeTenant(tenantId);
  } catch (error) {
    if (error instanceof SubrouterClientError && error.status === 404) return;
    throw error;
  }
}

async function destroyProviderBackedAccountVms(
  scope: AccountDeletionScope,
  runtime: AccountDeletionRuntime,
): Promise<void> {
  let lastWorkflowError: unknown = null;
  for (let pass = 0; pass < MAX_ACCOUNT_VM_CLEANUP_PASSES; pass += 1) {
    const activeVms = await providerBackedAccountVms(scope, runtime);
    if (activeVms.length === 0) return;
    for (const vm of activeVms) {
      if (!vm.providerVmId) continue;
      try {
        await runtime.runVmWorkflow(runtime.destroyAccountOwnedVm({
          userId: scope.userId,
          provider: vm.provider,
          providerVmId: vm.providerVmId,
        }));
      } catch (error) {
        if (isVmNotFoundError(error)) continue;
        lastWorkflowError = error;
      }
    }
  }

  const remaining = await providerBackedAccountVms(scope, runtime);
  if (remaining.length > 0) {
    if (lastWorkflowError) throw lastWorkflowError;
    throw new Error("Cloud VM account deletion cleanup did not settle");
  }
}

async function providerBackedAccountVms(
  scope: AccountDeletionScope,
  runtime: AccountDeletionRuntime,
): Promise<readonly { readonly provider: ProviderId; readonly providerVmId: string | null }[]> {
  const db = runtime.cloudDb();
  return await db
    .select({ provider: cloudVms.provider, providerVmId: cloudVms.providerVmId })
    .from(cloudVms)
    .where(and(
      personalCloudVmRows(scope),
      ne(cloudVms.status, "destroyed"),
      isNotNull(cloudVms.providerVmId),
    ));
}

function personalCloudVmRows(scope: AccountDeletionScope) {
  return and(
    eq(cloudVms.userId, scope.userId),
    or(
      isNull(cloudVms.billingTeamId),
      inArray(cloudVms.billingTeamId, scope.ownedBillingTeamIds),
    ),
  );
}

function teamScopedCloudVmRowsCreatedByUser(scope: AccountDeletionScope) {
  return and(
    eq(cloudVms.userId, scope.userId),
    isNotNull(cloudVms.billingTeamId),
    ...scope.ownedBillingTeamIds.map((teamId) => ne(cloudVms.billingTeamId, teamId)),
  );
}

function teamScopedUsageEventsCreatedByUser(scope: AccountDeletionScope) {
  return and(
    eq(cloudVmUsageEvents.userId, scope.userId),
    isNotNull(cloudVmUsageEvents.billingTeamId),
    ...scope.ownedBillingTeamIds.map((teamId) => ne(cloudVmUsageEvents.billingTeamId, teamId)),
  );
}

function personalCloudVmUsageEvents(scope: AccountDeletionScope) {
  return and(
    eq(cloudVmUsageEvents.userId, scope.userId),
    or(
      isNull(cloudVmUsageEvents.billingTeamId),
      inArray(cloudVmUsageEvents.billingTeamId, scope.ownedBillingTeamIds),
    ),
  );
}

async function deleteAccountVmSnapshots(
  scope: AccountDeletionScope,
  runtime: AccountDeletionRuntime,
): Promise<void> {
  const db = runtime.cloudDb();
  const buildWorkflow = runtime.deleteVmSnapshot ?? defaultAccountDeletionRuntime.deleteVmSnapshot;
  if (!buildWorkflow) {
    throw new Error("Cloud VM snapshot deletion is not configured");
  }

  for (;;) {
    const snapshots = await accountVmSnapshotRows(scope, runtime);
    if (snapshots.length === 0) return;
    for (const snapshot of snapshots) {
      await runtime.runVmWorkflow(buildWorkflow({
        provider: snapshot.provider,
        snapshotId: snapshot.snapshotId,
      }));
    }
    await db.delete(cloudVmUsageEvents).where(inArray(cloudVmUsageEvents.id, snapshots.map((row) => row.id)));
  }
}

async function accountVmSnapshotRows(
  scope: AccountDeletionScope,
  runtime: AccountDeletionRuntime,
): Promise<readonly { readonly id: string; readonly provider: ProviderId; readonly snapshotId: string }[]> {
  const db = runtime.cloudDb();
  const rows = await db
    .select({
      id: cloudVmUsageEvents.id,
      provider: cloudVmUsageEvents.provider,
      snapshotId: sql<string | null>`${cloudVmUsageEvents.metadata}->>'snapshotId'`,
    })
    .from(cloudVmUsageEvents)
    .where(and(
      personalCloudVmUsageEvents(scope),
      eq(cloudVmUsageEvents.eventType, "vm.snapshot.created"),
      isNotNull(cloudVmUsageEvents.provider),
      sql`${cloudVmUsageEvents.metadata}->>'snapshotId' is not null`,
    ))
    .limit(ACCOUNT_VM_SNAPSHOT_CLEANUP_BATCH_SIZE);
  return rows.flatMap((row) => {
    const snapshotId = row.snapshotId?.trim();
    if (!row.provider || !snapshotId) return [];
    return [{ id: row.id, provider: row.provider, snapshotId }];
  });
}

async function revokeAccountVmIdentityLeases(
  scope: AccountDeletionScope,
  runtime: AccountDeletionRuntime,
): Promise<void> {
  const db = runtime.cloudDb();
  const buildWorkflow = runtime.revokeVmIdentityLease ?? defaultAccountDeletionRuntime.revokeVmIdentityLease;
  if (!buildWorkflow) {
    throw new Error("Cloud VM identity lease revocation is not configured");
  }

  for (;;) {
    const leases = await accountVmIdentityLeaseRows(scope, runtime);
    if (leases.length === 0) return;

    const revokedIds: string[] = [];
    for (const lease of leases) {
      const identityHandle = lease.providerIdentityHandle?.trim();
      if (identityHandle) {
        await runtime.runVmWorkflow(buildWorkflow({
          provider: lease.provider,
          identityHandle,
        }));
      }
      revokedIds.push(lease.id);
    }

    if (revokedIds.length > 0) {
      await db
        .update(cloudVmLeases)
        .set({ revokedAt: new Date() })
        .where(inArray(cloudVmLeases.id, revokedIds));
    }
  }
}

async function accountVmIdentityLeaseRows(
  scope: AccountDeletionScope,
  runtime: AccountDeletionRuntime,
): Promise<readonly { readonly id: string; readonly provider: ProviderId; readonly providerIdentityHandle: string | null }[]> {
  const db = runtime.cloudDb();
  return await db
    .select({
      id: cloudVmLeases.id,
      provider: cloudVms.provider,
      providerIdentityHandle: cloudVmLeases.providerIdentityHandle,
    })
    .from(cloudVmLeases)
    .innerJoin(cloudVms, eq(cloudVmLeases.vmId, cloudVms.id))
    .where(and(
      eq(cloudVmLeases.userId, scope.userId),
      isNotNull(cloudVmLeases.providerIdentityHandle),
      isNull(cloudVmLeases.revokedAt),
    ))
    .limit(ACCOUNT_VM_LEASE_REVOKE_BATCH_SIZE);
}

async function deleteAccountVaultObjectBatch(
  userId: string,
  runtime: AccountDeletionRuntime,
): Promise<boolean> {
  if (await deleteVaultSnapshotObjectBatch(userId, runtime) > 0) return false;
  if (await deleteVaultUploadGrantObjectBatch(userId, runtime) > 0) return false;
  if (await deleteVaultUploadTombstoneObjectBatch(userId, runtime) > 0) return false;
  return true;
}

async function deleteVaultSnapshotObjectBatch(
  userId: string,
  runtime: AccountDeletionRuntime,
): Promise<number> {
  const db = runtime.cloudDb();
  const rows = await db
    .select({ id: vaultSnapshots.id, objectKey: vaultSnapshots.objectKey })
    .from(vaultSnapshots)
    .innerJoin(vaultSessions, eq(vaultSnapshots.sessionId, vaultSessions.id))
    .where(eq(vaultSessions.userId, userId))
    .limit(VAULT_ACCOUNT_DELETION_BATCH_SIZE);
  if (rows.length === 0) return 0;

  await deleteVaultObjectKeys(rows.map((row) => row.objectKey), runtime);
  await db.delete(vaultSnapshots).where(inArray(vaultSnapshots.id, rows.map((row) => row.id)));
  return rows.length;
}

async function deleteVaultUploadGrantObjectBatch(
  userId: string,
  runtime: AccountDeletionRuntime,
): Promise<number> {
  const db = runtime.cloudDb();
  const rows = await db
    .select({
      id: vaultUploadGrants.id,
      objectKey: vaultUploadGrants.objectKey,
      uploadObjectKey: vaultUploadGrants.uploadObjectKey,
    })
    .from(vaultUploadGrants)
    .where(eq(vaultUploadGrants.userId, userId))
    .limit(VAULT_ACCOUNT_DELETION_BATCH_SIZE);
  if (rows.length === 0) return 0;

  await deleteVaultObjectKeys(rows.flatMap((row) => [row.objectKey, row.uploadObjectKey]), runtime);
  await db.delete(vaultUploadGrants).where(inArray(vaultUploadGrants.id, rows.map((row) => row.id)));
  return rows.length;
}

async function deleteVaultUploadTombstoneObjectBatch(
  userId: string,
  runtime: AccountDeletionRuntime,
): Promise<number> {
  const db = runtime.cloudDb();
  const rows = await db
    .select({
      id: vaultUploadTombstones.id,
      objectKey: vaultUploadTombstones.objectKey,
      uploadObjectKey: vaultUploadTombstones.uploadObjectKey,
    })
    .from(vaultUploadTombstones)
    .where(eq(vaultUploadTombstones.userId, userId))
    .limit(VAULT_ACCOUNT_DELETION_BATCH_SIZE);
  if (rows.length === 0) return 0;

  await deleteVaultObjectKeys(rows.flatMap((row) => [row.objectKey, row.uploadObjectKey]), runtime);
  await db.delete(vaultUploadTombstones).where(inArray(vaultUploadTombstones.id, rows.map((row) => row.id)));
  return rows.length;
}

async function deleteVaultObjectKeys(
  objectKeys: readonly string[],
  runtime: AccountDeletionRuntime,
): Promise<void> {
  for (const key of new Set(objectKeys)) {
    await runtime.deleteObject(key);
  }
}

async function cancelStripeAccountBilling(
  scope: AccountDeletionScope,
  anonymizedUserId: string,
  runtime: AccountDeletionRuntime,
): Promise<void> {
  const { customerRows, subscriptionRows } = await accountDeletionStripeBillingRows(scope, runtime);

  if (customerRows.length === 0 && subscriptionRows.length === 0) return;
  assertRetainedTeamBillingOwners(scope, customerRows, subscriptionRows);
  const isBillingConfigured = runtime.isStripeBillingConfigured ?? isStripeBillingConfigured;
  if (!isBillingConfigured()) {
    throw new Error("Stripe account deletion is not configured");
  }

  const stripeClient = (runtime.stripeClient ?? stripe)();
  for (const customer of customerRows) {
    const retainedOwnerId = retainedTeamBillingOwnerFor(scope, customer.stackTeamId, scope.userId);
    await updateStripeCustomerForAccountDeletion(
      stripeClient,
      customer.id,
      anonymizedUserId,
      isOwnedBillingTeamId(scope, customer.stackTeamId),
      retainedOwnerId,
    );
  }
  for (const subscription of subscriptionRows) {
    if (shouldCancelStripeSubscriptionForAccountDeletion(scope, subscription)) {
      await cancelStripeSubscriptionForAccountDeletion(
        stripeClient,
        subscription.id,
        anonymizedUserId,
        isOwnedBillingTeamId(scope, subscription.stackTeamId),
        null,
        subscription,
      );
      continue;
    }

    const retainedOwnerId = retainedTeamBillingOwnerFor(
      scope,
      subscription.stackTeamId,
      subscription.stackUserId,
    );
    await updateStripeSubscriptionForAccountDeletion(
      stripeClient,
      subscription.id,
      anonymizedUserId,
      isOwnedBillingTeamId(scope, subscription.stackTeamId),
      retainedOwnerId,
      subscription,
    );
  }
}

async function accountDeletionStripeBillingRows(
  scope: AccountDeletionScope,
  runtime: Pick<AccountDeletionRuntime, "cloudDb">,
): Promise<{
  readonly customerRows: readonly AccountDeletionStripeCustomerRow[];
  readonly subscriptionRows: readonly AccountDeletionStripeSubscriptionRow[];
}> {
  const db = runtime.cloudDb();
  const customerRows = await db
    .select({
      id: stripeCustomers.id,
      stackTeamId: stripeCustomers.stackTeamId,
    })
    .from(stripeCustomers)
    .where(or(
      eq(stripeCustomers.stackUserId, scope.userId),
      inArray(stripeCustomers.stackTeamId, scope.ownedBillingTeamIds),
    ));
  const subscriptionRows = await db
    .select({
      id: stripeSubscriptions.id,
      plan: stripeSubscriptions.plan,
      scope: stripeSubscriptions.scope,
      stackTeamId: stripeSubscriptions.stackTeamId,
      stackUserId: stripeSubscriptions.stackUserId,
      status: stripeSubscriptions.status,
    })
    .from(stripeSubscriptions)
    .where(or(
      eq(stripeSubscriptions.stackUserId, scope.userId),
      inArray(stripeSubscriptions.stackTeamId, scope.ownedBillingTeamIds),
    ));
  return { customerRows, subscriptionRows };
}

async function updateStripeCustomerForAccountDeletion(
  stripeClient: ReturnType<typeof stripe>,
  customerId: string,
  anonymizedUserId: string,
  clearStackTeamId: boolean,
  retainedOwnerId: string | null,
): Promise<void> {
  try {
    await stripeClient.customers.update(customerId, {
      email: deletedAccountEmail(anonymizedUserId),
      metadata: accountDeletionStripeMetadata({
        anonymizedUserId,
        clearStackTeamId,
        retainedOwnerId,
      }),
    });
  } catch (error) {
    if (isStripeMissingResourceError(error)) return;
    throw error;
  }
}

async function cancelStripeSubscriptionForAccountDeletion(
  stripeClient: ReturnType<typeof stripe>,
  subscriptionId: string,
  anonymizedUserId: string,
  clearStackTeamId: boolean,
  retainedOwnerId: string | null,
  routing: AccountDeletionSubscriptionRouting,
): Promise<void> {
  const subscription = await retrieveStripeSubscriptionForAccountDeletion(stripeClient, subscriptionId);
  if (!subscription) return;

  await updateStripeSubscriptionForAccountDeletion(
    stripeClient,
    subscriptionId,
    anonymizedUserId,
    clearStackTeamId,
    retainedOwnerId,
    routing,
  );

  if (subscription.status === "canceled") return;

  try {
    await stripeClient.subscriptions.cancel(subscriptionId);
  } catch (error) {
    if (isStripeSubscriptionAlreadyCanceledError(error) || isStripeMissingResourceError(error)) return;
    throw error;
  }
}

async function updateStripeSubscriptionForAccountDeletion(
  stripeClient: ReturnType<typeof stripe>,
  subscriptionId: string,
  anonymizedUserId: string,
  clearStackTeamId: boolean,
  retainedOwnerId: string | null,
  routing: AccountDeletionSubscriptionRouting,
): Promise<void> {
  try {
    await stripeClient.subscriptions.update(subscriptionId, {
      metadata: accountDeletionSubscriptionMetadata({
        anonymizedUserId,
        clearStackTeamId,
        retainedOwnerId,
        routing,
      }),
    });
  } catch (error) {
    if (isStripeMissingResourceError(error)) return;
    throw error;
  }
}

function shouldCancelStripeSubscriptionForAccountDeletion(
  scope: AccountDeletionScope,
  subscription: {
    readonly plan: string | null;
    readonly scope: string;
    readonly stackTeamId: string | null;
    readonly stackUserId: string | null;
  },
): boolean {
  if (
    subscription.stackUserId === scope.userId &&
    subscription.scope === "user" &&
    subscription.plan === PRO_PLAN_ID
  ) {
    return true;
  }
  return isOwnedBillingTeamId(scope, subscription.stackTeamId) &&
    subscription.scope === "team" &&
    subscription.plan === TEAM_PLAN_ID;
}

function accountDeletionStripeMetadata(input: {
  readonly anonymizedUserId: string;
  readonly clearStackTeamId: boolean;
  readonly retainedOwnerId: string | null;
}): Record<string, string> {
  return {
    stackUserId: input.retainedOwnerId ?? "",
    ...(input.clearStackTeamId ? { stackTeamId: "" } : {}),
    deletedAccountId: input.anonymizedUserId,
  };
}

type AccountDeletionSubscriptionRouting = {
  readonly plan: string | null;
  readonly scope: string;
  readonly stackTeamId: string | null;
};

function accountDeletionSubscriptionMetadata(input: {
  readonly anonymizedUserId: string;
  readonly clearStackTeamId: boolean;
  readonly retainedOwnerId: string | null;
  readonly routing: AccountDeletionSubscriptionRouting;
}): Record<string, string> {
  const metadata = accountDeletionStripeMetadata(input);
  if (
    input.retainedOwnerId &&
    input.routing.scope === "team" &&
    input.routing.plan === TEAM_PLAN_ID &&
    input.routing.stackTeamId
  ) {
    metadata.app = "cmux";
    metadata.plan = TEAM_PLAN_ID;
    metadata.stackTeamId = input.routing.stackTeamId;
  }
  return metadata;
}

function deletedAccountEmail(anonymizedUserId: string): string {
  const suffix = anonymizedUserId.startsWith("deleted_")
    ? anonymizedUserId.slice("deleted_".length)
    : anonymizedUserId.replace(/[^A-Za-z0-9]/g, "").slice(0, 24);
  return `deleted+${suffix}@cmux.com`;
}

function assertRetainedTeamBillingOwners(
  scope: AccountDeletionScope,
  customerRows: readonly { readonly stackTeamId: string | null }[],
  subscriptionRows: readonly {
    readonly scope: string;
    readonly stackTeamId: string | null;
    readonly stackUserId: string | null;
  }[],
): void {
  const retainedTeamIds = new Set<string>();
  for (const customer of customerRows) {
    if (retainedTeamBillingOwnerFor(scope, customer.stackTeamId, scope.userId)) continue;
    if (needsRetainedTeamBillingOwner(scope, customer.stackTeamId, scope.userId)) {
      retainedTeamIds.add(customer.stackTeamId);
    }
  }
  for (const subscription of subscriptionRows) {
    if (subscription.scope !== "team") continue;
    if (retainedTeamBillingOwnerFor(scope, subscription.stackTeamId, subscription.stackUserId)) continue;
    if (needsRetainedTeamBillingOwner(scope, subscription.stackTeamId, subscription.stackUserId)) {
      retainedTeamIds.add(subscription.stackTeamId);
    }
  }
  if (retainedTeamIds.size === 0) return;
  throw new Error(
    `Account deletion retained team billing owner missing for ${Array.from(retainedTeamIds).sort().join(", ")}`,
  );
}

function isOwnedBillingTeamId(scope: AccountDeletionScope, stackTeamId: string | null): boolean {
  return !!stackTeamId && scope.ownedBillingTeamIds.includes(stackTeamId);
}

function retainedTeamBillingOwnerFor(
  scope: AccountDeletionScope,
  stackTeamId: string | null,
  stackUserId: string | null,
): string | null {
  if (!needsRetainedTeamBillingOwner(scope, stackTeamId, stackUserId)) return null;
  return stackTeamId ? scope.retainedTeamBillingOwners.get(stackTeamId) ?? null : null;
}

function needsRetainedTeamBillingOwner(
  scope: AccountDeletionScope,
  stackTeamId: string | null,
  stackUserId: string | null,
): stackTeamId is string {
  return !!stackTeamId &&
    stackUserId === scope.userId &&
    !isOwnedBillingTeamId(scope, stackTeamId);
}

async function retrieveStripeSubscriptionForAccountDeletion(
  stripeClient: ReturnType<typeof stripe>,
  subscriptionId: string,
): Promise<{ readonly status: string } | null> {
  try {
    const subscription = await stripeClient.subscriptions.retrieve(subscriptionId);
    return { status: subscription.status };
  } catch (error) {
    if (isStripeMissingResourceError(error)) return null;
    throw error;
  }
}

function deletedAccountId(userId: string): string {
  return `deleted_${accountDeletionUserHash(userId).slice(0, 24)}`;
}

function deletedOwnedTeamId(teamId: string): string {
  return `deleted_team_${accountDeletionUserHash(teamId).slice(0, 24)}`;
}

function accountDeletionErrorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message.slice(0, 500);
  if (typeof error === "string") return error.slice(0, 500);
  return "Account deletion failed";
}

function isMissingCloudDbConfigError(error: unknown): boolean {
  return error instanceof Error && (
    /DATABASE_URL is required/.test(error.message) ||
    /aws-rds-iam database config is missing/.test(error.message)
  );
}

function isStripeMissingResourceError(error: unknown): boolean {
  return stripeErrorCode(error) === "resource_missing" ||
    stripeErrorMessage(error).toLowerCase().includes("no such");
}

function isStripeSubscriptionAlreadyCanceledError(error: unknown): boolean {
  return stripeErrorMessage(error).toLowerCase().includes("already canceled");
}

function stripeErrorCode(error: unknown): string | null {
  if (!error || typeof error !== "object") return null;
  const code = (error as { code?: unknown }).code;
  if (typeof code === "string") return code;
  return stripeErrorCode((error as { cause?: unknown }).cause);
}

function stripeErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  if (error && typeof error === "object") {
    const message = (error as { message?: unknown }).message;
    if (typeof message === "string") return message;
  }
  return "";
}

function uniqueStrings(values: readonly (string | undefined | null)[]): readonly string[] {
  const seen = new Set<string>();
  const strings: string[] = [];
  for (const value of values) {
    const trimmed = value?.trim();
    if (!trimmed || seen.has(trimmed)) continue;
    seen.add(trimmed);
    strings.push(trimmed);
  }
  return strings;
}

function stackJsonObject(value: unknown): StackJsonObject {
  return value && typeof value === "object" && !Array.isArray(value)
    ? { ...(value as StackJsonObject) }
    : {};
}
