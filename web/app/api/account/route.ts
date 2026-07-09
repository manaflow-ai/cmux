import { and, asc, eq, inArray, isNotNull, isNull, or, sql } from "drizzle-orm";

import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { cloudDb } from "../../../db/client";
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
} from "../../../db/schema";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  type ProMetadataJson,
  type ProMetadataCustomer,
} from "../../../services/billing/pro";
import { isAscConfigured } from "../../../services/asc/client";
import { removeTester } from "../../../services/asc/testflight";
import { captureAscError } from "../../../services/errors";
import { isStripeBillingConfigured, stripe } from "../../../services/billing/stripe";
import {
  createSubrouterClientFromEnv,
  SubrouterClientError,
} from "../../../services/subrouter/client";
import { deleteObject } from "../../../services/vault/storage";
import {
  accountDeletionAdvisoryLockKey,
  accountDeletionUserHash,
  isBlockingAccountDeletionStatus,
} from "../../../services/account/deletionLock";
import { unauthorized } from "../../../services/vms/auth";
import { isVmAccountDeletionIdentityRevocationError } from "../../../services/vms/errors";
import type { ProviderId } from "../../../services/vms/drivers";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import {
  destroyVm,
  listUserVms,
  revokeUserIdentityLeasesForAccountDeletion,
  runVmWorkflow,
} from "../../../services/vms/workflows";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const VAULT_OBJECT_DELETE_BATCH_SIZE = 100;
const DELETED_ACCOUNT_ACTOR_ID = "deleted-account";

type DeletableStackUser = {
  readonly id: string;
  readonly primaryEmail?: string | null;
  readonly selectedTeam?: unknown;
  readonly listTeams?: () => Promise<readonly unknown[]>;
  readonly delete: () => Promise<void>;
} & ProMetadataCustomer;

type AccountDeletionStackTeam = {
  readonly id: string;
  readonly listUsers?: () => Promise<readonly unknown[]>;
};

type RetainedTeamBillingOwner = {
  readonly stackTeamId: string;
  readonly stackUserId: string;
};

const ACCOUNT_DELETION_TOMBSTONE_LEASE_MS = 15 * 60 * 1000;

export async function DELETE(request: Request): Promise<Response> {
  const stackUser = await currentDeletableStackUser(request);
  if (!stackUser) return unauthorized();

  const userId = stackUser.id;
  const originalStackMetadata = stackUser.clientReadOnlyMetadata;
  let stackMetadataMarked = false;
  let accountDeletionTombstoneStarted = false;
  let cmuxOwnedRowsDeleted = false;
  let destructiveCleanupStarted = false;
  let destroyedVms = 0;
  let restoreBillingEntitlementsOnFailure = true;
  try {
    const accountScope = await accountDeletionScopeForUser(stackUser);
    accountDeletionTombstoneStarted = await markAccountDeletionTombstonePending(userId);
    if (!accountDeletionTombstoneStarted) {
      return jsonResponse({ ok: true, deletionPending: true, destroyedVms: 0 }, 202);
    }
    await markAccountDeletingAndClearBillingEntitlements(stackUser);
    stackMetadataMarked = true;
    await resolveUserBillingForAccountDeletion(
      userId,
      accountScope.teamIds,
      accountScope.retainedTeamBillingOwners,
      {
        beforeExternalRequest: () => {
          restoreBillingEntitlementsOnFailure = false;
          destructiveCleanupStarted = true;
        },
      },
    );
    await removeTestFlightAccessForAccountDeletion(stackUser, {
      afterExternalMutation: () => {
        restoreBillingEntitlementsOnFailure = false;
        destructiveCleanupStarted = true;
      },
    });
    try {
      destroyedVms = await destroyPersonalCloudVms(userId, accountScope.teamIds);
      if (destroyedVms > 0) destructiveCleanupStarted = true;
    } catch (error) {
      if (error instanceof AccountDeletionDestructiveCleanupError) {
        destroyedVms = error.destroyedVms;
        destructiveCleanupStarted = error.destructiveCleanupStarted;
      }
      throw error;
    }
    await deleteVaultRowsAndObjectsForAccount(userId, {
      beforeObjectDeletion: () => {
        destructiveCleanupStarted = true;
      },
    });
    await deletePersonalSubrouterTenant(userId, {
      afterExternalMutation: () => {
        destructiveCleanupStarted = true;
      },
    }, accountScope.teamIds);
    try {
      const revokedIdentityLeases = await runVmWorkflow(revokeUserIdentityLeasesForAccountDeletion(userId));
      if (revokedIdentityLeases > 0) destructiveCleanupStarted = true;
    } catch (error) {
      if (isVmAccountDeletionIdentityRevocationError(error)) destructiveCleanupStarted = true;
      throw error;
    }
    // Delete cmux-owned data before the Stack user so a Stack-side failure does
    // not strand retained app data behind an account the user can no longer use.
    // These deletes are idempotent, so the same signed-in user can retry the
    // final Stack deletion when the distinct response below is returned.
    await deleteCmuxOwnedAccountRows(userId, accountScope.teamIds);
    cmuxOwnedRowsDeleted = true;
    try {
      await stackUser.delete();
    } catch (error) {
      logAccountDeleteError("account.delete.stack_user_failed_after_data_delete", error);
      if (accountDeletionTombstoneStarted) await markAccountDeletionTombstoneFailed(userId, error);
      return jsonResponse({
        error: "account_delete_retryable",
        retryable: true,
        destroyedVms,
      }, 500);
    }
    try {
      await markAccountDeletionTombstoneCompleted(userId);
      await finishPostStackAccountCleanup(userId, accountScope.teamIds);
    } catch (error) {
      logAccountDeleteError("account.delete.post_stack_cleanup_failed", error);
      return jsonResponse({
        ok: true,
        cleanupIncomplete: true,
        destroyedVms,
      }, 202);
    }
    return jsonResponse({ ok: true, destroyedVms });
  } catch (error) {
    if (destructiveCleanupStarted || cmuxOwnedRowsDeleted) {
      if (accountDeletionTombstoneStarted) await markAccountDeletionTombstoneFailed(userId, error);
      logAccountDeleteError("account.delete.partial_after_destructive_cleanup", error);
      return jsonResponse({
        error: "account_delete_retryable",
        retryable: true,
        destroyedVms,
      }, 500);
    }
    if (stackMetadataMarked) {
      await restoreStackMetadataAfterAccountDeletionFailure(stackUser, originalStackMetadata, {
        restoreBillingEntitlements: restoreBillingEntitlementsOnFailure,
      });
    }
    if (accountDeletionTombstoneStarted) await markAccountDeletionTombstoneFailed(userId, error);
    logAccountDeleteError("account.delete.failed", error);
    return jsonResponse({ error: "account_delete_failed" }, 500);
  }
}

async function currentDeletableStackUser(request: Request): Promise<DeletableStackUser | null> {
  if (!isStackConfigured()) return null;

  const authHeader = request.headers.get("authorization");
  const refreshHeader = request.headers.get("x-stack-refresh-token");
  if (!authHeader?.toLowerCase().startsWith("bearer ") || !refreshHeader) return null;

  const accessToken = authHeader.slice("bearer ".length).trim();
  const refreshToken = refreshHeader.trim();
  if (!accessToken || !refreshToken) return null;

  const user = await getStackServerApp().getUser({
    tokenStore: { accessToken, refreshToken },
  });
  const candidate = user as Partial<DeletableStackUser>;
  if (!user || typeof candidate.delete !== "function" || typeof candidate.update !== "function") return null;
  return user as DeletableStackUser;
}

async function markAccountDeletionTombstonePending(userId: string): Promise<boolean> {
  const db = cloudDb();
  const now = new Date();
  const userIdHash = accountDeletionUserHash(userId);
  return await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0))`);
    const [existing] = await tx
      .select({
        userIdHash: accountDeletionTombstones.userIdHash,
        status: accountDeletionTombstones.status,
        updatedAt: accountDeletionTombstones.updatedAt,
      })
      .from(accountDeletionTombstones)
      .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
      .limit(1);
    if (existing?.status === "completed") return false;
    if (existing && isBlockingAccountDeletionStatus(existing.status) && !isStaleAccountDeletionTombstone(existing.updatedAt, now)) {
      return false;
    }

    await tx
      .insert(accountDeletionTombstones)
      .values({
        userId,
        userIdHash,
        status: "pending",
        attemptCount: 1,
        updatedAt: now,
        errorMessage: null,
      })
      .onConflictDoUpdate({
        target: accountDeletionTombstones.userIdHash,
        set: {
          userId,
          status: "pending",
          updatedAt: now,
          attemptCount: sql`${accountDeletionTombstones.attemptCount} + 1`,
          errorMessage: null,
        },
      });
    return true;
  });
}

function isStaleAccountDeletionTombstone(updatedAt: Date | null, now: Date): boolean {
  return !updatedAt || now.getTime() - updatedAt.getTime() >= ACCOUNT_DELETION_TOMBSTONE_LEASE_MS;
}

async function markAccountDeletionTombstoneCompleted(userId: string): Promise<void> {
  const now = new Date();
  await cloudDb()
    .update(accountDeletionTombstones)
    .set({
      userId: null,
      status: "completed",
      updatedAt: now,
      completedAt: now,
      errorMessage: null,
    })
    .where(eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(userId)));
}

async function markAccountDeletionTombstoneFailed(userId: string, error: unknown): Promise<void> {
  await cloudDb()
    .update(accountDeletionTombstones)
    .set({
      status: "failed",
      updatedAt: new Date(),
      errorMessage: sanitizedErrorSummary(error),
    })
    .where(eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(userId)));
}

class AccountDeletionDestructiveCleanupError extends Error {
  constructor(
    message: string,
    readonly destroyedVms: number,
    readonly destructiveCleanupStarted: boolean,
  ) {
    super(message);
    this.name = "AccountDeletionDestructiveCleanupError";
  }
}

async function destroyPersonalCloudVms(userId: string, accountTeamIds: readonly string[]): Promise<number> {
  const vms = await listAccountDeletionCloudVms(userId, accountTeamIds);
  const failures: unknown[] = [];
  let destroyedVms = 0;
  let destructiveCleanupStarted = false;
  for (const vm of vms) {
    try {
      const destroyInput: {
        userId: string;
        billingTeamId?: string | null;
        teamIds: readonly string[];
        providerVmId: string;
        provider: ProviderId;
      } = {
        userId,
        teamIds: accountTeamIds,
        providerVmId: vm.providerVmId,
        provider: vm.provider,
      };
      if (vm.billingTeamId) destroyInput.billingTeamId = vm.billingTeamId;
      const destroyProgram = destroyVm(destroyInput);
      destructiveCleanupStarted = true;
      await runVmWorkflow(destroyProgram);
      destroyedVms += 1;
    } catch (error) {
      failures.push(error);
      logAccountDeleteError("account.delete.vm_destroy_failed", error);
    }
  }
  if (failures.length > 0) {
    throw new AccountDeletionDestructiveCleanupError(
      `Failed to destroy ${failures.length} personal cloud VM${failures.length === 1 ? "" : "s"}`,
      destroyedVms,
      destructiveCleanupStarted,
    );
  }
  return destroyedVms;
}

async function listAccountDeletionCloudVms(
  userId: string,
  accountTeamIds: readonly string[],
): Promise<Array<{ readonly providerVmId: string; readonly provider: ProviderId; readonly billingTeamId?: string | null }>> {
  const vms = new Map<
    string,
    { readonly providerVmId: string; readonly provider: ProviderId; readonly billingTeamId?: string | null }
  >();
  const legacyScopedVms = await runVmWorkflow(listUserVms(userId));
  for (const vm of legacyScopedVms) {
    vms.set(accountDeletionVmKey(vm), {
      providerVmId: vm.providerVmId,
      provider: vm.provider,
    });
  }
  for (const teamId of accountTeamIds) {
    if (teamId === userId) continue;
    const teamScopedVms = await runVmWorkflow(listUserVms(userId, teamId));
    for (const vm of teamScopedVms) {
      vms.set(accountDeletionVmKey(vm), {
        providerVmId: vm.providerVmId,
        provider: vm.provider,
        billingTeamId: teamId,
      });
    }
  }
  return [...vms.values()];
}

function accountDeletionVmKey(vm: { readonly provider: ProviderId; readonly providerVmId: string }): string {
  return `${vm.provider}:${vm.providerVmId}`;
}

async function deleteVaultRowsAndObjectsForAccount(
  userId: string,
  options: { readonly beforeObjectDeletion?: () => void } = {},
): Promise<void> {
  const db = cloudDb();

  for (;;) {
    const snapshots = await db
      .select({ id: vaultSnapshots.id, objectKey: vaultSnapshots.objectKey })
      .from(vaultSnapshots)
      .innerJoin(vaultSessions, eq(vaultSnapshots.sessionId, vaultSessions.id))
      .where(eq(vaultSessions.userId, userId))
      .orderBy(asc(vaultSnapshots.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE);
    if (snapshots.length === 0) break;
    options.beforeObjectDeletion?.();
    await Promise.all(snapshots.map((snapshot) => deleteObject(snapshot.objectKey)));
    await db.delete(vaultSnapshots).where(inArray(vaultSnapshots.id, snapshots.map((snapshot) => snapshot.id)));
    if (snapshots.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }

  for (;;) {
    const grants = await db
      .select({
        id: vaultUploadGrants.id,
        objectKey: vaultUploadGrants.objectKey,
        uploadObjectKey: vaultUploadGrants.uploadObjectKey,
      })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.userId, userId))
      .orderBy(asc(vaultUploadGrants.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE);
    if (grants.length === 0) break;
    options.beforeObjectDeletion?.();
    await Promise.all(grants.flatMap((grant) => [
      deleteObject(grant.objectKey),
      deleteObject(grant.uploadObjectKey),
    ]));
    await db.delete(vaultUploadGrants).where(inArray(vaultUploadGrants.id, grants.map((grant) => grant.id)));
    if (grants.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }

  for (;;) {
    const tombstones = await db
      .select({
        id: vaultUploadTombstones.id,
        objectKey: vaultUploadTombstones.objectKey,
        uploadObjectKey: vaultUploadTombstones.uploadObjectKey,
      })
      .from(vaultUploadTombstones)
      .where(eq(vaultUploadTombstones.userId, userId))
      .orderBy(asc(vaultUploadTombstones.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE);
    if (tombstones.length === 0) break;
    options.beforeObjectDeletion?.();
    await Promise.all(tombstones.flatMap((tombstone) => [
      deleteObject(tombstone.objectKey),
      deleteObject(tombstone.uploadObjectKey),
    ]));
    await db
      .delete(vaultUploadTombstones)
      .where(inArray(vaultUploadTombstones.id, tombstones.map((tombstone) => tombstone.id)));
    if (tombstones.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }

  for (;;) {
    const sessions = await db
      .select({ id: vaultSessions.id, latestObjectKey: vaultSessions.latestObjectKey })
      .from(vaultSessions)
      .where(eq(vaultSessions.userId, userId))
      .orderBy(asc(vaultSessions.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE);
    if (sessions.length === 0) break;
    options.beforeObjectDeletion?.();
    await Promise.all(sessions.map((session) => deleteObject(session.latestObjectKey)));
    await db.delete(vaultSessions).where(inArray(vaultSessions.id, sessions.map((session) => session.id)));
    if (sessions.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }
}

async function finishPostStackAccountCleanup(userId: string, accountTeamIds: readonly string[]): Promise<void> {
  await deleteVaultRowsAndObjectsForAccount(userId);
  await deleteCmuxOwnedAccountRows(userId, accountTeamIds);
}

async function resolveUserBillingForAccountDeletion(
  userId: string,
  accountTeamIds: readonly string[],
  retainedTeamBillingOwners: readonly RetainedTeamBillingOwner[],
  options: { readonly beforeExternalRequest?: () => void } = {},
): Promise<void> {
  const db = cloudDb();
  const deletionTeamIds = uniqueNonEmptyStrings([userId, ...accountTeamIds]);
  const retainedOwnerByTeam = new Map(
    retainedTeamBillingOwners.map((owner) => [owner.stackTeamId, owner.stackUserId] as const),
  );
  const subscriptionRows = await db
    .select({
      id: stripeSubscriptions.id,
      stackTeamId: stripeSubscriptions.stackTeamId,
      scope: stripeSubscriptions.scope,
      status: stripeSubscriptions.status,
    })
    .from(stripeSubscriptions)
    .where(eq(stripeSubscriptions.stackUserId, userId));
  const activeSubscriptions = subscriptionRows.filter((subscription) =>
    stripeSubscriptionBelongsToDeletingAccount(subscription, deletionTeamIds) &&
    stripeSubscriptionIsActive(subscription)
  );
  const retainedTeamSubscriptions = subscriptionRows.filter((subscription) =>
    stripeSubscriptionBelongsToRetainedTeam(subscription, deletionTeamIds)
  );
  const customerRows = await db
    .select({
      id: stripeCustomers.id,
      stackTeamId: stripeCustomers.stackTeamId,
    })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.stackUserId, userId));
  const customers = customerRows.filter((customer) =>
    !customer.stackTeamId || deletionTeamIds.includes(customer.stackTeamId)
  );
  const retainedTeamCustomers = customerRows.filter((customer) =>
    customer.stackTeamId && !deletionTeamIds.includes(customer.stackTeamId)
  );
  assertRetainedTeamBillingOwners({
    retainedOwnerByTeam,
    rows: [...retainedTeamCustomers, ...retainedTeamSubscriptions],
  });

  if (
    activeSubscriptions.length === 0 &&
    customers.length === 0 &&
    retainedTeamCustomers.length === 0 &&
    retainedTeamSubscriptions.length === 0
  ) return;
  if (!isStripeBillingConfigured()) {
    throw new Error("Stripe billing cleanup is not configured");
  }

  const client = stripe();
  for (const customer of retainedTeamCustomers) {
    const retainedOwnerId = retainedOwnerByTeam.get(customer.stackTeamId ?? "");
    if (!retainedOwnerId) throw new Error(`retained team billing owner missing for ${customer.stackTeamId}`);
    options.beforeExternalRequest?.();
    await client.customers.update(customer.id, {
      email: "",
      metadata: {
        stackUserId: retainedOwnerId,
        deletedAccountId: deletedStripeAccountId(userId),
      },
    });
    await db
      .update(stripeCustomers)
      .set({
        stackUserId: retainedOwnerId,
        email: null,
        updatedAt: sql`now()`,
      })
      .where(eq(stripeCustomers.id, customer.id));
  }
  for (const subscription of retainedTeamSubscriptions) {
    const retainedOwnerId = retainedOwnerByTeam.get(subscription.stackTeamId ?? "");
    if (!retainedOwnerId) throw new Error(`retained team billing owner missing for ${subscription.stackTeamId}`);
    options.beforeExternalRequest?.();
    await client.subscriptions.update(subscription.id, {
      metadata: {
        stackUserId: retainedOwnerId,
        deletedAccountId: deletedStripeAccountId(userId),
      },
    });
    await db
      .update(stripeSubscriptions)
      .set({
        stackUserId: retainedOwnerId,
        raw: null,
        updatedAt: sql`now()`,
      })
      .where(eq(stripeSubscriptions.id, subscription.id));
  }
  for (const subscription of activeSubscriptions) {
    options.beforeExternalRequest?.();
    await cancelStripeSubscriptionForAccountDeletion(client, subscription.id);
  }
  for (const customer of customers) {
    options.beforeExternalRequest?.();
    await deleteStripeCustomerForAccountDeletion(client, customer.id);
  }
}

function stripeSubscriptionBelongsToDeletingAccount(
  subscription: { readonly scope?: string | null; readonly stackTeamId?: string | null },
  deletionTeamIds: readonly string[],
): boolean {
  const scope = subscription.scope ?? "user";
  if (scope === "user" && !subscription.stackTeamId) return true;
  return scope === "team" &&
    typeof subscription.stackTeamId === "string" &&
    deletionTeamIds.includes(subscription.stackTeamId);
}

function stripeSubscriptionBelongsToRetainedTeam(
  subscription: { readonly scope?: string | null; readonly stackTeamId?: string | null },
  deletionTeamIds: readonly string[],
): boolean {
  return (subscription.scope ?? "user") === "team" &&
    typeof subscription.stackTeamId === "string" &&
    !deletionTeamIds.includes(subscription.stackTeamId);
}

function stripeSubscriptionIsActive(subscription: { readonly status?: string | null }): boolean {
  return !subscription.status ||
    (ACTIVE_STRIPE_PRO_STATUSES as readonly string[]).includes(subscription.status);
}

function assertRetainedTeamBillingOwners(input: {
  readonly retainedOwnerByTeam: ReadonlyMap<string, string>;
  readonly rows: readonly { readonly stackTeamId: string | null }[];
}): void {
  const missingTeamIds = uniqueNonEmptyStrings(input.rows.flatMap((row) => {
    const stackTeamId = row.stackTeamId;
    return stackTeamId && !input.retainedOwnerByTeam.has(stackTeamId) ? [stackTeamId] : [];
  }));
  if (missingTeamIds.length > 0) {
    throw new Error(`retained team billing owner missing for ${missingTeamIds.join(", ")}`);
  }
}

function deletedStripeAccountId(userId: string): string {
  return `deleted_${accountDeletionUserHash(userId).slice(0, 24)}`;
}

async function removeTestFlightAccessForAccountDeletion(
  user: DeletableStackUser,
  options: { readonly afterExternalMutation?: () => void } = {},
): Promise<void> {
  if (!isAscConfigured()) return;
  const email = user.primaryEmail?.trim();
  if (!email) return;
  try {
    await removeTester(email);
    options.afterExternalMutation?.();
  } catch (error) {
    captureAscError(error, {
      route: "/api/account",
      stackUserId: user.id,
      email,
    });
  }
}

async function markAccountDeletingAndClearBillingEntitlements(user: DeletableStackUser): Promise<void> {
  const metadata = stackMetadataRecord(user.clientReadOnlyMetadata);
  delete metadata.cmuxPlan;
  metadata.cmuxAccountDeleting = true;
  await user.update({ clientReadOnlyMetadata: metadata as ProMetadataJson });
}

async function restoreStackMetadataAfterAccountDeletionFailure(
  user: DeletableStackUser,
  metadata: unknown,
  options: { readonly restoreBillingEntitlements?: boolean } = {},
): Promise<void> {
  try {
    const restored = stackMetadataRecord(metadata);
    if (options.restoreBillingEntitlements === false) {
      delete restored.cmuxPlan;
    }
    await user.update({ clientReadOnlyMetadata: restored as ProMetadataJson });
  } catch (error) {
    logAccountDeleteError("account.delete.metadata_restore_failed", error);
  }
}

function stackMetadataRecord(metadata: unknown): Record<string, unknown> {
  return metadata && typeof metadata === "object" && !Array.isArray(metadata)
    ? { ...(metadata as Record<string, unknown>) }
    : {};
}

async function cancelStripeSubscriptionForAccountDeletion(
  client: ReturnType<typeof stripe>,
  subscriptionId: string,
): Promise<void> {
  try {
    await client.subscriptions.cancel(subscriptionId);
  } catch (error) {
    if (isStripeAlreadyInDeletionTargetState(error, [/already been canceled/i])) return;
    throw error;
  }
}

async function deleteStripeCustomerForAccountDeletion(
  client: ReturnType<typeof stripe>,
  customerId: string,
): Promise<void> {
  try {
    await client.customers.del(customerId);
  } catch (error) {
    if (isStripeAlreadyInDeletionTargetState(error, [/already deleted/i])) return;
    throw error;
  }
}

function isStripeAlreadyInDeletionTargetState(error: unknown, messagePatterns: readonly RegExp[]): boolean {
  const statusCode =
    error && typeof error === "object"
      ? (error as { statusCode?: unknown; raw?: { statusCode?: unknown } }).statusCode ??
        (error as { raw?: { statusCode?: unknown } }).raw?.statusCode
      : undefined;
  if (statusCode === 404) return true;

  const message =
    error && typeof error === "object" && typeof (error as { message?: unknown }).message === "string"
      ? (error as { message: string }).message
      : String(error);
  return messagePatterns.some((pattern) => pattern.test(message));
}

async function deleteCmuxOwnedAccountRows(userId: string, accountTeamIds: readonly string[]): Promise<void> {
  const db = cloudDb();
  await db.transaction(async (tx) => {
    const now = new Date();
    const deletionTeamIds = uniqueNonEmptyStrings([userId, ...accountTeamIds]);
    for (const teamId of deletionTeamIds) {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${teamId}, 0))`);
    }
    const userVmRows = await tx
      .select({
        id: cloudVms.id,
        billingTeamId: cloudVms.billingTeamId,
        providerVmId: cloudVms.providerVmId,
        status: cloudVms.status,
      })
      .from(cloudVms)
      .where(eq(cloudVms.userId, userId))
      .for("update");
    const personalVmRows = userVmRows.filter((vm) =>
      !vm.billingTeamId || deletionTeamIds.includes(vm.billingTeamId)
    );
    const sharedTeamVmRows = userVmRows.filter((vm) =>
      vm.billingTeamId && !deletionTeamIds.includes(vm.billingTeamId)
    );
    const unsafePersonalVmRows = personalVmRows.filter((vm) => {
      if (vm.status === "destroyed") return false;
      if (vm.status === "failed" && !vm.providerVmId) return false;
      return true;
    });
    if (unsafePersonalVmRows.length > 0) {
      throw new Error(
        `Personal cloud VM provider teardown or creation is still pending for ${unsafePersonalVmRows.length} row${unsafePersonalVmRows.length === 1 ? "" : "s"}`,
      );
    }

    await tx.delete(deviceTokens).where(eq(deviceTokens.userId, userId));
    await tx.delete(notificationSendEvents).where(eq(notificationSendEvents.userId, userId));

    await tx.delete(billingEmailClaims).where(or(
      eq(billingEmailClaims.stackUserId, userId),
      eq(billingEmailClaims.claimedByUserId, userId),
    ));
    await tx.delete(stripeSubscriptions).where(and(
      eq(stripeSubscriptions.stackUserId, userId),
      eq(stripeSubscriptions.scope, "user"),
      isNull(stripeSubscriptions.stackTeamId),
    ));
    await tx.delete(stripeCustomers).where(and(
      eq(stripeCustomers.stackUserId, userId),
      isNull(stripeCustomers.stackTeamId),
    ));
    await tx
      .update(stripeSubscriptions)
      .set({ stackUserId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
      .where(and(
        eq(stripeSubscriptions.stackUserId, userId),
        eq(stripeSubscriptions.scope, "team"),
        isNotNull(stripeSubscriptions.stackTeamId),
      ));
    await tx
      .update(stripeCustomers)
      .set({ stackUserId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
      .where(and(
        eq(stripeCustomers.stackUserId, userId),
        isNotNull(stripeCustomers.stackTeamId),
      ));

    await tx.delete(cloudVmBillingGrants).where(or(
      and(
        eq(cloudVmBillingGrants.billingCustomerType, "user"),
        eq(cloudVmBillingGrants.billingCustomerId, userId),
      ),
      and(
        eq(cloudVmBillingGrants.billingCustomerType, "team"),
        inArray(cloudVmBillingGrants.billingCustomerId, deletionTeamIds),
      ),
    ));
    await tx.delete(cloudVmNotificationDeliveries).where(eq(cloudVmNotificationDeliveries.userId, userId));
    await tx.delete(cloudVmNotificationEvents).where(eq(cloudVmNotificationEvents.userId, userId));
    await tx.delete(cloudVmUsageEvents).where(eq(cloudVmUsageEvents.userId, userId));
    await tx.delete(cloudVmLeases).where(eq(cloudVmLeases.userId, userId));
    await tx.delete(cloudVmSessions).where(eq(cloudVmSessions.userId, userId));
    if (personalVmRows.length > 0) {
      await tx.delete(cloudVms).where(inArray(cloudVms.id, personalVmRows.map((vm) => vm.id)));
    }
    if (sharedTeamVmRows.length > 0) {
      await tx
        .update(cloudVms)
        .set({ userId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
        .where(inArray(cloudVms.id, sharedTeamVmRows.map((vm) => vm.id)));
    }
    await tx.delete(cloudVmBaseEvents).where(eq(cloudVmBaseEvents.userId, userId));
    await tx.delete(cloudVmBases).where(or(
      and(
        eq(cloudVmBases.scopeType, "user"),
        eq(cloudVmBases.scopeId, userId),
      ),
      and(
        eq(cloudVmBases.scopeType, "team"),
        inArray(cloudVmBases.scopeId, deletionTeamIds),
      ),
    ));
    await tx
      .update(cloudVmBases)
      .set({ createdByUserId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
      .where(eq(cloudVmBases.createdByUserId, userId));
    await tx
      .update(cloudVmBases)
      .set({ lastOpenedByUserId: null, updatedAt: now })
      .where(eq(cloudVmBases.lastOpenedByUserId, userId));
    await tx
      .update(cloudVmBaseGenerations)
      .set({ createdByUserId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
      .where(eq(cloudVmBaseGenerations.createdByUserId, userId));

    await tx.delete(devices).where(and(
      inArray(devices.teamId, deletionTeamIds),
      eq(devices.userId, userId),
    ));
    await tx
      .update(devices)
      .set({ userId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
      .where(eq(devices.userId, userId));

    await tx.delete(vaultCliAuthRequests).where(eq(vaultCliAuthRequests.userId, userId));
  });
}

async function deletePersonalSubrouterTenant(
  userId: string,
  options: { readonly afterExternalMutation?: () => void } = {},
  accountTeamIds: readonly string[] = [userId],
): Promise<void> {
  const db = cloudDb();
  const teamIds = uniqueNonEmptyStrings([userId, ...accountTeamIds]);
  const tenants = await db
    .select({ tenantId: subrouterTenants.tenantId })
    .from(subrouterTenants)
    .where(inArray(subrouterTenants.teamId, teamIds));
  if (tenants.length === 0) return;

  const client = createSubrouterClientFromEnv();
  for (const tenant of tenants) {
    options.afterExternalMutation?.();
    try {
      await client.revokeTenant(tenant.tenantId);
    } catch (error) {
      if (!(error instanceof SubrouterClientError && error.status === 404)) throw error;
    }
  }
  await db.delete(subrouterTenants).where(inArray(subrouterTenants.teamId, teamIds));
}

async function accountDeletionScopeForUser(user: DeletableStackUser): Promise<{
  readonly teamIds: readonly string[];
  readonly retainedTeamBillingOwners: readonly RetainedTeamBillingOwner[];
}> {
  if (typeof user.listTeams !== "function") {
    throw new Error("Stack team listing is required for account deletion");
  }
  const listedTeams = await user.listTeams();
  const teams = uniqueStackTeams([
    stackTeamFromUnknown(user.selectedTeam),
    ...listedTeams.map(stackTeamFromUnknown),
  ]);
  const personalTeamIds: string[] = [];
  const retainedTeamBillingOwners: RetainedTeamBillingOwner[] = [];
  for (const team of teams) {
    const memberIds = await stackTeamMemberIds(team);
    if (!memberIds) {
      throw new Error(`Stack team membership is required for account deletion: ${team.id}`);
    }
    if (memberIds.length === 1 && memberIds[0] === user.id) {
      personalTeamIds.push(team.id);
      continue;
    }
    if (!memberIds.includes(user.id)) continue;
    const retainedOwnerId = memberIds.find((memberId) => memberId !== user.id);
    if (retainedOwnerId) {
      retainedTeamBillingOwners.push({
        stackTeamId: team.id,
        stackUserId: retainedOwnerId,
      });
    }
  }
  return {
    teamIds: uniqueNonEmptyStrings([user.id, ...personalTeamIds]),
    retainedTeamBillingOwners,
  };
}

function stackTeamFromUnknown(value: unknown): AccountDeletionStackTeam | null {
  if (!value || typeof value !== "object") return null;
  const id = (value as { readonly id?: unknown }).id;
  if (typeof id !== "string" || !id.trim()) return null;
  const listUsers = (value as { readonly listUsers?: unknown }).listUsers;
  return {
    id: id.trim(),
    listUsers: typeof listUsers === "function"
      ? async () => await listUsers.call(value)
      : undefined,
  };
}

async function stackTeamMemberIds(team: AccountDeletionStackTeam): Promise<readonly string[] | null> {
  if (typeof team.listUsers !== "function") return null;
  const members = await team.listUsers();
  return uniqueNonEmptyStrings(members.flatMap((member) => {
    if (!member || typeof member !== "object") return [];
    const id = (member as { readonly id?: unknown }).id;
    return typeof id === "string" ? [id] : [];
  }));
}

function uniqueStackTeams(values: readonly (AccountDeletionStackTeam | null)[]): readonly AccountDeletionStackTeam[] {
  const teams: AccountDeletionStackTeam[] = [];
  const seen = new Set<string>();
  for (const team of values) {
    if (!team || seen.has(team.id)) continue;
    seen.add(team.id);
    teams.push(team);
  }
  return teams;
}

function uniqueNonEmptyStrings(values: readonly (string | null | undefined)[]): readonly string[] {
  return [...new Set(values.map((value) => value?.trim()).filter((value): value is string => !!value))];
}

const SENSITIVE_ERROR_TEXT =
  /(Bearer\s+\S+|eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|srt_[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{8,})/g;

function logAccountDeleteError(label: string, error: unknown): void {
  console.error(label, sanitizedErrorSummary(error));
}

function sanitizedErrorSummary(error: unknown): string {
  const name =
    error && typeof error === "object" && typeof (error as { name?: unknown }).name === "string"
      ? (error as { name: string }).name
      : typeof error;
  const message =
    error && typeof error === "object" && typeof (error as { message?: unknown }).message === "string"
      ? (error as { message: string }).message
      : String(error);
  return `${name}: ${message.replace(SENSITIVE_ERROR_TEXT, "[redacted]")}`;
}
