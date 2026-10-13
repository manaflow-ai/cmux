import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import postgres from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { createDrizzleHexclaveInboxStore } from "../services/auth/hexclave/inboxStore";
import { inboxHarness, postBurst } from "./helpers/hexclave-inbox-harness";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const sql = runDbTests ? postgres((process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL)!, { max: 1 }) : null;

beforeEach(async () => {
  if (sql) await sql`truncate hexclave_webhook_inbox, hexclave_webhook_inbox_drain_slots`;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

const user = (id: string) => ({ kind: "user" as const, id, revokeCandidateTeamIds: [] as string[] });

describe("Hexclave webhook inbox store", () => {
  dbTest("a burst of 300 deliveries is applied in full against a throttling Hexclave", async () => {
    const harness = inboxHarness(createDrizzleHexclaveInboxStore());
    const ids = await postBurst(harness);
    harness.hexclave.rateLimit = { perSecond: 20, nowMs: harness.nowMs };
    let drains = 0;
    for (;;) {
      const [{ count }] = await sql!<{ count: number }[]>`select count(*)::int as count from hexclave_webhook_inbox`;
      if (count === 0 || drains >= 2_000) break;
      await harness.drain();
      harness.advance(1_000);
      drains += 1;
    }
    const [{ count }] = await sql!<{ count: number }[]>`select count(*)::int as count from hexclave_webhook_inbox`;
    expect(count).toBe(0);
    const processed = [...harness.mirror.events.entries()].filter(([, event]) => event.processed).map(([id]) => id).sort();
    expect(processed).toEqual(ids);
    expect(harness.hexclave.throttled).toBeGreaterThan(0);
  });

  dbTest("enqueue keeps the first copy of a svix id and the signed payload", async () => {
    const store = createDrizzleHexclaveInboxStore();
    await store.enqueue({ svixId: "m1", eventType: "user.updated", target: user("u1"), payload: { type: "user.updated", data: { id: "u1" } } });
    await store.enqueue({ svixId: "m1", eventType: "user.updated", target: user("u1"), payload: { changed: true } });
    const rows = await sql!<{ payload: unknown }[]>`select payload from hexclave_webhook_inbox`;
    expect(rows).toEqual([{ payload: { type: "user.updated", data: { id: "u1" } } }]);
  });

  dbTest("a claim takes every due event of the oldest entities, and a concurrent claim takes none of them", async () => {
    const store = createDrizzleHexclaveInboxStore();
    for (const [svixId, id] of [["m1", "u1"], ["m2", "u2"], ["m3", "u1"], ["m4", "u3"]] as const) {
      await store.enqueue({ svixId, eventType: "user.updated", target: user(id), payload: {} });
    }
    await sql!`update hexclave_webhook_inbox set next_attempt_at = now() - interval '1 minute'`;
    const now = new Date();
    const lease = new Date(now.getTime() + 60_000);
    const [a, b] = await Promise.all([store.claimDue(now, 2, lease), store.claimDue(now, 2, lease)]);
    const claimedA = a.map((entry) => entry.svixId);
    const claimedB = b.map((entry) => entry.svixId);
    // Disjoint: no event is held by both drains.
    expect(claimedA.filter((id) => claimedB.includes(id))).toEqual([]);
    // Whoever got u1 holds both of its events, so one read applies them.
    const withU1 = claimedA.includes("m1") ? claimedA : claimedB;
    expect(withU1).toContain("m3");
    // Nothing is lost: a later claim picks up whatever neither drain took.
    const rest = await store.claimDue(now, 5, lease);
    expect([...claimedA, ...claimedB, ...rest.map((entry) => entry.svixId)].sort()).toEqual(["m1", "m2", "m3", "m4"]);
  });

  dbTest("a rescheduled event is not due before its time and keeps its attempt count", async () => {
    const store = createDrizzleHexclaveInboxStore();
    await store.enqueue({ svixId: "m1", eventType: "team.updated", target: { kind: "team", id: "t1", revokeCandidateTeamIds: [] }, payload: {} });
    await sql!`update hexclave_webhook_inbox set next_attempt_at = now() - interval '1 minute'`;
    const now = new Date();
    expect(await store.claimDue(now, 5, new Date(now.getTime() + 60_000))).toHaveLength(1);
    await store.retryLater(["m1"], { nextAttemptAt: new Date(now.getTime() + 30_000), error: "HexclaveApiError 429" });
    expect(await store.claimDue(new Date(now.getTime() + 10_000), 5, new Date(now.getTime() + 70_000))).toEqual([]);
    const [again] = await store.claimDue(new Date(now.getTime() + 31_000), 5, new Date(now.getTime() + 90_000));
    expect(again).toMatchObject({ svixId: "m1", attempts: 1, target: { kind: "team", id: "t1" } });
    await store.complete(["m1"]);
    const [{ count }] = await sql!<{ count: number }[]>`select count(*)::int as count from hexclave_webhook_inbox`;
    expect(count).toBe(0);
  });

  dbTest("at most two drain slots are held at once, and an expired lease is reusable", async () => {
    const store = createDrizzleHexclaveInboxStore();
    const now = new Date();
    const lease = new Date(now.getTime() + 60_000);
    expect(await store.claimDrainSlot(now, lease, 2)).toBe(0);
    expect(await store.claimDrainSlot(now, lease, 2)).toBe(1);
    expect(await store.claimDrainSlot(now, lease, 2)).toBeNull();
    expect(await store.claimDrainSlot(new Date(now.getTime() + 61_000), new Date(now.getTime() + 120_000), 2)).toBe(0);
    await store.releaseDrainSlot(1);
    expect(await store.claimDrainSlot(new Date(now.getTime() + 62_000), new Date(now.getTime() + 120_000), 2)).toBe(1);
  });
});
