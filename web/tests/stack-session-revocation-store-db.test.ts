import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import postgres from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { databaseStackSessionRevocationStore } from "../services/vms/stackSessionRevocationStore";
import { retryPendingStackSessionRevocations } from "../services/vms/stackSessionRevocations";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const sql = runDbTests ? postgres((process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL)!, { max: 1 }) : null;

beforeEach(async () => {
  if (sql) await sql`truncate stack_session_revocations`;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("stack session revocation store", () => {
  dbTest("a throttled revocation stays due after its backoff and is revoked on retry", async () => {
    const store = databaseStackSessionRevocationStore();
    await store.enqueue({ userId: "user-1", accessGrantId: null, stackSessionIds: ["s1", "s2"] });
    // Enqueueing again (a retried DELETE) keeps the existing rows.
    await store.enqueue({ userId: "user-1", accessGrantId: null, stackSessionIds: ["s1"] });
    const now = new Date();
    let answers = [429, 200, 200];
    const revoke = async () => {
      const status = answers.shift();
      if (status !== 200) throw Object.assign(new Error("throttled"), { status });
    };

    expect(await retryPendingStackSessionRevocations({ store, revoke, now: () => now })).toEqual({ attempted: 2, revoked: 1, pending: 1 });
    expect((await store.listOpen(["s1", "s2"])).map((row) => [row.stackSessionId, row.attempts])).toEqual([["s1", 1]]);
    // Backoff: not due a second later, due two minutes later.
    expect(await store.listDue(new Date(now.getTime() + 1_000), 10)).toEqual([]);
    const later = new Date(now.getTime() + 2 * 60_000);
    expect(await retryPendingStackSessionRevocations({ store, revoke, now: () => later })).toEqual({ attempted: 1, revoked: 1, pending: 0 });
    expect(await store.listOpen(["s1", "s2"])).toEqual([]);
    const [row] = await sql!<{ attempts: number; last_error: string | null; revoked_at: Date | null }[]>`
      select attempts, last_error, revoked_at from stack_session_revocations where stack_session_id = 's1'
    `;
    expect(row).toMatchObject({ attempts: 1, last_error: null });
    expect(row!.revoked_at).not.toBeNull();
  });
});
