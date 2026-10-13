import { describe, expect, test } from "bun:test";

import { serverUser } from "./helpers/hexclave-fixtures";
import { inboxHarness, postBurst, userId } from "./helpers/hexclave-inbox-harness";
import { MemoryInbox } from "./helpers/hexclave-memory";

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

  test("a throttle stops the drain and reschedules after Hexclave's Retry-After", async () => {
    const harness = inboxHarness();
    for (let index = 0; index < 3; index++) {
      harness.hexclave.users.set(userId(index), serverUser({ id: userId(index) }));
      await harness.post("user.updated", serverUser({ id: userId(index) }), `msg_${index}`);
    }
    harness.hexclave.rateLimit = { perSecond: 0, nowMs: harness.nowMs };
    const first = await harness.drain();
    expect(first).toMatchObject({ throttled: true, entities: 0, deferredEvents: 3 });
    expect(harness.hexclave.throttled).toBe(1);
    // Rescheduled after max(Retry-After 1 s, first backoff 30 s): nothing is
    // claimable before then, everything after.
    harness.hexclave.rateLimit = null;
    harness.advance(29_000);
    expect((await harness.drain()).events).toBe(0);
    harness.advance(2_000);
    expect((await harness.drain()).events).toBe(3);
  });

  test("at most two drains run at once", async () => {
    const harness = inboxHarness();
    const inbox = harness.inbox;
    const now = new Date(harness.nowMs());
    const lease = new Date(harness.nowMs() + 60_000);
    expect(await inbox.claimDrainSlot(now, lease, 2)).toBe(0);
    expect(await inbox.claimDrainSlot(now, lease, 2)).toBe(1);
    expect(await inbox.claimDrainSlot(now, lease, 2)).toBeNull();
    expect((await harness.drain()).skipped).toBe(true);
  });
});
