import { afterEach, describe, expect, test } from "bun:test";
import { discardCloudDb } from "../db/client";

// A list read that timed out on a wedged pool drops that pool, not whatever
// client is current by the time its deadline fires: a later list that queued on
// the same dead pool must not drop the fresh pool another request already
// opened. The dropped client closes only after a grace, so other requests'
// queries on it can finish instead of being cut off.

type FakeState = { db: object; close: () => Promise<void>; abandon: () => Promise<void>; warm: () => Promise<void>; key: string };
const holder = globalThis as typeof globalThis & { __cmuxCloudDb?: FakeState };

function fakeState(label: string, closed: string[]): FakeState {
  return {
    db: { label },
    close: async () => undefined,
    abandon: async () => { closed.push(label); },
    warm: async () => undefined,
    key: label,
  };
}

afterEach(() => { holder.__cmuxCloudDb = undefined; });

describe("discardCloudDb", () => {
  test("a stale timeout does not drop the fresh pool", () => {
    const closed: string[] = [];
    const wedged = fakeState("wedged", closed);
    const fresh = fakeState("fresh", closed);
    holder.__cmuxCloudDb = fresh;
    discardCloudDb(wedged.db as never, { closeAfterMs: 0 });
    expect(holder.__cmuxCloudDb).toBe(fresh);
    expect(closed).toEqual([]);
  });

  test("the timed-out pool is dropped now and closed after the grace", async () => {
    const closed: string[] = [];
    const wedged = fakeState("wedged", closed);
    holder.__cmuxCloudDb = wedged;
    discardCloudDb(wedged.db as never, { closeAfterMs: 20 });
    expect(holder.__cmuxCloudDb).toBeUndefined();
    expect(closed).toEqual([]);
    for (const giveUpAt = performance.now() + 2_000; closed.length === 0 && performance.now() < giveUpAt;) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    expect(closed).toEqual(["wedged"]);
  });
});
