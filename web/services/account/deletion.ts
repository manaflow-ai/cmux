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
  vaultCliAuthRequests,
  vaultSessions,
  vaultSnapshots,
  vaultUploadGrants,
  vaultUploadTombstones,
} from "../../db/schema";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PRO_PLAN_ID,
} from "../billing/pro";
import { isStripeBillingConfigured, stripe } from "../billing/stripe";
import { destroyAccountOwnedVm, runVmWorkflow } from "../vms/workflows";
import { isVmNotFoundError } from "../vms/errors";
import { deleteObject } from "../vault/storage";
import {
  accountDeletionAdvisoryLockKey,
  accountDeletionUserHash,
  isBlockingAccountDeletionStatus,
} from "./deletionLock";

const ACCOUNT_DELETION_METADATA_KEY = "cmuxAccountDeletionInProgress";
const ACCOUNT_DELETION_JOB_STALE_MS = 60 * 60 * 1000;
const MAX_ACCOUNT_VM_CLEANUP_PASSES = 3;
const VAULT_ACCOUNT_DELETION_BATCH_SIZE = 100;

type AccountDeletionWorkflow = unknown;
type AccountDeletionRuntime = {
  readonly cloudDb: typeof cloudDb;
  readonly deleteObject: (key: string) => Promise<void>;
  readonly destroyAccountOwnedVm: (input: {
    readonly userId: string;
    readonly providerVmId: string;
  }) => AccountDeletionWorkflow;
  readonly runVmWorkflow: (workflow: AccountDeletionWorkflow) => Promise<unknown>;
};

const defaultAccountDeletionRuntime: AccountDeletionRuntime = {
  cloudDb,
  deleteObject,
  destroyAccountOwnedVm: (input) => destroyAccountOwnedVm(input),
  runVmWorkflow: (workflow) =>
    runVmWorkflow(workflow as ReturnType<typeof destroyAccountOwnedVm>),
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
};

export type AccountDeletionStatus = "pending" | "in_progress" | "completed" | "failed";

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

export async function hasAccountDeletionTombstone(
  input: AccountDeletionInput,
  runtime: AccountDeletionRuntime = defaultAccountDeletionRuntime,
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
): Promise<boolean> {
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
    if (!existing || existing.status === "completed") return false;
    if (existing.status === "in_progress" && existing.updatedAt > staleBefore) return false;

    const now = new Date();
    const [claimed] = await tx
      .update(accountDeletionTombstones)
      .set({
        userId: input.userId,
        status: "in_progress",
        attemptCount: sql`${accountDeletionTombstones.attemptCount} + 1`,
        updatedAt: now,
        startedAt: now,
        errorMessage: null,
      })
      .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
      .returning({ userIdHash: accountDeletionTombstones.userIdHash });
    return !!claimed;
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
        eq(accountDeletionTombstones.status, "failed"),
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
      .where(eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(input.userId)));
  });
}

export async function deleteCmuxAccountData(
  input: AccountDeletionInput,
  runtime: AccountDeletionRuntime = defaultAccountDeletionRuntime,
): Promise<void> {
  const anonymizedUserId = deletedAccountId(input.userId);
  await claimProviderlessAccountVms(input.userId, runtime);
  await destroyProviderBackedAccountVms(input.userId, runtime);
  await deleteAccountVaultObjects(input.userId, runtime);

  await cancelStripeAccountBilling(input.userId, anonymizedUserId, runtime);

  const anonymizedEmail = `${anonymizedUserId}@deleted.cmux.invalid`;
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
    await tx.delete(cloudVmUsageEvents).where(or(
      eq(cloudVmUsageEvents.billingTeamId, input.userId),
      and(
        eq(cloudVmUsageEvents.userId, input.userId),
        or(
          isNull(cloudVmUsageEvents.billingTeamId),
          eq(cloudVmUsageEvents.billingTeamId, input.userId),
        ),
      ),
    ));
    await tx.update(cloudVmUsageEvents)
      .set({ userId: anonymizedUserId })
      .where(teamScopedUsageEventsCreatedByUser(input.userId));
    await tx.delete(cloudVmBaseEvents).where(eq(cloudVmBaseEvents.userId, input.userId));
    await tx.delete(cloudVmBillingGrants).where(and(
      eq(cloudVmBillingGrants.billingCustomerType, "user"),
      eq(cloudVmBillingGrants.billingCustomerId, input.userId),
    ));
    await tx.delete(cloudVmBases).where(and(
      eq(cloudVmBases.scopeType, "user"),
      eq(cloudVmBases.scopeId, input.userId),
    ));
    await tx.delete(cloudVms).where(personalCloudVmRows(input.userId));
    await tx.update(cloudVms)
      .set({ userId: anonymizedUserId, updatedAt: now })
      .where(teamScopedCloudVmRowsCreatedByUser(input.userId));

    await tx.update(cloudVmBases)
      .set({ createdByUserId: anonymizedUserId, updatedAt: now })
      .where(eq(cloudVmBases.createdByUserId, input.userId));
    await tx.update(cloudVmBases)
      .set({ lastOpenedByUserId: anonymizedUserId, updatedAt: now })
      .where(eq(cloudVmBases.lastOpenedByUserId, input.userId));
    await tx.update(cloudVmBaseGenerations)
      .set({ createdByUserId: anonymizedUserId, updatedAt: now })
      .where(eq(cloudVmBaseGenerations.createdByUserId, input.userId));

    await tx.update(stripeCustomers)
      .set({ stackUserId: anonymizedUserId, email: null, updatedAt: now })
      .where(eq(stripeCustomers.stackUserId, input.userId));
    await tx.update(stripeSubscriptions)
      .set({ status: "canceled", cancelAtPeriodEnd: false, raw: null, updatedAt: now })
      .where(and(
        eq(stripeSubscriptions.stackUserId, input.userId),
        eq(stripeSubscriptions.scope, "user"),
      ));
    await tx.update(stripeSubscriptions)
      .set({ stackUserId: anonymizedUserId, raw: null, updatedAt: now })
      .where(eq(stripeSubscriptions.stackUserId, input.userId));
    await tx.update(billingEmailClaims)
      .set({ stackUserId: anonymizedUserId, email: anonymizedEmail })
      .where(eq(billingEmailClaims.stackUserId, input.userId));
    await tx.update(billingEmailClaims)
      .set({ claimedByUserId: null })
      .where(eq(billingEmailClaims.claimedByUserId, input.userId));
  });
}

async function claimProviderlessAccountVms(
  userId: string,
  runtime: AccountDeletionRuntime,
): Promise<void> {
  const db = runtime.cloudDb();
  const [inFlightCreate] = await db
    .select({ id: cloudVms.id })
    .from(cloudVms)
    .where(and(
      personalCloudVmRows(userId),
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
      destroyedAt: new Date(),
      updatedAt: new Date(),
    })
    .where(and(
      personalCloudVmRows(userId),
      ne(cloudVms.status, "destroyed"),
      ne(cloudVms.status, "provisioning"),
      isNull(cloudVms.providerVmId),
    ));
}

async function destroyProviderBackedAccountVms(
  userId: string,
  runtime: AccountDeletionRuntime,
): Promise<void> {
  let lastWorkflowError: unknown = null;
  for (let pass = 0; pass < MAX_ACCOUNT_VM_CLEANUP_PASSES; pass += 1) {
    const activeVms = await providerBackedAccountVms(userId, runtime);
    if (activeVms.length === 0) return;
    for (const vm of activeVms) {
      if (!vm.providerVmId) continue;
      try {
        await runtime.runVmWorkflow(runtime.destroyAccountOwnedVm({
          userId,
          providerVmId: vm.providerVmId,
        }));
      } catch (error) {
        if (isVmNotFoundError(error)) continue;
        lastWorkflowError = error;
      }
    }
  }

  const remaining = await providerBackedAccountVms(userId, runtime);
  if (remaining.length > 0) {
    if (lastWorkflowError) throw lastWorkflowError;
    throw new Error("Cloud VM account deletion cleanup did not settle");
  }
}

async function providerBackedAccountVms(
  userId: string,
  runtime: AccountDeletionRuntime,
): Promise<readonly { readonly providerVmId: string | null }[]> {
  const db = runtime.cloudDb();
  return await db
    .select({ providerVmId: cloudVms.providerVmId })
    .from(cloudVms)
    .where(and(
      personalCloudVmRows(userId),
      ne(cloudVms.status, "destroyed"),
      isNotNull(cloudVms.providerVmId),
    ));
}

function personalCloudVmRows(userId: string) {
  return and(
    eq(cloudVms.userId, userId),
    or(isNull(cloudVms.billingTeamId), eq(cloudVms.billingTeamId, userId)),
  );
}

function teamScopedCloudVmRowsCreatedByUser(userId: string) {
  return and(
    eq(cloudVms.userId, userId),
    isNotNull(cloudVms.billingTeamId),
    ne(cloudVms.billingTeamId, userId),
  );
}

function teamScopedUsageEventsCreatedByUser(userId: string) {
  return and(
    eq(cloudVmUsageEvents.userId, userId),
    isNotNull(cloudVmUsageEvents.billingTeamId),
    ne(cloudVmUsageEvents.billingTeamId, userId),
  );
}

async function deleteAccountVaultObjects(
  userId: string,
  runtime: AccountDeletionRuntime,
): Promise<void> {
  for (;;) {
    const deleted =
      await deleteVaultSnapshotObjectBatch(userId, runtime) +
      await deleteVaultUploadGrantObjectBatch(userId, runtime) +
      await deleteVaultUploadTombstoneObjectBatch(userId, runtime);
    if (deleted === 0) return;
  }
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
  userId: string,
  anonymizedUserId: string,
  runtime: AccountDeletionRuntime,
): Promise<void> {
  const db = runtime.cloudDb();
  const customerRows = await db
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.stackUserId, userId));
  const subscriptionRows = await db
    .select({ id: stripeSubscriptions.id })
    .from(stripeSubscriptions)
    .where(and(
      eq(stripeSubscriptions.stackUserId, userId),
      eq(stripeSubscriptions.scope, "user"),
      eq(stripeSubscriptions.plan, PRO_PLAN_ID),
      inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
    ));

  if (customerRows.length === 0 && subscriptionRows.length === 0) return;
  if (!isStripeBillingConfigured()) {
    throw new Error("Stripe account deletion is not configured");
  }

  const stripeClient = stripe();
  for (const customer of customerRows) {
    await updateStripeCustomerForAccountDeletion(stripeClient, customer.id, anonymizedUserId);
  }
  for (const subscription of subscriptionRows) {
    await cancelStripeSubscriptionForAccountDeletion(stripeClient, subscription.id, anonymizedUserId);
  }
}

async function updateStripeCustomerForAccountDeletion(
  stripeClient: ReturnType<typeof stripe>,
  customerId: string,
  anonymizedUserId: string,
): Promise<void> {
  try {
    await stripeClient.customers.update(customerId, {
      email: "",
      metadata: { stackUserId: "", deletedAccountId: anonymizedUserId },
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
): Promise<void> {
  const subscription = await retrieveStripeSubscriptionForAccountDeletion(stripeClient, subscriptionId);
  if (!subscription || subscription.status === "canceled") return;

  await stripeClient.subscriptions.update(subscriptionId, {
    metadata: { stackUserId: "", deletedAccountId: anonymizedUserId },
  });

  try {
    await stripeClient.subscriptions.cancel(subscriptionId);
  } catch (error) {
    if (isStripeSubscriptionAlreadyCanceledError(error) || isStripeMissingResourceError(error)) return;
    throw error;
  }
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

function stackJsonObject(value: unknown): StackJsonObject {
  return value && typeof value === "object" && !Array.isArray(value)
    ? { ...(value as StackJsonObject) }
    : {};
}
