import { and, asc, eq, inArray, isNull, or } from "drizzle-orm";

import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { cloudDb } from "../../../db/client";
import {
  billingEmailClaims,
  cloudVmBaseEvents,
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
} from "../../../db/schema";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  type ProMetadataJson,
  type ProMetadataCustomer,
} from "../../../services/billing/pro";
import { isStripeBillingConfigured, stripe } from "../../../services/billing/stripe";
import { deleteObject } from "../../../services/vault/storage";
import { unauthorized, verifyRequest } from "../../../services/vms/auth";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import { destroyVm, listUserVms, runVmWorkflow } from "../../../services/vms/workflows";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const VAULT_OBJECT_DELETE_BATCH_SIZE = 100;

type DeletableStackUser = {
  readonly id: string;
  readonly delete: () => Promise<void>;
} & ProMetadataCustomer;

export async function DELETE(request: Request): Promise<Response> {
  const user = await verifyRequest(request, { allowCookie: false, allowDeletingAccount: true });
  if (!user) return unauthorized();

  const stackUser = await currentDeletableStackUser(request);
  if (!stackUser || stackUser.id !== user.id) return unauthorized();

  try {
    await resolveUserBillingForAccountDeletion(user.id);
    await markAccountDeletingAndClearBillingEntitlements(stackUser);
    const destroyedVms = await destroyPersonalCloudVms(user.id);
    await deleteVaultObjectsForAccount(user.id);
    // Delete cmux-owned data before the Stack user so a Stack-side failure does
    // not strand retained app data behind an account the user can no longer use.
    // These deletes are idempotent, so the same signed-in user can retry the
    // final Stack deletion when the distinct response below is returned.
    await deleteCollectedVaultObjects(await deleteCmuxOwnedAccountRows(user.id));
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
    await finishPostStackAccountCleanup(user.id);
    return jsonResponse({ ok: true, destroyedVms });
  } catch (error) {
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

async function destroyPersonalCloudVms(userId: string): Promise<number> {
  const vms = await runVmWorkflow(listUserVms(userId));
  for (const vm of vms) {
    await runVmWorkflow(destroyVm({ userId, providerVmId: vm.providerVmId }));
  }
  return vms.length;
}

async function deleteVaultObjectsForAccount(userId: string): Promise<void> {
  const db = cloudDb();

  for (let offset = 0; ; offset += VAULT_OBJECT_DELETE_BATCH_SIZE) {
    const sessions = await db
      .select({ latestObjectKey: vaultSessions.latestObjectKey })
      .from(vaultSessions)
      .where(eq(vaultSessions.userId, userId))
      .orderBy(asc(vaultSessions.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE)
      .offset(offset);
    if (sessions.length === 0) break;
    for (const session of sessions) await deleteObject(session.latestObjectKey);
    if (sessions.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }

  for (let offset = 0; ; offset += VAULT_OBJECT_DELETE_BATCH_SIZE) {
    const snapshots = await db
      .select({ objectKey: vaultSnapshots.objectKey })
      .from(vaultSnapshots)
      .innerJoin(vaultSessions, eq(vaultSnapshots.sessionId, vaultSessions.id))
      .where(eq(vaultSessions.userId, userId))
      .orderBy(asc(vaultSnapshots.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE)
      .offset(offset);
    if (snapshots.length === 0) break;
    for (const snapshot of snapshots) await deleteObject(snapshot.objectKey);
    if (snapshots.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }

  for (let offset = 0; ; offset += VAULT_OBJECT_DELETE_BATCH_SIZE) {
    const grants = await db
      .select({
        objectKey: vaultUploadGrants.objectKey,
        uploadObjectKey: vaultUploadGrants.uploadObjectKey,
      })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.userId, userId))
      .orderBy(asc(vaultUploadGrants.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE)
      .offset(offset);
    if (grants.length === 0) break;
    for (const grant of grants) {
      await deleteObject(grant.objectKey);
      await deleteObject(grant.uploadObjectKey);
    }
    if (grants.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }

  for (let offset = 0; ; offset += VAULT_OBJECT_DELETE_BATCH_SIZE) {
    const tombstones = await db
      .select({
        objectKey: vaultUploadTombstones.objectKey,
        uploadObjectKey: vaultUploadTombstones.uploadObjectKey,
      })
      .from(vaultUploadTombstones)
      .where(eq(vaultUploadTombstones.userId, userId))
      .orderBy(asc(vaultUploadTombstones.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE)
      .offset(offset);
    if (tombstones.length === 0) break;
    for (const tombstone of tombstones) {
      await deleteObject(tombstone.objectKey);
      await deleteObject(tombstone.uploadObjectKey);
    }
    if (tombstones.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }
}

async function deleteCollectedVaultObjects(rows: DeletedAccountRows): Promise<void> {
  for (const objectKey of rows.vaultObjectKeys) {
    await deleteObject(objectKey);
  }
}

async function finishPostStackAccountCleanup(userId: string): Promise<void> {
  try {
    await deleteVaultObjectsForAccount(userId);
    await deleteCollectedVaultObjects(await deleteCmuxOwnedAccountRows(userId));
  } catch (error) {
    logAccountDeleteError("account.delete.post_stack_cleanup_failed", error);
  }
}

async function resolveUserBillingForAccountDeletion(userId: string): Promise<void> {
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
  for (const subscription of activeSubscriptions) {
    await cancelStripeSubscriptionForAccountDeletion(client, subscription.id);
  }
  for (const customer of customers) {
    await deleteStripeCustomerForAccountDeletion(client, customer.id);
  }
}

async function markAccountDeletingAndClearBillingEntitlements(user: DeletableStackUser): Promise<void> {
  const raw = user.clientReadOnlyMetadata;
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {};
  delete metadata.cmuxPlan;
  metadata.cmuxAccountDeleting = true;
  await user.update({ clientReadOnlyMetadata: metadata as ProMetadataJson });
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

type DeletedAccountRows = {
  readonly vaultObjectKeys: readonly string[];
};

async function deleteCmuxOwnedAccountRows(userId: string): Promise<DeletedAccountRows> {
  const db = cloudDb();
  const vaultObjectKeys = new Set<string>();
  await db.transaction(async (tx) => {
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

    await tx.delete(cloudVmBillingGrants).where(and(
      eq(cloudVmBillingGrants.billingCustomerType, "user"),
      eq(cloudVmBillingGrants.billingCustomerId, userId),
    ));
    await tx.delete(cloudVmNotificationDeliveries).where(eq(cloudVmNotificationDeliveries.userId, userId));
    await tx.delete(cloudVmNotificationEvents).where(eq(cloudVmNotificationEvents.userId, userId));
    await tx.delete(cloudVmUsageEvents).where(personalUsageScope(userId));
    await tx.delete(cloudVmLeases).where(eq(cloudVmLeases.userId, userId));
    await tx.delete(cloudVmSessions).where(eq(cloudVmSessions.userId, userId));
    await tx.delete(cloudVms).where(personalVmScope(userId));
    await tx.delete(cloudVmBaseEvents).where(eq(cloudVmBaseEvents.userId, userId));
    await tx.delete(cloudVmBases).where(and(
      eq(cloudVmBases.scopeType, "user"),
      eq(cloudVmBases.scopeId, userId),
    ));

    await tx.delete(devices).where(eq(devices.userId, userId));

    const deletedGrants = await tx
      .delete(vaultUploadGrants)
      .where(eq(vaultUploadGrants.userId, userId))
      .returning({
        objectKey: vaultUploadGrants.objectKey,
        uploadObjectKey: vaultUploadGrants.uploadObjectKey,
      });
    for (const grant of deletedGrants) {
      vaultObjectKeys.add(grant.objectKey);
      vaultObjectKeys.add(grant.uploadObjectKey);
    }

    const deletedTombstones = await tx
      .delete(vaultUploadTombstones)
      .where(eq(vaultUploadTombstones.userId, userId))
      .returning({
        objectKey: vaultUploadTombstones.objectKey,
        uploadObjectKey: vaultUploadTombstones.uploadObjectKey,
      });
    for (const tombstone of deletedTombstones) {
      vaultObjectKeys.add(tombstone.objectKey);
      vaultObjectKeys.add(tombstone.uploadObjectKey);
    }

    await tx.delete(vaultCliAuthRequests).where(eq(vaultCliAuthRequests.userId, userId));

    const sessions = await tx
      .select({ id: vaultSessions.id })
      .from(vaultSessions)
      .where(eq(vaultSessions.userId, userId));
    const sessionIds = sessions.map((session) => session.id);
    if (sessionIds.length > 0) {
      const deletedSnapshots = await tx
        .delete(vaultSnapshots)
        .where(inArray(vaultSnapshots.sessionId, sessionIds))
        .returning({ objectKey: vaultSnapshots.objectKey });
      for (const snapshot of deletedSnapshots) vaultObjectKeys.add(snapshot.objectKey);
    }

    const deletedSessions = await tx
      .delete(vaultSessions)
      .where(eq(vaultSessions.userId, userId))
      .returning({ latestObjectKey: vaultSessions.latestObjectKey });
    for (const session of deletedSessions) vaultObjectKeys.add(session.latestObjectKey);
  });
  return { vaultObjectKeys: [...vaultObjectKeys] };
}

function personalVmScope(userId: string) {
  return and(
    eq(cloudVms.userId, userId),
    or(isNull(cloudVms.billingTeamId), eq(cloudVms.billingTeamId, userId)),
  );
}

function personalUsageScope(userId: string) {
  return and(
    eq(cloudVmUsageEvents.userId, userId),
    or(isNull(cloudVmUsageEvents.billingTeamId), eq(cloudVmUsageEvents.billingTeamId, userId)),
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
