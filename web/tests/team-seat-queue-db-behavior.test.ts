// Database-backed proof of the seat queue contract that MemoryTeamSeatQueue
// mirrors: a cheap upsert to mark, a per-team try-lock that reports busy
// instead of waiting, and compare-and-clear on dirty_at so a change during a
// reconcile keeps the team queued. Gated like the other *-db-behavior tests.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { databaseTeamSeatQueue as queue, TEAM_SEATS_BUSY } from "../services/billing/teamSeatQueue";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const TEAM = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2 });
});

beforeEach(async () => {
  if (!sql) return;
  await sql`truncate team_seat_reconciles`;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("team seat queue", () => {
  dbTest("marking is an upsert that lists oldest first and scopes by team", async () => {
    await queue.markDirty(TEAM);
    await queue.markDirty(OTHER);
    await queue.markDirty(TEAM);
    const rows = await queue.listDirty(10);
    expect(rows.map((row) => row.stackTeamId)).toEqual([OTHER, TEAM]);
    expect((await queue.listDirty(10, [TEAM])).map((row) => row.stackTeamId)).toEqual([TEAM]);
    expect(await queue.listDirty(10, [])).toEqual([]);
  });

  dbTest("a clean outcome clears dirty_at only when it is unchanged", async () => {
    await queue.markDirty(TEAM);
    const [seen] = await queue.listDirty(1);
    await queue.recordOutcome(TEAM, seen!.dirtyAt, { memberCount: 3, stripeQuantity: 3, error: null });
    expect(await queue.listDirty(10)).toEqual([]);
    const [row] = await sql!`select last_member_count, last_stripe_quantity, last_error, last_reconciled_at from team_seat_reconciles where stack_team_id = ${TEAM}`;
    expect(row).toMatchObject({ last_member_count: 3, last_stripe_quantity: 3, last_error: null });
    expect(row!.last_reconciled_at).not.toBeNull();

    await queue.markDirty(TEAM);
    const [again] = await queue.listDirty(1);
    await sql!`select pg_sleep(0.002)`;
    await queue.markDirty(TEAM);
    await queue.recordOutcome(TEAM, again!.dirtyAt, { memberCount: 4, stripeQuantity: 4, error: null });
    expect((await queue.listDirty(10)).map((row) => row.stackTeamId)).toEqual([TEAM]);
  });

  dbTest("an error keeps the team dirty and is recorded", async () => {
    await queue.markDirty(TEAM);
    const [seen] = await queue.listDirty(1);
    await queue.recordOutcome(TEAM, seen!.dirtyAt, { memberCount: null, stripeQuantity: null, error: "Error: stripe down" });
    expect((await queue.listDirty(10)).map((row) => row.stackTeamId)).toEqual([TEAM]);
    const [row] = await sql!`select last_error from team_seat_reconciles where stack_team_id = ${TEAM}`;
    expect(row!.last_error).toBe("Error: stripe down");
  });

  dbTest("the per-team lock reports busy instead of waiting", async () => {
    let release: () => void = () => undefined;
    const held = new Promise<void>((resolve) => { release = resolve; });
    let inner: unknown = "unset";
    const outer = queue.withTeamLock(TEAM, async () => {
      inner = await queue.withTeamLock(TEAM, async () => "second");
      const other = await queue.withTeamLock(OTHER, async () => "other");
      await held;
      return other;
    });
    release();
    expect(await outer).toBe("other");
    expect(inner).toBe(TEAM_SEATS_BUSY);
    expect(await queue.withTeamLock(TEAM, async () => "free")).toBe("free");
  });
});
