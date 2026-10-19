import { describe, expect, test } from "bun:test";

import { serverUser } from "./helpers/hexclave-fixtures";
import { inboxHarness, postBurst, userId } from "./helpers/hexclave-inbox-harness";
import { MemoryInbox } from "./helpers/hexclave-memory";
import { MAX_ATTEMPTS, STUCK_ATTEMPTS } from "../services/auth/hexclave/inbox";

// On 2026-10-13 a Hexclave throttle made webhook deliveries fail; Svix then
// redelivered 300+ events at once, each doing up to four Hexclave reads in
// the request, which kept Hexclave throttling us. Deliveries are now stored
// and answered 200; a rate-limited drain applies them.

describe("Hexclave webhook inbox", () => {
  test("a verified delivery is stored and answered 200 without any Hexclave read", async () => {
    const harness = inboxHarness();
    harness.hexclave.users.set(userId(1), serverUser({ id: userId(1) }));
    const response = await harness.post("user.updated", serverUser({ id: userId(1) }), "msg_1");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ received: true, queued: "user.updated" });
    expect(harness.hexclave.calls).toEqual([]);
    expect(harness.drainsScheduled()).toBe(1);
    // A redelivery while it waits is stored once.
    expect((await harness.post("user.updated", serverUser({ id: userId(1) }), "msg_1")).status).toBe(200);
    expect((harness.inbox as MemoryInbox).rows.size).toBe(1);
  });

  test("a store failure answers 503 so Svix redelivers", async () => {
    const inbox = new MemoryInbox();
    inbox.failEnqueue = new Error("database unavailable");
    const harness = inboxHarness(inbox);
    const response = await harness.post("user.updated", serverUser({ id: userId(1) }), "msg_1");
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("30");
  });

  test("a burst of 300 deliveries against a Hexclave that throttles above 20 calls a second is applied in full", async () => {
    const harness = inboxHarness();
    const ids = await postBurst(harness);
    harness.hexclave.rateLimit = { perSecond: 20, nowMs: harness.nowMs };

    let drains = 0;
    while ((harness.inbox as MemoryInbox).rows.size > 0 && drains < 2_000) {
      await harness.drain();
      harness.advance(1_000);
      drains += 1;
    }

    // No loss: every delivery was applied and recorded exactly once.
    expect((harness.inbox as MemoryInbox).rows.size).toBe(0);
    const processed = [...harness.mirror.events.entries()].filter(([, event]) => event.processed).map(([id]) => id).sort();
    expect(processed).toEqual(ids);
    expect(harness.mirror.users.size).toBe(120);
    expect(harness.mirror.teams.size).toBe(40);
    // Hexclave did throttle, and the drain backed off instead of failing.
    expect(harness.hexclave.throttled).toBeGreaterThan(0);
    // Coalescing: far fewer user reads than user events.
    const userReads = harness.hexclave.calls.filter((call) => call.startsWith("getUser:")).length;
    expect(userReads).toBeLessThan(260);
  });

  test("a coalesced reconcile reads each user once for all of their pending events", async () => {
    const harness = inboxHarness();
    harness.hexclave.users.set(userId(5), serverUser({ id: userId(5) }));
    for (const svixId of ["msg_a", "msg_b", "msg_c"]) {
      await harness.post("user.updated", serverUser({ id: userId(5) }), svixId);
    }
    const result = await harness.drain();
    expect(result).toMatchObject({ entities: 1, events: 3, throttled: false });
    expect(harness.hexclave.calls.filter((call) => call === `getUser:${userId(5)}`)).toHaveLength(1);
  });

  test("a throttle sets a global backoff: the failed entity counts an attempt, untried ones only wait", async () => {
    const harness = inboxHarness();
    for (let index = 0; index < 3; index++) {
      harness.hexclave.users.set(userId(index), serverUser({ id: userId(index) }));
      await harness.post("user.updated", serverUser({ id: userId(index) }), `msg_${index}`);
    }
    harness.hexclave.rateLimit = { perSecond: 0, nowMs: harness.nowMs };
    const first = await harness.drain();
    expect(first).toMatchObject({ throttled: true, entities: 0, deferredEvents: 3 });
    expect(harness.hexclave.throttled).toBe(1);
    const rows = (harness.inbox as MemoryInbox).rows;
    expect([...rows.values()].map((row) => [row.svixId, row.attempts])).toEqual([["msg_0", 1], ["msg_1", 0], ["msg_2", 0]]);
    harness.hexclave.rateLimit = null;
    // Inside Retry-After (1 s) no drain starts at all.
    expect((await harness.drain()).skipped).toBe(true);
    expect(harness.hexclave.calls).toEqual([]);
    // After it, the untried entities run; the failed one waits out its own backoff (30 s).
    harness.advance(1_000);
    expect((await harness.drain()).events).toBe(2);
    harness.advance(30_000);
    expect((await harness.drain()).events).toBe(1);
  });

  test("a global throttle set by one drain stops a second drain before it reads Hexclave", async () => {
    const harness = inboxHarness();
    for (let index = 0; index < 2; index++) {
      harness.hexclave.users.set(userId(index), serverUser({ id: userId(index) }));
      await harness.post("user.updated", serverUser({ id: userId(index) }), `msg_${index}`);
    }
    harness.hexclave.rateLimit = { perSecond: 0, nowMs: harness.nowMs };
    await harness.drain(1);
    const reads = harness.hexclave.throttled;
    expect(await harness.drain(1)).toMatchObject({ skipped: true });
    expect(harness.hexclave.throttled).toBe(reads);
  });

  test("user.deleted and user.updated for one user coalesce into one read and end deleted", async () => {
    const harness = inboxHarness();
    harness.hexclave.users.set(userId(7), serverUser({ id: userId(7) }));
    await harness.post("user.created", serverUser({ id: userId(7) }), "msg_created");
    await harness.drain();
    expect(harness.mirror.users.has(userId(7))).toBe(true);
    harness.hexclave.deleteUser(userId(7));
    await harness.post("user.updated", serverUser({ id: userId(7) }), "msg_updated");
    await harness.post("user.deleted", { id: userId(7), teams: [] }, "msg_deleted");
    harness.hexclave.calls.length = 0;
    expect(await harness.drain()).toMatchObject({ entities: 1, events: 2 });
    expect(harness.hexclave.calls.filter((call) => call.startsWith("getUser:"))).toHaveLength(1);
    expect(harness.mirror.users.has(userId(7))).toBe(false);
    expect((harness.inbox as MemoryInbox).rows.size).toBe(0);
  });

  test("two concurrent drains apply each event once", async () => {
    const harness = inboxHarness();
    for (let index = 0; index < 20; index++) {
      harness.hexclave.users.set(userId(index), serverUser({ id: userId(index) }));
      await harness.post("user.updated", serverUser({ id: userId(index) }), `msg_${index}`);
    }
    const [a, b] = await Promise.all([harness.drain(20), harness.drain(20)]);
    const rest = await harness.drain(20);
    expect(a.events + b.events + rest.events).toBe(20);
    expect(harness.hexclave.calls.filter((call) => call.startsWith("getUser:"))).toHaveLength(20);
  });

  test("a drain that crashed holding claims leaves them to be reclaimed and applied once", async () => {
    const harness = inboxHarness();
    harness.hexclave.users.set(userId(1), serverUser({ id: userId(1) }));
    await harness.post("user.updated", serverUser({ id: userId(1) }), "msg_crash");
    const now = new Date(harness.nowMs());
    await harness.inbox.claimDrainSlot(now, new Date(now.getTime() + 120_000), 2);
    expect(await harness.inbox.claimDue(now, 10, new Date(now.getTime() + 120_000))).toHaveLength(1);
    harness.advance(60_000);
    expect((await harness.drain()).events).toBe(0);
    harness.advance(61_000);
    expect((await harness.drain()).events).toBe(1);
    expect(harness.hexclave.calls.filter((call) => call === `getUser:${userId(1)}`)).toHaveLength(1);
  });

  test("a permanently failing entity is dead-lettered after the attempt cap", async () => {
    const harness = inboxHarness();
    harness.hexclave.users.set(userId(3), serverUser({ id: userId(3) }));
    await harness.post("user.updated", serverUser({ id: userId(3) }), "msg_bad");
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      harness.hexclave.failNext = new Error("mirror write failed");
      await harness.drain();
      harness.advance(2 * 60 * 60_000);
    }
    const row = (harness.inbox as MemoryInbox).rows.get("msg_bad")!;
    expect(row.attempts).toBe(MAX_ATTEMPTS);
    expect(row.deadLetteredAt).not.toBeNull();
    expect(await harness.inbox.health(STUCK_ATTEMPTS)).toEqual({ stuck: 0, deadLettered: 1 });
    // Dead letters are never drained again.
    expect((await harness.drain()).events).toBe(0);
  });

  test("at most two drains run at once", async () => {
    const harness = inboxHarness();
    const inbox = harness.inbox;
    const now = new Date(harness.nowMs());
    const lease = new Date(harness.nowMs() + 60_000);
    expect((await inbox.claimDrainSlot(now, lease, 2))?.slot).toBe(0);
    expect((await inbox.claimDrainSlot(now, lease, 2))?.slot).toBe(1);
    expect(await inbox.claimDrainSlot(now, lease, 2)).toBeNull();
    expect((await harness.drain()).skipped).toBe(true);
  });
});
