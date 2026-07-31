import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import {
  PUSH_SEND_LEASE_MS,
  recordPushSendOrThrow,
  PushRateLimitExceededError,
} from "../services/apns/rateLimit";
import { APNS_DEFAULT_MAX_DELIVERY_DURATION_MS } from "../services/apns/sender";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

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

    await recordPushSendOrThrow(
      db,
      "push-user-1",
      1,
      "event-after-window",
      new Date(now.getTime() + 10 * 60 * 1000 + 1),
    );
  });

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
  });
});
