import { describe, expect, it } from "vitest";
import { createCoalescedRefresh } from "./coalescedRefresh";

function flushMicrotasks(): Promise<void> {
  return Promise.resolve().then(() => undefined);
}

describe("createCoalescedRefresh", () => {
  it("bounds a delayed workspace snapshot to one follow-up and keeps the latest state", async () => {
    const pending: Array<() => void> = [];
    let snapshot = 0;
    let latestState = 0;
    const listWorkspaces = () => {
      const nextSnapshot = ++snapshot;
      return new Promise<number>((resolve) => pending.push(() => resolve(nextSnapshot)));
    };
    const queueRefresh = createCoalescedRefresh(async () => {
      latestState = await listWorkspaces();
    });

    queueRefresh();
    expect(snapshot).toBe(1);

    // These notifications model a resize/layout burst arriving while the
    // current listWorkspaces request is still delayed.
    for (const event of ["surface-resized", "layout-changed", "surface-resized", "layout-changed"]) {
      if (event === "surface-resized" || event === "layout-changed") queueRefresh();
    }
    expect(snapshot).toBe(1);

    pending.shift()?.();
    await flushMicrotasks();
    await flushMicrotasks();
    expect(snapshot).toBe(2);

    pending.shift()?.();
    await flushMicrotasks();
    await flushMicrotasks();
    expect(latestState).toBe(2);
    expect(snapshot).toBe(2);
  });

  it("cancels a queued follow-up when the transport generation is discarded", async () => {
    let resolveCurrent: (() => void) | undefined;
    let requests = 0;
    const queueRefresh = createCoalescedRefresh(
      () =>
        new Promise<void>((resolve) => {
          requests += 1;
          resolveCurrent = resolve;
        }),
    );

    queueRefresh();
    queueRefresh();
    queueRefresh.cancel();
    resolveCurrent?.();
    await flushMicrotasks();
    await flushMicrotasks();

    expect(requests).toBe(1);
  });

  it("stops at one follow-up when the operation keeps invalidating itself", async () => {
    let requests = 0;
    let queueRefresh: (() => void) | undefined;
    queueRefresh = createCoalescedRefresh(async () => {
      requests += 1;
      if (requests < 5) queueRefresh?.();
    });

    queueRefresh();
    await flushMicrotasks();
    await flushMicrotasks();

    expect(requests).toBe(2);
  });

  it("starts a fresh bounded cycle for an invalidation during the follow-up", async () => {
    const pending: Array<() => void> = [];
    let snapshot = 0;
    let latestState = 0;
    const listWorkspaces = () => {
      const nextSnapshot = ++snapshot;
      return new Promise<number>((resolve) => pending.push(() => resolve(nextSnapshot)));
    };
    const queueRefresh = createCoalescedRefresh(async () => {
      latestState = await listWorkspaces();
    });

    queueRefresh();
    queueRefresh();
    pending.shift()?.();
    await flushMicrotasks();
    await flushMicrotasks();
    expect(snapshot).toBe(2);

    // The second request is already in flight when the final event arrives.
    queueRefresh();
    pending.shift()?.();
    await flushMicrotasks();
    await new Promise((resolve) => setTimeout(resolve, 10));
    await flushMicrotasks();
    expect(snapshot).toBe(3);

    pending.shift()?.();
    await flushMicrotasks();
    await flushMicrotasks();
    expect(latestState).toBe(3);
  });

  it("cancels a deferred cycle after a late invalidation", async () => {
    const pending: Array<() => void> = [];
    let requests = 0;
    const queueRefresh = createCoalescedRefresh(
      () =>
        new Promise<void>((resolve) => {
          requests += 1;
          pending.push(resolve);
        }),
    );

    queueRefresh();
    queueRefresh();
    pending.shift()?.();
    await flushMicrotasks();
    await flushMicrotasks();
    queueRefresh();
    pending.shift()?.();
    await flushMicrotasks();
    queueRefresh.cancel();
    await new Promise((resolve) => setTimeout(resolve, 10));

    expect(requests).toBe(2);
  });
});
