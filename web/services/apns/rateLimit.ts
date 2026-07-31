import { and, count, eq, gte, lt, sql } from "drizzle-orm";

import type { cloudDb } from "../../db/client";
import { notificationSendEvents } from "../../db/schema";

type NotificationDb = ReturnType<typeof cloudDb>;

const PUSH_RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000;
// Per-user cap (keyed on user.id), so this only bounds a user's own phone — it is
// a runaway-loop / APNs-volume guard, not anti-abuse (a user cannot spam others).
// Power users running many agents legitimately exceed 60/10min, so allow 200/10min.
const PUSH_RATE_LIMIT_MAX_EVENTS = 200;

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
  const windowStart = new Date(now.getTime() - PUSH_RATE_LIMIT_WINDOW_MS);

  await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${userId}, 1))`);
    await tx
      .delete(notificationSendEvents)
      .where(and(eq(notificationSendEvents.userId, userId), lt(notificationSendEvents.createdAt, windowStart)));

    const [recent] = await tx
      .select({ total: count() })
      .from(notificationSendEvents)
      .where(and(eq(notificationSendEvents.userId, userId), gte(notificationSendEvents.createdAt, windowStart)));

    const recentCount = Number(recent?.total ?? 0);
    if (recentCount >= PUSH_RATE_LIMIT_MAX_EVENTS) {
      throw new PushRateLimitExceededError(Math.ceil(PUSH_RATE_LIMIT_WINDOW_MS / 1000));
    }

    await tx.insert(notificationSendEvents).values({ userId, deviceCount, createdAt: now });
  });
}
