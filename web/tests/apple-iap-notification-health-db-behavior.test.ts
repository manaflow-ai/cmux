// Database proof for the Billing nightly's delivery read: it finds a TEST
// notification by UUID and nothing else. Gated like the other *-db-behavior
// tests.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { findAppleTestNotification } from "../services/billing/apple/notificationHealth";

const runDbTests = process.env.CMUX_DB_TEST === "1";
// Runs only against a database (CMUX_DB_TEST=1, scripts/run-db-behavior-tests.sh).
const dbTest = test.if(runDbTests);

const TEST_UUID = "11111111-2222-4333-8444-555555555555";
const RENEWAL_UUID = "66666666-7777-4888-9999-aaaaaaaaaaaa";

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2 });
});

beforeEach(async () => {
  if (!sql) return;
  await sql`truncate apple_notifications`;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

async function insert(uuid: string, type: string, processedAt: Date | null) {
  await sql!`
    insert into apple_notifications
      (notification_uuid, notification_type, environment, original_transaction_id, signed_date, payload, received_at, processed_at, error)
    values
      (${uuid}, ${type}, 'Sandbox', ${type === "TEST" ? null : "otx-1"}, now(),
       ${sql!.json({ secret: "payload" })}, '2026-11-16T09:00:01Z', ${processedAt}, 'skipped: no_state_change')
  `;
}

describe("Apple TEST notification lookup", () => {
  dbTest("finds a recorded TEST notification with its timestamps", async () => {
    await insert(TEST_UUID, "TEST", new Date("2026-11-16T09:00:02Z"));
    expect(await findAppleTestNotification(TEST_UUID)).toEqual({
      receivedAt: new Date("2026-11-16T09:00:01Z"),
      processedAt: new Date("2026-11-16T09:00:02Z"),
      environment: "Sandbox",
    });
  });

  dbTest("reports an unprocessed TEST notification as unprocessed", async () => {
    await insert(TEST_UUID, "TEST", null);
    expect((await findAppleTestNotification(TEST_UUID))?.processedAt).toBeNull();
  });

  dbTest("never answers for a notification that is not a TEST", async () => {
    await insert(RENEWAL_UUID, "DID_RENEW", new Date());
    expect(await findAppleTestNotification(RENEWAL_UUID)).toBeNull();
  });

  dbTest("answers null for an unknown UUID", async () => {
    expect(await findAppleTestNotification(TEST_UUID)).toBeNull();
  });
});
