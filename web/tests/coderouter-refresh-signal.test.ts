import { describe, expect, test } from "bun:test";
import {
  createRefreshCompletionRegistry,
  createStickyRefreshPatience,
  STICKY_REFRESH_PATIENCE_MS,
} from "../services/coderouter/refreshSignal";
import { createFakeRefreshWaitClock } from "./refresh-wait-clock-fixture";

function busy(): Error {
  return Object.assign(new Error("busy"), { _tag: "CodeRouterRefreshBusy" });
}

describe("refresh completion registry", () => {
  test("wakes every waiter for the settled account only", async () => {
    const registry = createRefreshCompletionRegistry();
    const woke: string[] = [];
    const signal = new AbortController().signal;
    const first = registry.next("acct-1", signal).then(() => woke.push("first"));
    const second = registry.next("acct-1", signal).then(() => woke.push("second"));
    const other = registry.next("acct-2", signal).then(() => woke.push("other"));

    registry.settled("acct-1");
    await Promise.all([first, second]);
    expect(woke.sort()).toEqual(["first", "second"]);

    registry.settled("acct-2");
    await other;
    expect(woke).toContain("other");
  });

  test("rejects a waiter with the abort reason and forgets it", async () => {
    const registry = createRefreshCompletionRegistry();
    const controller = new AbortController();
    const waiting = registry.next("acct-1", controller.signal);
    controller.abort(new DOMException("caller left", "AbortError"));
    await expect(waiting).rejects.toMatchObject({ name: "AbortError" });
    // A later settle has nothing left to wake.
    registry.settled("acct-1");
  });
});

describe("sticky refresh patience", () => {
  test("retries as soon as this instance's refresh settles, without advancing time", async () => {
    const clock = createFakeRefreshWaitClock();
    const registry = createRefreshCompletionRegistry({
      onWait: (accountId) => queueMicrotask(() => registry.settled(accountId)),
    });
    let probes = 0;
    const patience = createStickyRefreshPatience({
      registry,
      clock,
      leaseActive: async () => {
        probes += 1;
        return true;
      },
    });
    let attempts = 0;
    const credential = await clock.runUntilSettled(patience({ accountId: "acct-1" }, async () => {
      attempts += 1;
      if (attempts < 3) throw busy();
      return "fresh";
    }));

    expect(credential).toBe("fresh");
    expect(attempts).toBe(3);
    expect(probes).toBe(0);
    expect(clock.now()).toBe(0);
    expect(clock.pendingSleeps()).toBe(0);
  });

  test("falls back to re-reading the lease row when another instance holds it", async () => {
    const clock = createFakeRefreshWaitClock();
    const probeTimes: number[] = [];
    const patience = createStickyRefreshPatience({
      registry: createRefreshCompletionRegistry(),
      clock,
      leaseActive: async () => {
        probeTimes.push(clock.now());
        return probeTimes.length < 3;
      },
    });
    let attempts = 0;
    const credential = await clock.runUntilSettled(patience({ accountId: "acct-1" }, async () => {
      attempts += 1;
      if (attempts === 1) throw busy();
      return "fresh";
    }));

    expect(credential).toBe("fresh");
    expect(attempts).toBe(2);
    // Backoff re-reads: 100 ms, then 200 ms, then 400 ms after the busy answer.
    expect(probeTimes).toEqual([100, 300, 700]);
    expect(clock.pendingSleeps()).toBe(0);
  });

  test("gives up with the busy error at the patience deadline", async () => {
    const clock = createFakeRefreshWaitClock();
    const probeTimes: number[] = [];
    const patience = createStickyRefreshPatience({
      registry: createRefreshCompletionRegistry(),
      clock,
      leaseActive: async () => {
        probeTimes.push(clock.now());
        return true;
      },
    });
    let attempts = 0;
    const waiting = clock.runUntilSettled(patience({ accountId: "acct-1" }, async () => {
      attempts += 1;
      throw busy();
    }));

    await expect(waiting).rejects.toMatchObject({ _tag: "CodeRouterRefreshBusy" });
    expect(attempts).toBe(1);
    expect(clock.now()).toBe(STICKY_REFRESH_PATIENCE_MS);
    expect(probeTimes.at(-1)).toBe(STICKY_REFRESH_PATIENCE_MS);
    expect(clock.pendingSleeps()).toBe(0);
  });

  test("keeps one deadline across repeated refreshes and caps the number of waits", async () => {
    const clock = createFakeRefreshWaitClock();
    const registry = createRefreshCompletionRegistry({
      onWait: (accountId) => queueMicrotask(() => registry.settled(accountId)),
    });
    const patience = createStickyRefreshPatience({
      registry,
      clock,
      leaseActive: async () => true,
      maxWaits: 4,
    });
    let attempts = 0;
    const waiting = clock.runUntilSettled(patience({ accountId: "acct-1" }, async () => {
      attempts += 1;
      throw busy();
    }));

    await expect(waiting).rejects.toMatchObject({ _tag: "CodeRouterRefreshBusy" });
    // One first attempt plus one retry per settled wait.
    expect(attempts).toBe(5);
  });

  test("rethrows anything other than refresh-busy without waiting", async () => {
    const clock = createFakeRefreshWaitClock();
    let probes = 0;
    const patience = createStickyRefreshPatience({
      registry: createRefreshCompletionRegistry(),
      clock,
      leaseActive: async () => {
        probes += 1;
        return true;
      },
    });
    const broken = Object.assign(new Error("broken"), { _tag: "CodeRouterCredentialBroken" });
    await expect(patience({ accountId: "acct-1" }, async () => {
      throw broken;
    })).rejects.toBe(broken);
    expect(probes).toBe(0);
    expect(clock.pendingSleeps()).toBe(0);
  });

  test("request abort cancels the wait, the backoff sleep, and further attempts", async () => {
    const clock = createFakeRefreshWaitClock();
    const controller = new AbortController();
    const registry = createRefreshCompletionRegistry({
      onWait: () => queueMicrotask(() => controller.abort(new DOMException("caller left", "AbortError"))),
    });
    let probes = 0;
    const patience = createStickyRefreshPatience({
      registry,
      clock,
      leaseActive: async () => {
        probes += 1;
        return true;
      },
    });
    let attempts = 0;
    const waiting = patience({ accountId: "acct-1", signal: controller.signal }, async () => {
      attempts += 1;
      throw busy();
    });

    await expect(waiting).rejects.toMatchObject({ name: "AbortError" });
    expect(attempts).toBe(1);
    expect(probes).toBe(0);
    expect(clock.now()).toBe(0);
    expect(clock.pendingSleeps()).toBe(0);
  });

  test("a failing lease re-read keeps waiting until the deadline instead of surfacing the database error", async () => {
    const clock = createFakeRefreshWaitClock();
    let probes = 0;
    const patience = createStickyRefreshPatience({
      registry: createRefreshCompletionRegistry(),
      clock,
      leaseActive: async () => {
        probes += 1;
        throw new Error("database unavailable");
      },
    });
    const waiting = clock.runUntilSettled(patience({ accountId: "acct-1" }, async () => {
      throw busy();
    }));
    await expect(waiting).rejects.toMatchObject({ _tag: "CodeRouterRefreshBusy" });
    expect(probes).toBeGreaterThan(0);
    expect(clock.now()).toBe(STICKY_REFRESH_PATIENCE_MS);
  });
});
