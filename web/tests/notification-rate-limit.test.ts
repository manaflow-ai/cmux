import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import {
  PUSH_SEND_LEASE_MS,
  completePushSend,
  recordPushSendOrThrow,
  PushRateLimitExceededError,
} from "../services/apns/rateLimit";
import { APNS_DEFAULT_MAX_DELIVERY_DURATION_MS } from "../services/apns/sender";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const DB_STRESS_TEST_TIMEOUT_MS = 30_000;

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  sql = postgres(databaseURL, { max: 1 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("notification rate limit", () => {
  dbTest("limits forwarded pushes per user in a sliding window", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate notification_send_events restart identity cascade`;

    const { cloudDb } = await import("../db/client");
    const db = cloudDb();
    const now = new Date("2026-06-02T12:00:00Z");

    for (let i = 0; i < 200; i += 1) {
      await recordPushSendOrThrow(db, "push-user-1", 1, `event-${i}`, now);
    }
    await recordPushSendOrThrow(db, "push-user-2", 1, "event-other-user", now);

    await expect(recordPushSendOrThrow(db, "push-user-1", 1, "event-over-limit", now)).rejects.toBeInstanceOf(
      PushRateLimitExceededError,
    );
    const nearWindowEnd = new Date(now.getTime() + 10 * 60 * 1000 - 250);
    try {
      await recordPushSendOrThrow(
        db,
        "push-user-1",
        1,
        "event-over-limit-near-window-end",
        nearWindowEnd,
      );
      throw new Error("expected the rate limit to reject");
    } catch (error) {
      expect(error).toBeInstanceOf(PushRateLimitExceededError);
      expect((error as PushRateLimitExceededError).retryAfterSeconds).toBe(1);
    }

    await recordPushSendOrThrow(
      db,
      "push-user-1",
      1,
      "event-after-window",
      new Date(now.getTime() + 10 * 60 * 1000 + 1),
    );
  }, DB_STRESS_TEST_TIMEOUT_MS);

  dbTest("counts repeated transport attempts for one correlation id as one logical event", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate notification_send_events restart identity cascade`;

    const { cloudDb } = await import("../db/client");
    const db = cloudDb();
    const now = new Date("2026-06-02T12:00:00Z");
    const correlationId = "4d02de48-a21d-4ba1-97b5-42e9400ee09b";

    await recordPushSendOrThrow(db, "push-user-1", 2, correlationId, now);
    await recordPushSendOrThrow(db, "push-user-1", 2, correlationId, now);

    const [stored] = await sql<{ total: number }[]>`
      select count(*)::int as total
      from notification_send_events
      where user_id = 'push-user-1'
    `;
    expect(stored?.total).toBe(1);
  });

  dbTest("does not take over a live claim during the slowest default APNs send", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate notification_send_events restart identity cascade`;

    const { cloudDb } = await import("../db/client");
    const db = cloudDb();
    const startedAt = new Date("2026-06-02T12:00:00Z");
    const correlationId = "slow-active-send";

    expect(PUSH_SEND_LEASE_MS).toBeGreaterThan(APNS_DEFAULT_MAX_DELIVERY_DURATION_MS);
    await expect(
      recordPushSendOrThrow(db, "push-user-1", 1, correlationId, startedAt),
    ).resolves.toMatchObject({ kind: "claimed" });
    await expect(
      recordPushSendOrThrow(
        db,
        "push-user-1",
        1,
        correlationId,
        new Date(startedAt.getTime() + APNS_DEFAULT_MAX_DELIVERY_DURATION_MS),
      ),
    ).resolves.toMatchObject({ kind: "busy" });
  });

  dbTest("does not take over a live claim when its event expires mid-send", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate notification_send_events restart identity cascade`;

    const { cloudDb } = await import("../db/client");
    const db = cloudDb();
    const startedAt = new Date("2026-06-02T12:00:00Z");
    const correlationId = "expired-while-active";
    await recordPushSendOrThrow(
      db,
      "push-user-1",
      1,
      correlationId,
      startedAt,
      new Date(startedAt.getTime() + 1_000),
    );

    await expect(recordPushSendOrThrow(
      db,
      "push-user-1",
      1,
      correlationId,
      new Date(startedAt.getTime() + 1_001),
    )).resolves.toMatchObject({
      kind: "busy",
      retryAfterSeconds: 59,
    });
  });

  dbTest("a stale worker cannot overwrite a reclaimed lease", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate notification_send_events restart identity cascade`;

    const { cloudDb } = await import("../db/client");
    const db = cloudDb();
    const startedAt = new Date("2026-06-02T12:00:00Z");
    const first = await recordPushSendOrThrow(
      db,
      "push-user-1",
      1,
      "lease-fencing",
      startedAt,
    );
    expect(first.kind).toBe("claimed");
    if (first.kind !== "claimed") throw new Error("expected first claim");

    const second = await recordPushSendOrThrow(
      db,
      "push-user-1",
      1,
      "lease-fencing",
      new Date(startedAt.getTime() + PUSH_SEND_LEASE_MS + 1),
    );
    expect(second.kind).toBe("claimed");
    if (second.kind !== "claimed") throw new Error("expected reclaimed lease");

    const success = {
      sent: 1,
      devices: 1,
      pruned: 0,
      transientFailures: 0,
      permanentFailures: 0,
    };
    const transient = {
      sent: 0,
      devices: 1,
      pruned: 0,
      transientFailures: 1,
      permanentFailures: 0,
    };
    await completePushSend(
      db,
      "push-user-1",
      "lease-fencing",
      second.leaseToken,
      success,
      [],
    );
    await completePushSend(
      db,
      "push-user-1",
      "lease-fencing",
      first.leaseToken,
      transient,
      [],
    );

    const [stored] = await sql<{ sent: number; transient: number }[]>`
      select
        (result_summary ->> 'sent')::int as sent,
        (result_summary ->> 'transientFailures')::int as transient
      from notification_send_events
      where user_id = 'push-user-1' and correlation_id = 'lease-fencing'
    `;
    expect(stored).toEqual({ sent: 1, transient: 0 });
  });

  dbTest("persists provider backoff across same-correlation retries", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate notification_send_events restart identity cascade`;

    const { cloudDb } = await import("../db/client");
    const db = cloudDb();
    const startedAt = new Date("2026-06-02T12:00:00Z");
    const correlationId = "provider-backoff";
    const target = {
      targetId: "00000000-0000-4000-8000-000000000001",
      deviceToken: "a".repeat(64),
      bundleId: "com.cmux.app",
      environment: "production",
    };
    const first = await recordPushSendOrThrow(
      db,
      "push-user-1",
      1,
      correlationId,
      startedAt,
      new Date(startedAt.getTime() + 30 * 60 * 1_000),
      "notify",
      [target],
    );
    expect(first.kind).toBe("claimed");
    if (first.kind !== "claimed") throw new Error("expected first claim");

    await completePushSend(
      db,
      "push-user-1",
      correlationId,
      first.leaseToken,
      {
        sent: 0,
        devices: 1,
        pruned: 0,
        transientFailures: 1,
        permanentFailures: 0,
        retryAfterSeconds: 900,
      },
      [{
        ...target,
        status: 503,
        reason: "ServiceUnavailable",
        retryAfterSeconds: 900,
        prune: false,
      }],
      startedAt,
    );

    const deferred = await recordPushSendOrThrow(
      db,
      "push-user-1",
      1,
      correlationId,
      new Date(startedAt.getTime() + 60_000),
      new Date(startedAt.getTime() + 30 * 60 * 1_000),
      "notify",
      [target],
    );
    expect(deferred).toMatchObject({
      kind: "busy",
      retryAfterSeconds: 840,
    });

    const resumed = await recordPushSendOrThrow(
      db,
      "push-user-1",
      1,
      correlationId,
      new Date(startedAt.getTime() + 900_001),
      new Date(startedAt.getTime() + 30 * 60 * 1_000),
      "notify",
      [target],
    );
    expect(resumed).toMatchObject({ kind: "claimed" });
  });

  dbTest("keeps dismiss reconciliation available after the visible-alert budget", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate notification_send_events restart identity cascade`;

    const { cloudDb } = await import("../db/client");
    const db = cloudDb();
    const now = new Date("2026-06-02T12:00:00Z");
    for (let index = 0; index < 200; index += 1) {
      await recordPushSendOrThrow(
        db,
        "push-user-1",
        1,
        `notify-${index}`,
        now,
        new Date(now.getTime() + 120_000),
        "notify",
      );
    }

    await expect(recordPushSendOrThrow(
      db,
      "push-user-1",
      1,
      "dismiss-after-clear-all",
      now,
      new Date(now.getTime() + 120_000),
      "dismiss",
    )).resolves.toMatchObject({ kind: "claimed" });
  }, DB_STRESS_TEST_TIMEOUT_MS);
});
