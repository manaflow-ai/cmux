import { afterEach, beforeEach, expect, test } from "bun:test";
import { cachedSnapshot, emptySnapshot, saveSnapshot, snapshotKey, writeSnapshot } from "./snapshotCache";

const store = new Map<string, string>();
beforeEach(() => {
  store.clear();
  (globalThis as Record<string, unknown>).sessionStorage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
  };
});
afterEach(() => {
  delete (globalThis as Record<string, unknown>).sessionStorage;
});

test("the page's own snapshot keeps its key; each view has its own", () => {
  expect(snapshotKey()).toBe("cmux.acpmux.snapshot");
  expect(snapshotKey("a")).not.toBe(snapshotKey("b"));
});

test("views save and read their own snapshots", () => {
  saveSnapshot({ ...emptySnapshot(), sessionId: "s-a" }, "a");
  saveSnapshot({ ...emptySnapshot(), sessionId: "s-b" }, "b");
  saveSnapshot({ ...emptySnapshot(), sessionId: "s-page" });
  writeSnapshot();
  expect(cachedSnapshot("a").sessionId).toBe("s-a");
  expect(cachedSnapshot("b").sessionId).toBe("s-b");
  expect(cachedSnapshot().sessionId).toBe("s-page");
});
