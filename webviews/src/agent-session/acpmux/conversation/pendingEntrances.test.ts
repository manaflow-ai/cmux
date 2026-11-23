// A row that arrived live enters on its first mount only if it mounts soon (pendingEntrances.ts).
// Leo, 2026-11-21: "i srolled up and then bac k down and it replayed an animation" (O16, O17 in
// design/chat-animation-ordering-map.md).
import { expect, test } from "bun:test";
import { ENTRANCE_MOUNT_MS, PendingEntrances } from "./pendingEntrances";

test("a row that mounts with its arrival enters; one mounted after a scroll back draws in place", () => {
  let now = 0;
  const pending = new PendingEntrances(() => now);
  pending.add("reply");
  now = 16;
  expect(pending.has("reply")).toBe(true);
  // The reader was scrolled away: the row mounts seconds later, when they come back.
  pending.add("tool");
  now = 16 + ENTRANCE_MOUNT_MS + 1;
  expect(pending.has("tool")).toBe(false);
});

test("a mounted row never enters again, and a hidden page or another chat drops every pending one", () => {
  let now = 0;
  const pending = new PendingEntrances(() => now);
  pending.add("a");
  pending.delete("a");
  expect(pending.has("a")).toBe(false);
  pending.add("b");
  pending.clear();
  expect(pending.has("b")).toBe(false);
});

test("the pending set stays bounded while the reader stays away and rows keep arriving", () => {
  let now = 0;
  const pending = new PendingEntrances(() => now);
  for (let index = 0; index < 10_000; index += 1) {
    now += 50;
    pending.add(`row-${index}`);
  }
  expect(pending.size).toBeLessThanOrEqual(65);
});
