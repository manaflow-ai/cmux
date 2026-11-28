import crypto from "node:crypto";
import { and, count, eq, gte, lt, min, sql } from "drizzle-orm";

import type { cloudDb } from "../../db/client";
import { notificationSendEvents } from "../../db/schema";
import type { PushSendSummary } from "./response";
import type { ApnsSendResult, ApnsTarget } from "./sender";

type NotificationDb = ReturnType<typeof cloudDb>;

interface PersistedApnsTarget {
  readonly targetId: string;
  readonly bundleId: string;
  readonly environment: string;
}

interface PersistedApnsSendResult {
  readonly targetId: string;
  readonly status: number;
  readonly reason?: string;
  readonly retryAfterSeconds?: number;
  readonly prune: boolean;
}

const PUSH_RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000;
// The notification path permits up to 200 visible events and 200 invisible
// dismiss reconciliations per user in a busy ten-minute window. Keeping the
// budgets separate prevents an alert burst from blocking banner removal. This
// per-user transaction is the only in-code limiter; an infrastructure IP rule
// would conflate users behind NAT and drift from this contract.
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

export class PushTargetIdentityError extends Error {
  constructor() {
    super("push target is missing durable identity");
    this.name = "PushTargetIdentityError";
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
        retryNotBefore: notificationSendEvents.retryNotBefore,
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
      const record = decodePushSendRecord({
        summary: existing.summary ?? null,
        outcomes: existing.outcomes,
        expiresAt: existing.expiresAt,
        retryNotBefore: existing.retryNotBefore,
        eventKind:
          existing.eventKind === "dismiss" ? "dismiss" : "notify",
        initialTargets: existing.initialTargets,
      });
      const recordExpired =
        record.expiresAt != null && record.expiresAt.getTime() <= now.getTime();
      const blockedUntilMs = Math.max(
        existing.leaseUntil?.getTime() ?? 0,
        recordExpired ? 0 : existing.retryNotBefore?.getTime() ?? 0,
      );
      if (blockedUntilMs > now.getTime()) {
        return {
          kind: "busy",
          record,
          retryAfterSeconds: Math.max(
            1,
            Math.ceil((blockedUntilMs - now.getTime()) / 1_000),
          ),
        } as const;
      }
      const leaseToken = crypto.randomUUID();
      await tx
        .update(notificationSendEvents)
        .set({
          leaseUntil: new Date(now.getTime() + PUSH_SEND_LEASE_MS),
          leaseToken,
          retryNotBefore: null,
        })
        .where(eq(notificationSendEvents.id, existing.id));
      return { kind: "claimed", previous: record, leaseToken } as const;
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

    const leaseToken = crypto.randomUUID();
    await tx.insert(notificationSendEvents).values({
      userId,
      deviceCount,
      correlationId,
      payloadFingerprint,
      eventKind,
      initialTargets: encodeTargets(initialTargets),
      expiresAt,
      leaseUntil: new Date(now.getTime() + PUSH_SEND_LEASE_MS),
      leaseToken,
      createdAt: now,
    });
    return { kind: "claimed", previous: null, leaseToken } as const;
  });
}

export interface PushSendRecord {
  readonly summary: PushSendSummary | null;
  readonly outcomes: readonly ApnsSendResult[];
  readonly expiresAt: Date | null;
  readonly retryNotBefore: Date | null;
  readonly eventKind: "notify" | "dismiss";
  /** `null` is a legacy row; `[]` is a deliberately frozen empty audience. */
  readonly initialTargets: readonly ApnsTarget[] | null;
}

export type PushSendClaim =
  | {
      readonly kind: "claimed";
      readonly previous: PushSendRecord | null;
      readonly leaseToken: string;
    }
  | {
      readonly kind: "busy";
      readonly record: PushSendRecord;
      readonly retryAfterSeconds: number;
    };

export async function completePushSend(
  db: NotificationDb,
  userId: string,
  correlationId: string,
  leaseToken: string,
  summary: PushSendSummary,
  outcomes: readonly ApnsSendResult[],
  completedAt = new Date(),
  expiresAt: Date | null = null,
): Promise<boolean> {
  const requestedRetryNotBefore =
    summary.transientFailures > 0
      && summary.retryAfterSeconds != null
      && summary.retryAfterSeconds > 0
      ? new Date(
          completedAt.getTime()
            + Math.ceil(summary.retryAfterSeconds) * 1_000,
        )
      : null;
  const retryNotBefore =
    requestedRetryNotBefore != null
      && (expiresAt == null || requestedRetryNotBefore.getTime() < expiresAt.getTime())
      ? requestedRetryNotBefore
      : null;
  const updated = await db
    .update(notificationSendEvents)
    .set({
      resultSummary: summary,
      resultOutcomes: encodeOutcomes(outcomes),
      leaseUntil: null,
      leaseToken: null,
      retryNotBefore,
    })
    .where(
      and(
        eq(notificationSendEvents.userId, userId),
        eq(notificationSendEvents.correlationId, correlationId),
        eq(notificationSendEvents.leaseToken, leaseToken),
      ),
    )
    .returning({ id: notificationSendEvents.id });
  return updated.length === 1;
}

export async function releasePushSendLease(
  db: NotificationDb,
  userId: string,
  correlationId: string,
  leaseToken: string,
): Promise<boolean> {
  const updated = await db
    .update(notificationSendEvents)
    .set({ leaseUntil: null, leaseToken: null })
    .where(and(
      eq(notificationSendEvents.userId, userId),
      eq(notificationSendEvents.correlationId, correlationId),
      eq(notificationSendEvents.leaseToken, leaseToken),
    ))
    .returning({ id: notificationSendEvents.id });
  return updated.length === 1;
}

function encodeTargets(
  targets: readonly ApnsTarget[],
): PersistedApnsTarget[] {
  return targets.map((target) => {
    if (!target.targetId) throw new PushTargetIdentityError();
    return {
      targetId: target.targetId,
      bundleId: target.bundleId,
      environment: target.environment,
    };
  });
}

function encodeOutcomes(
  outcomes: readonly ApnsSendResult[],
): PersistedApnsSendResult[] {
  return outcomes.map((outcome) => {
    if (!outcome.targetId) throw new PushTargetIdentityError();
    return {
      targetId: outcome.targetId,
      status: outcome.status,
      ...(outcome.reason == null ? {} : { reason: outcome.reason }),
      ...(outcome.retryAfterSeconds == null
        ? {}
        : { retryAfterSeconds: outcome.retryAfterSeconds }),
      prune: outcome.prune,
    };
  });
}

function decodePushSendRecord(input: {
  readonly summary: PushSendSummary | null;
  readonly outcomes: readonly PersistedApnsSendResult[] | null;
  readonly expiresAt: Date | null;
  readonly retryNotBefore: Date | null;
  readonly eventKind: "notify" | "dismiss";
  readonly initialTargets: readonly PersistedApnsTarget[] | null;
}): PushSendRecord {
  return {
    summary: input.summary,
    outcomes: (input.outcomes ?? []).flatMap((outcome) =>
      typeof outcome.targetId === "string" && outcome.targetId.length > 0
        ? [{ ...outcome, deviceToken: outcome.targetId }]
        : []
    ),
    expiresAt: input.expiresAt,
    retryNotBefore: input.retryNotBefore,
    eventKind: input.eventKind,
    initialTargets: input.initialTargets == null
      ? null
      : input.initialTargets.flatMap((target) =>
          typeof target.targetId === "string" && target.targetId.length > 0
            ? [{ ...target, deviceToken: target.targetId }]
            : []
        ),
  };
}
