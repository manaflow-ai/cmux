import { and, count, eq, gte, lt, min, sql } from "drizzle-orm";

import type { cloudDb } from "../../db/client";
import { notificationSendEvents } from "../../db/schema";
import type { PushSendSummary } from "./response";
import type { ApnsSendResult, ApnsTarget } from "./sender";
import { APNS_DEFAULT_MAX_DELIVERY_DURATION_MS } from "./sender";

type NotificationDb = ReturnType<typeof cloudDb>;

const PUSH_RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000;
// The notification path can legitimately coalesce up to 200 agent events in a
// busy ten-minute window. This per-user transaction is the only in-code limiter;
// an infrastructure IP rule would conflate users behind NAT and drift from this
// contract.
const PUSH_RATE_LIMIT_MAX_EVENTS = 200;
// One owner keeps the logical event until the slowest bounded default APNs
// attempt plus database/network scheduling margin. A second request must not
// replay an alert while the first request is still legitimately in flight.
export const PUSH_SEND_LEASE_MS = 60_000;

export class PushRateLimitExceededError extends Error {
  readonly retryAfterSeconds: number;

  constructor(retryAfterSeconds: number) {
    super("push rate limit exceeded");
    this.name = "PushRateLimitExceededError";
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

export class PushCorrelationConflictError extends Error {
  constructor() {
    super("push correlation payload mismatch");
    this.name = "PushCorrelationConflictError";
  }
}

export async function recordPushSendOrThrow(
  db: NotificationDb,
  userId: string,
  deviceCount: number,
  correlationId: string,
  now = new Date(),
  expiresAt = new Date(now.getTime() + 5 * 60 * 1000),
  eventKind: "notify" | "dismiss" = "notify",
  initialTargets: readonly ApnsTarget[] = [],
  payloadFingerprint: string | null = null,
): Promise<PushSendClaim> {
  const windowStart = new Date(now.getTime() - PUSH_RATE_LIMIT_WINDOW_MS);

  return db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${userId}, 1))`);
    await tx
      .delete(notificationSendEvents)
      .where(and(eq(notificationSendEvents.userId, userId), lt(notificationSendEvents.createdAt, windowStart)));

    const [existing] = await tx
      .select({
        id: notificationSendEvents.id,
        payloadFingerprint: notificationSendEvents.payloadFingerprint,
        summary: notificationSendEvents.resultSummary,
        outcomes: notificationSendEvents.resultOutcomes,
        expiresAt: notificationSendEvents.expiresAt,
        leaseUntil: notificationSendEvents.leaseUntil,
        eventKind: notificationSendEvents.eventKind,
        initialTargets: notificationSendEvents.initialTargets,
      })
      .from(notificationSendEvents)
      .where(
        and(
          eq(notificationSendEvents.userId, userId),
          eq(notificationSendEvents.correlationId, correlationId),
        ),
      )
      .limit(1);
    if (existing) {
      if (existing.payloadFingerprint !== payloadFingerprint) {
        throw new PushCorrelationConflictError();
      }
      const record: PushSendRecord = {
        summary: existing.summary ?? null,
        outcomes: existing.outcomes ?? [],
        expiresAt: existing.expiresAt,
        eventKind:
          existing.eventKind === "dismiss" ? "dismiss" : "notify",
        initialTargets: existing.initialTargets ?? [],
      };
      if (
        existing.leaseUntil != null
        && existing.leaseUntil.getTime() > now.getTime()
      ) {
        return { kind: "busy", record } as const;
      }
      await tx
        .update(notificationSendEvents)
        .set({
          leaseUntil: new Date(now.getTime() + PUSH_SEND_LEASE_MS),
        })
        .where(eq(notificationSendEvents.id, existing.id));
      return { kind: "claimed", previous: record } as const;
    }

    const [recent] = await tx
      .select({
        total: count(),
        oldestCreatedAt: min(notificationSendEvents.createdAt),
      })
      .from(notificationSendEvents)
      .where(and(
        eq(notificationSendEvents.userId, userId),
        eq(notificationSendEvents.eventKind, eventKind),
        gte(notificationSendEvents.createdAt, windowStart),
      ));

    const recentCount = Number(recent?.total ?? 0);
    if (recentCount >= PUSH_RATE_LIMIT_MAX_EVENTS) {
      const oldestCreatedAt = recent?.oldestCreatedAt;
      const retryAfterMilliseconds =
        oldestCreatedAt instanceof Date
          ? oldestCreatedAt.getTime() + PUSH_RATE_LIMIT_WINDOW_MS - now.getTime()
          : PUSH_RATE_LIMIT_WINDOW_MS;
      throw new PushRateLimitExceededError(
        Math.max(1, Math.ceil(retryAfterMilliseconds / 1000)),
      );
    }

    await tx.insert(notificationSendEvents).values({
      userId,
      deviceCount,
      correlationId,
      payloadFingerprint,
      eventKind,
      initialTargets: [...initialTargets],
      expiresAt,
      leaseUntil: new Date(now.getTime() + PUSH_SEND_LEASE_MS),
      createdAt: now,
    });
    return { kind: "claimed", previous: null } as const;
  });
}

export interface PushSendRecord {
  readonly summary: PushSendSummary | null;
  readonly outcomes: readonly ApnsSendResult[];
  readonly expiresAt: Date | null;
  readonly eventKind: "notify" | "dismiss";
  readonly initialTargets: readonly ApnsTarget[];
}

export type PushSendClaim =
  | {
      readonly kind: "claimed";
      readonly previous: PushSendRecord | null;
    }
  | {
      readonly kind: "busy";
      readonly record: PushSendRecord;
    };

export async function pushSendRecord(
  db: NotificationDb,
  userId: string,
  correlationId: string,
): Promise<PushSendRecord | null> {
  const [existing] = await db
    .select({
      summary: notificationSendEvents.resultSummary,
      outcomes: notificationSendEvents.resultOutcomes,
      expiresAt: notificationSendEvents.expiresAt,
      eventKind: notificationSendEvents.eventKind,
      initialTargets: notificationSendEvents.initialTargets,
    })
    .from(notificationSendEvents)
    .where(
      and(
        eq(notificationSendEvents.userId, userId),
        eq(notificationSendEvents.correlationId, correlationId),
      ),
    )
    .limit(1);
  if (!existing) return null;
  return {
    summary: existing.summary ?? null,
    outcomes: existing.outcomes ?? [],
    expiresAt: existing.expiresAt,
    eventKind: existing.eventKind === "dismiss" ? "dismiss" : "notify",
    initialTargets: existing.initialTargets ?? [],
  };
}

export async function completePushSend(
  db: NotificationDb,
  userId: string,
  correlationId: string,
  summary: PushSendSummary,
  outcomes: readonly ApnsSendResult[],
): Promise<void> {
  await db
    .update(notificationSendEvents)
    .set({
      resultSummary: summary,
      resultOutcomes: [...outcomes],
      leaseUntil: null,
    })
    .where(
      and(
        eq(notificationSendEvents.userId, userId),
        eq(notificationSendEvents.correlationId, correlationId),
      ),
    );
}
