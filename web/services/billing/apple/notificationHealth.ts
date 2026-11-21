// The Billing nightly's delivery read (app/api/cron/apple-notifications/health):
// did an App Store TEST notification with this UUID reach the ledger? Only
// TEST rows answer, and only with timestamps and the environment, so the read
// can never confirm or describe a customer's notification.

import { and, eq } from "drizzle-orm";

import { createHash } from "node:crypto";

import { cloudDb } from "../../../db/client";
import { appleNotificationHistoryCursors, appleNotifications } from "../../../db/schema";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Apple's `notificationUUID` shape; the only input the read accepts. */
export function isAppleNotificationUuid(value: unknown): value is string {
  return typeof value === "string" && UUID.test(value);
}

export type AppleTestNotificationReceipt = {
  readonly receivedAt: Date;
  readonly processedAt: Date | null;
  readonly environment: string;
};

/** The ledger receipt of one TEST notification, or null when none has that UUID. */
export async function findAppleTestNotification(
  notificationUuid: string,
  db: ReturnType<typeof cloudDb> = cloudDb(),
): Promise<AppleTestNotificationReceipt | null> {
  const [row] = await db
    .select({
      receivedAt: appleNotifications.receivedAt,
      processedAt: appleNotifications.processedAt,
      environment: appleNotifications.environment,
    })
    .from(appleNotifications)
    .where(and(
      eq(appleNotifications.notificationUuid, notificationUuid),
      eq(appleNotifications.notificationType, "TEST"),
    ))
    .limit(1);
  return row ?? null;
}

export type AppleHistoryCursorRow = {
  readonly nextStartAt: Date;
  readonly windowStartAt: Date | null;
  readonly windowEndAt: Date | null;
  readonly paginationToken: string | null;
  readonly retryableRuns: number;
  readonly updatedAt: Date;
};

/** The backfill cursor of one history, or null before its first save. */
export async function findAppleHistoryCursor(
  bundleId: string,
  environment: string,
  db: ReturnType<typeof cloudDb> = cloudDb(),
): Promise<AppleHistoryCursorRow | null> {
  const [row] = await db
    .select({
      nextStartAt: appleNotificationHistoryCursors.nextStartAt,
      windowStartAt: appleNotificationHistoryCursors.windowStartAt,
      windowEndAt: appleNotificationHistoryCursors.windowEndAt,
      paginationToken: appleNotificationHistoryCursors.paginationToken,
      retryableRuns: appleNotificationHistoryCursors.retryableRuns,
      updatedAt: appleNotificationHistoryCursors.updatedAt,
    })
    .from(appleNotificationHistoryCursors)
    .where(and(
      eq(appleNotificationHistoryCursors.bundleId, bundleId),
      eq(appleNotificationHistoryCursors.environment, environment),
    ))
    .limit(1);
  return row ?? null;
}

/**
 * What the post-release check may see of a cursor: timestamps, counts, and an
 * opaque `position` that changes whenever the backfill moves (a new window or
 * a new page). Apple's pagination token itself never leaves the server.
 */
export function describeAppleHistoryCursor(row: AppleHistoryCursorRow | null) {
  if (!row) {
    return {
      found: false, position: null, nextStartAt: null, windowStartAt: null, windowEndAt: null,
      pagePending: false, retryableRuns: 0, updatedAt: null,
    };
  }
  const iso = (value: Date | null) => value?.toISOString() ?? null;
  const position = createHash("sha256")
    .update([iso(row.nextStartAt), iso(row.windowStartAt), iso(row.windowEndAt), row.paginationToken ?? ""].join("|"))
    .digest("hex")
    .slice(0, 16);
  return {
    found: true,
    position,
    nextStartAt: iso(row.nextStartAt),
    windowStartAt: iso(row.windowStartAt),
    windowEndAt: iso(row.windowEndAt),
    pagePending: row.paginationToken !== null,
    retryableRuns: row.retryableRuns,
    updatedAt: iso(row.updatedAt),
  };
}
