import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import postgres from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { createDrizzleHexclaveInboxStore } from "../services/auth/hexclave/inboxStore";
import { serverUser } from "./helpers/hexclave-fixtures";
import { inboxHarness, postBurst, userId } from "./helpers/hexclave-inbox-harness";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const databaseUrl = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
const sql = runDbTests ? postgres(databaseUrl!, { max: 1 }) : null;

beforeEach(async () => {
  if (sql) await sql`truncate hexclave_webhook_inbox, hexclave_webhook_inbox_drain_slots, hexclave_webhook_inbox_state, hexclave_webhook_events`;
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

  dbTest("enqueue keeps the first copy of a svix id and stores only the target", async () => {
    const store = createDrizzleHexclaveInboxStore();
    await store.enqueue({ svixId: "m1", eventType: "user.updated", target: user("u1") });
    await store.enqueue({ svixId: "m1", eventType: "team.updated", target: { kind: "team", id: "t9", revokeCandidateTeamIds: [] } });
    const rows = await sql!<{ event_type: string; entity_kind: string; entity_id: string }[]>`
      select event_type, entity_kind, entity_id from hexclave_webhook_inbox
    `;
    expect(rows).toEqual([{ event_type: "user.updated", entity_kind: "user", entity_id: "u1" }]);
    const columns = await sql!<{ column_name: string }[]>`
      select column_name from information_schema.columns where table_name = 'hexclave_webhook_inbox'
    `;
    expect(columns.map((column) => column.column_name)).not.toContain("payload");
  });

  dbTest("a claim takes every due event of the oldest entities, and a concurrent claim takes none of them", async () => {
    const store = createDrizzleHexclaveInboxStore();
    for (const [svixId, id] of [["m1", "u1"], ["m2", "u2"], ["m3", "u1"], ["m4", "u3"]] as const) {
      await store.enqueue({ svixId, eventType: "user.updated", target: user(id) });
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

  dbTest("entity selection skips a claim whose establishment lock is held", async () => {
    const store = createDrizzleHexclaveInboxStore();
    await store.enqueue({ svixId: "m-locked", eventType: "user.updated", target: user("u-locked") });
    const lockKey = "hexclave:inbox:user:u-locked";
    let unlock!: () => void;
    let locked!: () => void;
    const release = new Promise<void>((resolve) => { unlock = resolve; });
    const ready = new Promise<void>((resolve) => { locked = resolve; });
    const holder = sql!.begin(async (tx) => {
      await tx`select pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`;
      locked();
      await release;
    });
    await ready;
    const now = new Date();
    try {
      expect(await store.claimDue(now, 1, new Date(now.getTime() + 60_000))).toEqual([]);
    } finally {
      unlock();
      await holder;
    }
    expect((await store.claimDue(now, 1, new Date(now.getTime() + 60_000))).map((entry) => entry.svixId))
      .toEqual(["m-locked"]);
  });

  dbTest("claim renewal waits for the entity-establishment lock, then rechecks its token", async () => {
    const store = createDrizzleHexclaveInboxStore();
    const observer = postgres(databaseUrl!, { max: 1 });
    await store.enqueue({ svixId: "m-renew-locked", eventType: "user.updated", target: user("u-renew-locked") });
    const now = new Date();
    await sql!`update hexclave_webhook_inbox set next_attempt_at = ${new Date(now.getTime() - 1_000)} where svix_id = 'm-renew-locked'`;
    const claimedUntil = new Date(now.getTime() + 60_000);
    expect(await store.claimDue(now, 1, claimedUntil)).toHaveLength(1);

    let unlock!: () => void;
    let locked!: () => void;
    let holderPid = 0;
    const release = new Promise<void>((resolve) => { unlock = resolve; });
    const ready = new Promise<void>((resolve) => { locked = resolve; });
    const holder = sql!.begin(async (tx) => {
      const [session] = await tx<{ pid: number }[]>`select pg_backend_pid()::int as pid`;
      holderPid = session!.pid;
      await tx`select pg_advisory_xact_lock(hashtextextended('hexclave:inbox:user:u-renew-locked', 0))`;
      locked();
      await release;
    });
    await ready;
    const renewedUntil = new Date(claimedUntil.getTime() + 60_000);
    let settled = false;
    const renewal = store.renewClaims(["m-renew-locked"], claimedUntil, renewedUntil).then((renewed) => {
      settled = true;
      return renewed;
    });
    try {
      const deadline = Date.now() + 5_000;
      let waiting = 0;
      while (!settled && waiting === 0 && Date.now() < deadline) {
        const [row] = await observer<{ waiting: number }[]>`
          select count(*)::int as waiting
          from pg_stat_activity as waiter
          where waiter.wait_event_type = 'Lock'
            and ${holderPid} = any(pg_blocking_pids(waiter.pid))
        `;
        waiting = row?.waiting ?? 0;
        if (waiting === 0) await new Promise((resolve) => setTimeout(resolve, 10));
      }
      expect(settled).toBe(false);
      expect(waiting).toBe(1);
      unlock();
      await holder;
    } finally {
      unlock();
      await holder.catch(() => {});
      await observer.end({ timeout: 5 });
    }
    expect(await renewal).toBe(true);
  });

  dbTest("a new event for an entity waits for that entity's active claim", async () => {
    const store = createDrizzleHexclaveInboxStore();
    const now = new Date();
    const leaseUntil = new Date(now.getTime() + 60_000);
    await store.enqueue({ svixId: "m-remove", eventType: "user.updated", target: user("u-one") });
    await sql!`update hexclave_webhook_inbox set next_attempt_at = ${new Date(now.getTime() - 1_000)} where svix_id = 'm-remove'`;
    expect((await store.claimDue(now, 5, leaseUntil)).map((entry) => entry.svixId)).toEqual(["m-remove"]);

    await store.enqueue({ svixId: "m-readd", eventType: "team_membership.created", target: user("u-one") });
    await sql!`update hexclave_webhook_inbox set next_attempt_at = ${new Date(now.getTime() - 1_000)} where svix_id = 'm-readd'`;
    expect(await store.claimDue(now, 5, leaseUntil)).toEqual([]);
    const afterLease = new Date(leaseUntil.getTime() + 1);
    expect((await store.claimDue(afterLease, 5, new Date(afterLease.getTime() + 60_000)))
      .map((entry) => entry.svixId).sort()).toEqual(["m-readd", "m-remove"]);
  });

  dbTest("claim mutations are fenced by the exact lease token", async () => {
    const store = createDrizzleHexclaveInboxStore();
    for (const svixId of ["m-complete", "m-fail", "m-defer"]) {
      await store.enqueue({ svixId, eventType: "user.updated", target: user("u-fenced") });
    }
    const firstAt = new Date();
    await sql!`update hexclave_webhook_inbox set next_attempt_at = ${new Date(firstAt.getTime() - 1_000)} where entity_id = 'u-fenced'`;
    const firstUntil = new Date(firstAt.getTime() + 60_000);
    const first = await store.claimDue(firstAt, 1, firstUntil);
    expect(first).toHaveLength(3);
    const renewedUntil = new Date(firstUntil.getTime() + 60_000);
    expect(await store.renewClaims(first.map((entry) => entry.svixId), firstUntil, renewedUntil)).toBe(true);
    expect(await store.claimDue(new Date(firstUntil.getTime() + 1), 1, renewedUntil)).toEqual([]);
    const secondAt = new Date(renewedUntil.getTime() + 1);
    const secondUntil = new Date(secondAt.getTime() + 60_000);
    expect(await store.claimDue(secondAt, 1, secondUntil)).toHaveLength(3);

    expect(await store.renewClaims(["m-complete"], renewedUntil, new Date(secondUntil.getTime() + 60_000))).toBe(false);
    expect(await store.complete(["m-complete"], renewedUntil)).toBe(false);
    expect(await store.recordFailure(["m-fail"], renewedUntil, {
      now: secondAt,
      nextAttemptAt: secondAt,
      error: "stale worker",
      maxAttempts: 3,
    })).toBe(false);
    expect(await store.defer(["m-defer"], renewedUntil, secondAt)).toBe(false);
    const rows = await sql!<{ svix_id: string; attempts: number; claimed_until: Date }[]>`
      select svix_id, attempts, claimed_until
      from hexclave_webhook_inbox
      order by svix_id
    `;
    expect(rows).toEqual([
      { svix_id: "m-complete", attempts: 0, claimed_until: secondUntil },
      { svix_id: "m-defer", attempts: 0, claimed_until: secondUntil },
      { svix_id: "m-fail", attempts: 0, claimed_until: secondUntil },
    ]);
  });

  dbTest("a failed entity counts an attempt and dead-letters at the cap; a deferred one does not count", async () => {
    const store = createDrizzleHexclaveInboxStore();
    await store.enqueue({ svixId: "m1", eventType: "team.updated", target: { kind: "team", id: "t1", revokeCandidateTeamIds: [] } });
    await store.enqueue({ svixId: "m2", eventType: "team.updated", target: { kind: "team", id: "t2", revokeCandidateTeamIds: [] } });
    await sql!`update hexclave_webhook_inbox set next_attempt_at = now() - interval '1 minute'`;
    const now = new Date();
    const initial = await store.claimDue(now, 5, new Date(now.getTime() + 60_000));
    expect(initial).toHaveLength(2);
    const initialClaim = initial[0]!.claimUntil;
    const throttleUntil = new Date(now.getTime() + 15_000);
    expect(await store.recordFailure(["m1"], initialClaim, {
      now,
      nextAttemptAt: new Date(now.getTime() + 30_000),
      error: "HexclaveApiError 429",
      maxAttempts: 3,
      throttleUntil,
    })).toBe(true);
    expect(await store.claimDrainSlot(new Date(now.getTime() + 1), new Date(now.getTime() + 60_000), 2)).toBeNull();
    expect(await store.defer(["m2"], initialClaim, new Date(now.getTime() + 1_000))).toBe(true);
    const later = await store.claimDue(new Date(now.getTime() + 31_000), 5, new Date(now.getTime() + 90_000));
    expect(later.map((entry) => [entry.svixId, entry.attempts])).toEqual([["m1", 1], ["m2", 0]]);
    const laterClaim = later[0]!.claimUntil;
    expect(await store.recordFailure(["m1"], laterClaim, { now, nextAttemptAt: now, error: "x", maxAttempts: 3 })).toBe(true);
    const final = await store.claimDue(new Date(now.getTime() + 31_001), 1, new Date(now.getTime() + 120_000));
    expect(final.map((entry) => entry.svixId)).toEqual(["m1"]);
    expect(await store.recordFailure(["m1"], final[0]!.claimUntil, { now, nextAttemptAt: now, error: "x", maxAttempts: 3 })).toBe(true);
    expect(await store.health(2)).toEqual({ stuck: 0, deadLettered: 1 });
    expect(await store.claimDue(new Date(now.getTime() + 3_600_000), 5, new Date(now.getTime() + 3_700_000)))
      .toEqual([expect.objectContaining({ svixId: "m2" })]);
    // Alerting is change-only.
    expect(await store.recordReportedHealth({ stuck: 0, deadLettered: 1 })).toBe(true);
    expect(await store.recordReportedHealth({ stuck: 0, deadLettered: 1 })).toBe(false);
    expect(await store.recordReportedHealth({ stuck: 1, deadLettered: 1 })).toBe(true);
    // Retention: dead letters older than the cutoff go; younger stay.
    expect(await store.purgeDeadLettered(new Date(now.getTime() - 1_000))).toBe(0);
    expect(await store.purgeDeadLettered(new Date(now.getTime() + 1_000))).toBe(1);
  });

  dbTest("at most two drain slots are held at once; only the holder releases; a throttle holds every drain", async () => {
    const store = createDrizzleHexclaveInboxStore();
    const now = new Date();
    const lease = new Date(now.getTime() + 60_000);
    const first = await store.claimDrainSlot(now, lease, 2);
    const second = await store.claimDrainSlot(now, lease, 2);
    expect([first?.slot, second?.slot]).toEqual([0, 1]);
    expect(await store.claimDrainSlot(now, lease, 2)).toBeNull();
    // A lease that expired and was taken over is not released by its old holder.
    const takeover = await store.claimDrainSlot(new Date(now.getTime() + 61_000), new Date(now.getTime() + 120_000), 2);
    expect(takeover?.slot).toBe(0);
    await store.releaseDrainSlot(first!);
    expect(await store.claimDrainSlot(new Date(now.getTime() + 62_000), new Date(now.getTime() + 120_000), 1)).toBeNull();
    await store.releaseDrainSlot(takeover!);
    const free = await store.claimDrainSlot(new Date(now.getTime() + 62_000), new Date(now.getTime() + 120_000), 1);
    expect(free?.slot).toBe(0);
    await store.releaseDrainSlot(free!);
    await store.throttleUntil(new Date(now.getTime() + 300_000));
    await store.throttleUntil(new Date(now.getTime() + 100_000));
    expect(await store.claimDrainSlot(new Date(now.getTime() + 200_000), new Date(now.getTime() + 260_000), 2)).toBeNull();
    expect(await store.claimDrainSlot(new Date(now.getTime() + 301_000), new Date(now.getTime() + 360_000), 2)).not.toBeNull();
  });

  dbTest("a drain that crashed holding claims leaves them to be reclaimed and applied once", async () => {
    const harness = inboxHarness(createDrizzleHexclaveInboxStore());
    harness.hexclave.users.set(userId(1), serverUser({ id: userId(1) }));
    await harness.post("user.updated", serverUser({ id: userId(1) }), "msg_crash");
    const store = harness.inbox;
    const now = new Date(harness.nowMs());
    // The crashed drain: slot and claim taken, nothing applied or released.
    await store.claimDrainSlot(now, new Date(now.getTime() + 120_000), 2);
    expect(await store.claimDue(now, 10, new Date(now.getTime() + 120_000))).toHaveLength(1);
    harness.advance(60_000);
    expect((await harness.drain()).events).toBe(0);
    harness.advance(61_000);
    expect((await harness.drain()).events).toBe(1);
    expect((await harness.drain()).events).toBe(0);
    expect(harness.hexclave.calls.filter((call) => call === `getUser:${userId(1)}`)).toHaveLength(1);
  });

  dbTest("two concurrent drains apply each event once", async () => {
    const harness = inboxHarness(createDrizzleHexclaveInboxStore());
    for (let index = 0; index < 20; index++) {
      harness.hexclave.users.set(userId(index), serverUser({ id: userId(index) }));
      await harness.post("user.updated", serverUser({ id: userId(index) }), `msg_${index}`);
      await harness.post("user.created", serverUser({ id: userId(index) }), `msg_c${index}`);
    }
    const [a, b] = await Promise.all([harness.drain(20), harness.drain(20)]);
    const rest = await harness.drain(40);
    expect(a.events + b.events + rest.events).toBe(40);
    for (let index = 0; index < 20; index++) {
      expect(harness.hexclave.calls.filter((call) => call === `getUser:${userId(index)}`)).toHaveLength(1);
    }
  });
});
