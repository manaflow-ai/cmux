import crypto from "node:crypto";
import { and, eq, inArray } from "drizzle-orm";

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
      })),
    };
  });
}

export async function releaseDeviceDeliveryTargets(
  db: PushDatabase,
  leaseToken: string | null,
  targetIds: readonly string[],
): Promise<void> {
  if (!leaseToken || targetIds.length === 0) return;
  await db
    .update(deviceTokens)
    .set({ deliveryLeaseUntil: null, deliveryLeaseToken: null })
    .where(and(
      eq(deviceTokens.deliveryLeaseToken, leaseToken),
      inArray(deviceTokens.id, targetIds),
    ));
}
