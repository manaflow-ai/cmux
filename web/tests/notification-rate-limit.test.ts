import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { recordPushSendOrThrow, PushRateLimitExceededError } from "../services/apns/rateLimit";

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

    for (let i = 0; i < 60; i += 1) {
      await recordPushSendOrThrow(db, "push-user-1", 1, now);
    }
    await recordPushSendOrThrow(db, "push-user-2", 1, now);

    await expect(recordPushSendOrThrow(db, "push-user-1", 1, now)).rejects.toBeInstanceOf(
      PushRateLimitExceededError,
    );

    await recordPushSendOrThrow(db, "push-user-1", 1, new Date(now.getTime() + 10 * 60 * 1000 + 1));
  });
});
