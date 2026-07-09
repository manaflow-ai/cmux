import { and, count, eq, gte, lt, sql } from "drizzle-orm";

import type { cloudDb } from "../../db/client";
import { notificationSendEvents } from "../../db/schema";
import { withAccountDeletionUserMutationLock } from "../account/deletion";

type NotificationDb = ReturnType<typeof cloudDb>;
type NotificationWriteDb = Pick<NotificationDb, "delete" | "execute" | "insert" | "select">;

const PUSH_RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000;
const PUSH_RATE_LIMIT_MAX_EVENTS = 60;

export class PushRateLimitExceededError extends Error {
  readonly retryAfterSeconds: number;

  constructor(retryAfterSeconds: number) {
    super("push rate limit exceeded");
    this.name = "PushRateLimitExceededError";
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

export async function recordPushSendOrThrow(
  db: NotificationDb,
  userId: string,
  deviceCount: number,
  now = new Date(),
): Promise<void> {
  await withAccountDeletionUserMutationLock(db, userId, async (tx) => {
    await recordPushSendInTransactionOrThrow(tx, userId, deviceCount, now);
  });
}

export async function recordPushSendInTransactionOrThrow(
  db: NotificationWriteDb,
  userId: string,
  deviceCount: number,
  now = new Date(),
): Promise<void> {
  const windowStart = new Date(now.getTime() - PUSH_RATE_LIMIT_WINDOW_MS);
  await db.execute(sql`select pg_advisory_xact_lock(hashtextextended(${userId}, 1))`);
  await db
    .delete(notificationSendEvents)
    .where(and(eq(notificationSendEvents.userId, userId), lt(notificationSendEvents.createdAt, windowStart)));

  const [recent] = await db
    .select({ total: count() })
    .from(notificationSendEvents)
    .where(and(eq(notificationSendEvents.userId, userId), gte(notificationSendEvents.createdAt, windowStart)));

  const recentCount = Number(recent?.total ?? 0);
  if (recentCount >= PUSH_RATE_LIMIT_MAX_EVENTS) {
    throw new PushRateLimitExceededError(Math.ceil(PUSH_RATE_LIMIT_WINDOW_MS / 1000));
  }

  await db.insert(notificationSendEvents).values({ userId, deviceCount, createdAt: now });
}
