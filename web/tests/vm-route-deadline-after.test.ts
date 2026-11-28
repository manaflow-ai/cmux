import { afterEach, describe, expect, mock, test } from "bun:test";

// The real continuation path: work past a route's deadline is registered
// with next/server after() so the function stays alive for it, and a missing
// request scope is logged with the route instead of silently dropped.
const registered: Array<() => Promise<unknown>> = [];
let afterThrows = false;
mock.module("next/server", () => ({
  after: (callback: () => Promise<unknown>) => {
    if (afterThrows) throw new Error("`after` was called outside a request scope");
    registered.push(callback);
  },
}));

const { continueAfterResponse } = await import("../services/vms/routeDeadline");

afterEach(() => {
  registered.length = 0;
  afterThrows = false;
});

describe("continueAfterResponse", () => {
  test("registers the unfinished work with after() and settles with it", async () => {
    let finish: () => void = () => {};
    const work = new Promise<void>((resolve) => { finish = resolve; });
    continueAfterResponse(work, "/api/vm/[id]/pause");
    expect(registered).toHaveLength(1);
    let settled = false;
    const kept = registered[0]().then(() => { settled = true; });
    await Promise.resolve();
    expect(settled).toBe(false);
    finish();
    await kept;
    expect(settled).toBe(true);
  });

  test("a rejected continuation settles without throwing", async () => {
    continueAfterResponse(Promise.reject(new Error("provider 502")), "/api/vm/[id]/pause");
    await expect(registered[0]()).resolves.toBeUndefined();
  });

  test("logs the route when after() is unavailable", async () => {
    afterThrows = true;
    const logged: unknown[][] = [];
    const original = console.error;
    console.error = (...args: unknown[]) => { logged.push(args); };
    try {
      continueAfterResponse(Promise.resolve(), "/api/vm/[id]/pause");
    } finally {
      console.error = original;
    }
    expect(String(logged[0]?.[0])).toContain("/api/vm/[id]/pause");
  });
});
