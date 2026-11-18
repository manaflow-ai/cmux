// The Billing nightly's delivery read (app/api/cron/apple-notifications/health):
// did an App Store TEST notification with this UUID reach the ledger? Only
// TEST rows answer, and only with timestamps and the environment, so the read
// can never confirm or describe a customer's notification.

import { and, eq } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import { appleNotifications } from "../../../db/schema";

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
