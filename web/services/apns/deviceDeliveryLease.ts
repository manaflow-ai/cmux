import crypto from "node:crypto";
import { and, eq, gt, inArray, isNull } from "drizzle-orm";

import type { cloudDb } from "../../db/client";
import { deviceTokens } from "../../db/schema";
import { assertAccountDeletionUserMutationAllowed } from "../account/deletionLock";
import type { ApnsTarget } from "./sender";
import { MAX_DEVICE_TOKENS_PER_USER } from "./routePolicy";

type PushDatabase = ReturnType<typeof cloudDb>;

export const DEVICE_DELIVERY_LEASE_MS = 60_000;

export class DeviceDeliveryBusyError extends Error {
  readonly retryAfterSeconds: number;

  constructor(retryAfterSeconds: number) {
    super("device push delivery is already in progress");
    this.name = "DeviceDeliveryBusyError";
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

export interface DeviceDeliveryClaim {
  readonly leaseToken: string | null;
  readonly targets: readonly ApnsTarget[];
}

/**
 * Freezes the current account-owned recipient set while APNs I/O is in flight.
 * Registration and deletion lock the same rows before changing ownership, so
 * the server has a linear handoff point and cannot send an old account's event
 * after a new account's registration commits.
 */
export async function claimDeviceDeliveryTargets(
  db: PushDatabase,
  userId: string,
  targetBundleId: string | null,
  now = new Date(),
): Promise<DeviceDeliveryClaim> {
  // A null bundle is the legacy namespace: pre-rollout Macs cannot name a
  // target lane, so they keep their historical account-wide reach and each
  // token row supplies its own bundle topic to the sender.
  const tokenScope = (bundleId: string | null) => and(
    eq(deviceTokens.userId, userId),
    eq(deviceTokens.platform, "ios"),
    isNull(deviceTokens.revokedAt),
    ...(bundleId == null ? [] : [eq(deviceTokens.bundleId, bundleId)]),
  );
  return db.transaction(async (tx) => {
    // This uses the same account advisory lock as deletion startup. Once the
    // tombstone wins that linearization point, no later push can renew a device
    // delivery lease and starve deletion.
    await assertAccountDeletionUserMutationAllowed(tx, userId);
    const rows = await tx
      .select({
        targetId: deviceTokens.id,
        deviceToken: deviceTokens.deviceToken,
        bundleId: deviceTokens.bundleId,
        environment: deviceTokens.environment,
        installationId: deviceTokens.installationId,
        pushKeyId: deviceTokens.pushKeyId,
        deliveryLeaseUntil: deviceTokens.deliveryLeaseUntil,
      })
      .from(deviceTokens)
      .where(tokenScope(targetBundleId))
      .limit(MAX_DEVICE_TOKENS_PER_USER)
      .for("update");

    const blockedUntilMs = rows.reduce(
      (maximum, row) => Math.max(
        maximum,
        row.deliveryLeaseUntil?.getTime() ?? 0,
      ),
      0,
    );
    if (blockedUntilMs > now.getTime()) {
      throw new DeviceDeliveryBusyError(
        Math.max(1, Math.ceil((blockedUntilMs - now.getTime()) / 1_000)),
      );
    }
    if (rows.length === 0) {
      return { leaseToken: null, targets: [] };
    }

    const leaseToken = crypto.randomUUID();
    await tx
      .update(deviceTokens)
      .set({
        deliveryLeaseUntil: new Date(
          now.getTime() + DEVICE_DELIVERY_LEASE_MS,
        ),
        deliveryLeaseToken: leaseToken,
        deliveryStartedAt: null,
      })
      .where(and(
        tokenScope(targetBundleId),
        inArray(deviceTokens.id, rows.map((row) => row.targetId)),
      ));

    return {
      leaseToken,
      targets: rows.map((row) => ({
        targetId: row.targetId,
        deviceToken: row.deviceToken,
        bundleId: row.bundleId,
        environment: row.environment,
        installationId: row.installationId,
        pushKeyId: row.pushKeyId,
      })),
    };
  });
}

/**
 * Rechecks the revocation marker after the durable send lease is recorded.
 * Sign-out may revoke a row while APNs setup is still pending; revoked rows
 * must be removed from the provider call even though the original claim is
 * still in memory.
 */
export async function retainAuthorizedDeviceDeliveryTargets(
  db: PushDatabase,
  userId: string,
  leaseToken: string | null,
  targets: readonly ApnsTarget[],
  now = new Date(),
): Promise<ApnsTarget[]> {
  if (!leaseToken || targets.length === 0) {
    return [];
  }
  return db.transaction(async (tx) => {
    const rows = await tx
      .select({
        targetId: deviceTokens.id,
        deviceToken: deviceTokens.deviceToken,
        bundleId: deviceTokens.bundleId,
        environment: deviceTokens.environment,
        installationId: deviceTokens.installationId,
        pushKeyId: deviceTokens.pushKeyId,
      })
      .from(deviceTokens)
      .where(and(
        eq(deviceTokens.userId, userId),
        eq(deviceTokens.platform, "ios"),
        eq(deviceTokens.deliveryLeaseToken, leaseToken),
        isNull(deviceTokens.revokedAt),
        gt(deviceTokens.deliveryLeaseUntil, now),
        inArray(deviceTokens.id, targets.flatMap((target) =>
          target.targetId == null ? [] : [target.targetId]
        )),
      ))
      .for("update");
    const authorizedIDs = new Set(rows.map((row) => row.targetId));
    const authorizedTargets = targets.filter((target) =>
      target.targetId != null && authorizedIDs.has(target.targetId)
    );
    if (authorizedTargets.length > 0) {
      await tx
        .update(deviceTokens)
        .set({ deliveryStartedAt: now })
        .where(and(
          eq(deviceTokens.deliveryLeaseToken, leaseToken),
          isNull(deviceTokens.revokedAt),
          inArray(deviceTokens.id, authorizedTargets.flatMap((target) =>
            target.targetId == null ? [] : [target.targetId]
          )),
        ));
    }
    return authorizedTargets;
  });
}

export async function waitForDeviceDeliveryTarget(
  db: PushDatabase,
  targetId: string,
): Promise<void> {
  const deadline = Date.now() + DEVICE_DELIVERY_LEASE_MS + 5_000;
  let delayMs = 25;
  while (Date.now() < deadline) {
    const [row] = await db
      .select({
        deliveryStartedAt: deviceTokens.deliveryStartedAt,
        deliveryLeaseUntil: deviceTokens.deliveryLeaseUntil,
      })
      .from(deviceTokens)
      .where(eq(deviceTokens.id, targetId))
      .limit(1);
    if (!row || row.deliveryStartedAt == null) return;
    if (
      row.deliveryLeaseUntil == null
      || row.deliveryLeaseUntil.getTime() <= Date.now()
    ) return;
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    delayMs = Math.min(1_000, delayMs * 2);
  }
}

export async function releaseDeviceDeliveryTargets(
  db: PushDatabase,
  leaseToken: string | null,
  targetIds: readonly string[],
): Promise<void> {
  if (!leaseToken || targetIds.length === 0) return;
  await db
    .update(deviceTokens)
    .set({
      deliveryLeaseUntil: null,
      deliveryLeaseToken: null,
      deliveryStartedAt: null,
    })
    .where(and(
      eq(deviceTokens.deliveryLeaseToken, leaseToken),
      inArray(deviceTokens.id, targetIds),
    ));
}
