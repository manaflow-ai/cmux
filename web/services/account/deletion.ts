import { createHash } from "node:crypto";
import { and, eq, inArray, isNotNull, isNull, ne, or } from "drizzle-orm";
import { cloudDb } from "../../db/client";
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
import { deleteObject } from "../vault/storage";

const ACCOUNT_DELETION_METADATA_KEY = "cmuxAccountDeletionInProgress";
const MAX_ACCOUNT_VM_CLEANUP_PASSES = 3;

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
  readonly teamIds: readonly string[];
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

export async function markStackUserDeletionInProgress(
  user: StackAccountDeletionMetadataUser,
): Promise<void> {
  if (isStackAccountDeletionInProgress(user.clientReadOnlyMetadata)) return;
  const metadata = stackJsonObject(user.clientReadOnlyMetadata);
  metadata[ACCOUNT_DELETION_METADATA_KEY] = true;
  await user.update({ clientReadOnlyMetadata: metadata });
}

export async function deleteCmuxAccountData(input: AccountDeletionInput): Promise<void> {
  const anonymizedUserId = deletedAccountId(input.userId);
  await claimProviderlessAccountVms(input.userId);
  await destroyProviderBackedAccountVms(input.userId);

  const objectKeys = await accountVaultObjectKeys(input.userId);
  for (const key of objectKeys) {
    await deleteObject(key);
  }

  await cancelStripeAccountBilling(input.userId, anonymizedUserId);

  const anonymizedEmail = `${anonymizedUserId}@deleted.cmux.invalid`;
  const now = new Date();
  const db = cloudDb();

  await db.transaction(async (tx) => {
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
      eq(cloudVmUsageEvents.userId, input.userId),
      eq(cloudVmUsageEvents.billingTeamId, input.userId),
    ));
    await tx.delete(cloudVmBaseEvents).where(eq(cloudVmBaseEvents.userId, input.userId));
    await tx.delete(cloudVmBillingGrants).where(and(
      eq(cloudVmBillingGrants.billingCustomerType, "user"),
      eq(cloudVmBillingGrants.billingCustomerId, input.userId),
    ));
    await tx.delete(cloudVmBases).where(and(
      eq(cloudVmBases.scopeType, "user"),
      eq(cloudVmBases.scopeId, input.userId),
    ));
    await tx.delete(cloudVms).where(eq(cloudVms.userId, input.userId));

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

async function claimProviderlessAccountVms(userId: string): Promise<void> {
  const db = cloudDb();
  await db
    .update(cloudVms)
    .set({
      status: "destroyed",
      destroyedAt: new Date(),
      updatedAt: new Date(),
    })
    .where(and(
      eq(cloudVms.userId, userId),
      ne(cloudVms.status, "destroyed"),
      isNull(cloudVms.providerVmId),
    ));
}

async function destroyProviderBackedAccountVms(userId: string): Promise<void> {
  for (let pass = 0; pass < MAX_ACCOUNT_VM_CLEANUP_PASSES; pass += 1) {
    const activeVms = await providerBackedAccountVms(userId);
    if (activeVms.length === 0) return;
    for (const vm of activeVms) {
      if (!vm.providerVmId) continue;
      await runVmWorkflow(destroyAccountOwnedVm({
        userId,
        providerVmId: vm.providerVmId,
      }));
    }
  }

  const remaining = await providerBackedAccountVms(userId);
  if (remaining.length > 0) {
    throw new Error("Cloud VM account deletion cleanup did not settle");
  }
}

async function providerBackedAccountVms(userId: string): Promise<readonly { readonly providerVmId: string | null }[]> {
  const db = cloudDb();
  return await db
    .select({ providerVmId: cloudVms.providerVmId })
    .from(cloudVms)
    .where(and(
      eq(cloudVms.userId, userId),
      ne(cloudVms.status, "destroyed"),
      isNotNull(cloudVms.providerVmId),
    ));
}

async function accountVaultObjectKeys(userId: string): Promise<readonly string[]> {
  const db = cloudDb();
  const keys = new Set<string>();
  const snapshotRows = await db
    .select({ objectKey: vaultSnapshots.objectKey })
    .from(vaultSnapshots)
    .innerJoin(vaultSessions, eq(vaultSnapshots.sessionId, vaultSessions.id))
    .where(eq(vaultSessions.userId, userId));
  const grantRows = await db
    .select({
      objectKey: vaultUploadGrants.objectKey,
      uploadObjectKey: vaultUploadGrants.uploadObjectKey,
    })
    .from(vaultUploadGrants)
    .where(eq(vaultUploadGrants.userId, userId));
  const tombstoneRows = await db
    .select({
      objectKey: vaultUploadTombstones.objectKey,
      uploadObjectKey: vaultUploadTombstones.uploadObjectKey,
    })
    .from(vaultUploadTombstones)
    .where(eq(vaultUploadTombstones.userId, userId));

  for (const row of snapshotRows) keys.add(row.objectKey);
  for (const row of [...grantRows, ...tombstoneRows]) {
    keys.add(row.objectKey);
    keys.add(row.uploadObjectKey);
  }
  return [...keys];
}

async function cancelStripeAccountBilling(userId: string, anonymizedUserId: string): Promise<void> {
  const db = cloudDb();
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
    await stripeClient.customers.update(customer.id, {
      email: "",
      metadata: { stackUserId: "", deletedAccountId: anonymizedUserId },
    });
  }
  for (const subscription of subscriptionRows) {
    await stripeClient.subscriptions.update(subscription.id, {
      metadata: { stackUserId: "", deletedAccountId: anonymizedUserId },
    });
    await stripeClient.subscriptions.cancel(subscription.id);
  }
}

function deletedAccountId(userId: string): string {
  return `deleted_${createHash("sha256").update(userId).digest("hex").slice(0, 24)}`;
}

function stackJsonObject(value: unknown): StackJsonObject {
  return value && typeof value === "object" && !Array.isArray(value)
    ? { ...(value as StackJsonObject) }
    : {};
}
