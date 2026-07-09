import { and, asc, eq, inArray, isNotNull, isNull, or } from "drizzle-orm";

import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { cloudDb } from "../../../db/client";
import {
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
import { isStripeBillingConfigured, stripe } from "../../../services/billing/stripe";
import {
  createSubrouterClientFromEnv,
  SubrouterClientError,
} from "../../../services/subrouter/client";
import { deleteObject } from "../../../services/vault/storage";
import { unauthorized } from "../../../services/vms/auth";
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
  readonly delete: () => Promise<void>;
} & ProMetadataCustomer;

export async function DELETE(request: Request): Promise<Response> {
  const stackUser = await currentDeletableStackUser(request);
  if (!stackUser) return unauthorized();

  const userId = stackUser.id;
  const originalStackMetadata = stackUser.clientReadOnlyMetadata;
  let stackMetadataMarked = false;
  let cmuxOwnedRowsDeleted = false;
  let destructiveCleanupStarted = false;
  let destroyedVms = 0;
  let restoreBillingEntitlementsOnFailure = true;
  try {
    await markAccountDeletingAndClearBillingEntitlements(stackUser);
    stackMetadataMarked = true;
    await resolveUserBillingForAccountDeletion(userId, {
      beforeExternalMutation: () => {
        restoreBillingEntitlementsOnFailure = false;
        destructiveCleanupStarted = true;
      },
    });
    try {
      destroyedVms = await destroyPersonalCloudVms(userId);
      if (destroyedVms > 0) destructiveCleanupStarted = true;
    } catch (error) {
      if (error instanceof AccountDeletionDestructiveCleanupError) {
        destroyedVms = error.destroyedVms;
        destructiveCleanupStarted = error.destructiveCleanupStarted;
      }
      throw error;
    }
    destructiveCleanupStarted = true;
    await deleteVaultRowsAndObjectsForAccount(userId);
    destructiveCleanupStarted = true;
    await deletePersonalSubrouterTenant(userId);
    destructiveCleanupStarted = true;
    await runVmWorkflow(revokeUserIdentityLeasesForAccountDeletion(userId));
    // Delete cmux-owned data before the Stack user so a Stack-side failure does
    // not strand retained app data behind an account the user can no longer use.
    // These deletes are idempotent, so the same signed-in user can retry the
    // final Stack deletion when the distinct response below is returned.
    await deleteCmuxOwnedAccountRows(userId);
    cmuxOwnedRowsDeleted = true;
    try {
      await stackUser.delete();
    } catch (error) {
      logAccountDeleteError("account.delete.stack_user_failed_after_data_delete", error);
      return jsonResponse({
        error: "account_delete_retryable",
        retryable: true,
        destroyedVms,
      }, 500);
    }
    try {
      await finishPostStackAccountCleanup(userId);
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

async function destroyPersonalCloudVms(userId: string): Promise<number> {
  const vms = await runVmWorkflow(listUserVms(userId));
  const failures: unknown[] = [];
  let destroyedVms = 0;
  let destructiveCleanupStarted = false;
  for (const vm of vms) {
    try {
      const destroyProgram = destroyVm({ userId, providerVmId: vm.providerVmId });
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

async function deleteVaultRowsAndObjectsForAccount(userId: string): Promise<void> {
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
    await Promise.all(sessions.map((session) => deleteObject(session.latestObjectKey)));
    await db.delete(vaultSessions).where(inArray(vaultSessions.id, sessions.map((session) => session.id)));
    if (sessions.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }
}

async function finishPostStackAccountCleanup(userId: string): Promise<void> {
  await deleteVaultRowsAndObjectsForAccount(userId);
  await deleteCmuxOwnedAccountRows(userId);
}

async function resolveUserBillingForAccountDeletion(
  userId: string,
  options: { readonly beforeExternalMutation?: () => void } = {},
): Promise<void> {
  const db = cloudDb();
  const activeSubscriptions = await db
    .select({ id: stripeSubscriptions.id })
    .from(stripeSubscriptions)
    .where(and(
      eq(stripeSubscriptions.stackUserId, userId),
      eq(stripeSubscriptions.scope, "user"),
      isNull(stripeSubscriptions.stackTeamId),
      inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
    ));
  const customers = await db
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(and(
      eq(stripeCustomers.stackUserId, userId),
      isNull(stripeCustomers.stackTeamId),
    ));

  if (activeSubscriptions.length === 0 && customers.length === 0) return;
  if (!isStripeBillingConfigured()) {
    throw new Error("Stripe billing cleanup is not configured");
  }

  const client = stripe();
  let externalMutationMarked = false;
  const markExternalMutation = () => {
    if (externalMutationMarked) return;
    externalMutationMarked = true;
    options.beforeExternalMutation?.();
  };
  for (const subscription of activeSubscriptions) {
    markExternalMutation();
    await cancelStripeSubscriptionForAccountDeletion(client, subscription.id);
  }
  for (const customer of customers) {
    markExternalMutation();
    await deleteStripeCustomerForAccountDeletion(client, customer.id);
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

async function deleteCmuxOwnedAccountRows(userId: string): Promise<void> {
  const db = cloudDb();
  await db.transaction(async (tx) => {
    const now = new Date();
    const personalVmRows = await tx
      .select({
        id: cloudVms.id,
        providerVmId: cloudVms.providerVmId,
        status: cloudVms.status,
      })
      .from(cloudVms)
      .where(personalVmScope(userId))
      .for("update");
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

    await tx.delete(cloudVmBillingGrants).where(and(
      eq(cloudVmBillingGrants.billingCustomerType, "user"),
      eq(cloudVmBillingGrants.billingCustomerId, userId),
    ));
    await tx.delete(cloudVmNotificationDeliveries).where(eq(cloudVmNotificationDeliveries.userId, userId));
    await tx.delete(cloudVmNotificationEvents).where(eq(cloudVmNotificationEvents.userId, userId));
    await tx.delete(cloudVmUsageEvents).where(eq(cloudVmUsageEvents.userId, userId));
    await tx.delete(cloudVmLeases).where(eq(cloudVmLeases.userId, userId));
    await tx.delete(cloudVmSessions).where(eq(cloudVmSessions.userId, userId));
    if (personalVmRows.length > 0) {
      await tx.delete(cloudVms).where(inArray(cloudVms.id, personalVmRows.map((vm) => vm.id)));
    }
    await tx.delete(cloudVmBaseEvents).where(eq(cloudVmBaseEvents.userId, userId));
    await tx.delete(cloudVmBases).where(and(
      eq(cloudVmBases.scopeType, "user"),
      eq(cloudVmBases.scopeId, userId),
    ));
    await tx
      .update(cloudVms)
      .set({ userId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
      .where(eq(cloudVms.userId, userId));
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

    await tx.delete(devices).where(eq(devices.teamId, userId));
    await tx
      .update(devices)
      .set({ userId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
      .where(eq(devices.userId, userId));

    await tx.delete(vaultCliAuthRequests).where(eq(vaultCliAuthRequests.userId, userId));
  });
}

async function deletePersonalSubrouterTenant(userId: string): Promise<void> {
  const db = cloudDb();
  const [tenant] = await db
    .select({ tenantId: subrouterTenants.tenantId })
    .from(subrouterTenants)
    .where(eq(subrouterTenants.teamId, userId))
    .limit(1);
  if (!tenant) return;

  try {
    await createSubrouterClientFromEnv().revokeTenant(tenant.tenantId);
  } catch (error) {
    if (!(error instanceof SubrouterClientError && error.status === 404)) throw error;
  }
  await db.delete(subrouterTenants).where(eq(subrouterTenants.teamId, userId));
}

function personalVmScope(userId: string) {
  return and(
    eq(cloudVms.userId, userId),
    or(isNull(cloudVms.billingTeamId), eq(cloudVms.billingTeamId, userId)),
  );
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
