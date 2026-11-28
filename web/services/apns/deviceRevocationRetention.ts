import { and, inArray, lte } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { deviceTokenRevocations } from "../../db/schema";

const DEVICE_REVOCATION_RETENTION_BATCH = 500;

export async function pruneExpiredDeviceTokenRevocations(
  db = cloudDb(),
  now = new Date(),
): Promise<number> {
  const expired = await db
    .select({ id: deviceTokenRevocations.id })
    .from(deviceTokenRevocations)
    .where(lte(deviceTokenRevocations.expiresAt, now))
    .limit(DEVICE_REVOCATION_RETENTION_BATCH);
  if (expired.length === 0) return 0;
  const deleted = await db
    .delete(deviceTokenRevocations)
    .where(and(
      inArray(deviceTokenRevocations.id, expired.map((row) => row.id)),
      lte(deviceTokenRevocations.expiresAt, now),
    ))
    .returning({ id: deviceTokenRevocations.id });
  return deleted.length;
}
