import { and, eq, inArray, isNull, or } from "drizzle-orm";

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
  syncProPlanMetadata,
  type ProMetadataCustomer,
} from "../../../services/billing/pro";
import { isStripeBillingConfigured, stripe } from "../../../services/billing/stripe";
import { deleteObject } from "../../../services/vault/storage";
import { unauthorized, verifyRequest } from "../../../services/vms/auth";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import { destroyVm, listUserVms, runVmWorkflow } from "../../../services/vms/workflows";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type DeletableStackUser = {
  readonly id: string;
  readonly delete: () => Promise<void>;
} & ProMetadataCustomer;

export async function DELETE(request: Request): Promise<Response> {
  const user = await verifyRequest(request, { allowCookie: false });
  if (!user) return unauthorized();

  const stackUser = await currentDeletableStackUser(request);
  if (!stackUser || stackUser.id !== user.id) return unauthorized();

  try {
    const destroyedVms = await destroyPersonalCloudVms(user.id);
    await deleteVaultObjectsForAccount(user.id);
    await resolveUserBillingForAccountDeletion(user.id);
    await clearUserBillingEntitlementsForAccountDeletion(stackUser);
    // Delete cmux-owned data before the Stack user so a Stack-side failure does
    // not strand retained app data behind an account the user can no longer use.
    // These deletes are idempotent, so the same signed-in user can retry the
    // final Stack deletion when the distinct response below is returned.
    await deleteCmuxOwnedAccountRows(user.id);
    try {
      await stackUser.delete();
    } catch (error) {
      logAccountDeleteError("account.delete.stack_user_failed_after_data_delete", error);
      return jsonResponse({
        error: "account_stack_delete_failed_after_data_delete",
        retryable: true,
        destroyedVms,
      }, 500);
    }
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
  const objectKeys = new Set<string>();

  const sessions = await db
    .select({ latestObjectKey: vaultSessions.latestObjectKey })
    .from(vaultSessions)
    .where(eq(vaultSessions.userId, userId));
  for (const session of sessions) objectKeys.add(session.latestObjectKey);

  const snapshots = await db
    .select({ objectKey: vaultSnapshots.objectKey })
    .from(vaultSnapshots)
    .innerJoin(vaultSessions, eq(vaultSnapshots.sessionId, vaultSessions.id))
    .where(eq(vaultSessions.userId, userId));
  for (const snapshot of snapshots) objectKeys.add(snapshot.objectKey);

  const grants = await db
    .select({
      objectKey: vaultUploadGrants.objectKey,
      uploadObjectKey: vaultUploadGrants.uploadObjectKey,
    })
    .from(vaultUploadGrants)
    .where(eq(vaultUploadGrants.userId, userId));
  for (const grant of grants) {
    objectKeys.add(grant.objectKey);
    objectKeys.add(grant.uploadObjectKey);
  }

  const tombstones = await db
    .select({
      objectKey: vaultUploadTombstones.objectKey,
      uploadObjectKey: vaultUploadTombstones.uploadObjectKey,
    })
    .from(vaultUploadTombstones)
    .where(eq(vaultUploadTombstones.userId, userId));
  for (const tombstone of tombstones) {
    objectKeys.add(tombstone.objectKey);
    objectKeys.add(tombstone.uploadObjectKey);
  }

  for (const objectKey of objectKeys) {
    await deleteObject(objectKey);
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
    await client.subscriptions.cancel(subscription.id);
  }
  for (const customer of customers) {
    await client.customers.del(customer.id);
  }
}

async function clearUserBillingEntitlementsForAccountDeletion(user: DeletableStackUser): Promise<void> {
  await syncProPlanMetadata(user, false);
}

async function deleteCmuxOwnedAccountRows(userId: string): Promise<void> {
  const db = cloudDb();
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

    await tx.delete(vaultUploadGrants).where(eq(vaultUploadGrants.userId, userId));
    await tx.delete(vaultUploadTombstones).where(eq(vaultUploadTombstones.userId, userId));
    await tx.delete(vaultCliAuthRequests).where(eq(vaultCliAuthRequests.userId, userId));
    await tx.delete(vaultSessions).where(eq(vaultSessions.userId, userId));
  });
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
