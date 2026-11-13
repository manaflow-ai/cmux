import { describe, expect, test } from "bun:test";
import { ENTRANCE_HELD_ATTR, holdEntranceForFirstFrame } from "./entranceClock";

function frames() {
  const queued = new Map<number, () => void>();
  let next = 1;
  return {
    queued,
    request: (run: () => void) => {
      queued.set(next, run);
      return next++;
    },
    cancel: (handle: number) => void queued.delete(handle),
    flush: () => {
      const runs = [...queued.values()];
      queued.clear();
      for (const run of runs) run();
    },
  };
}

function row() {
  const attrs = new Set<string>();
  return {
    hasAttribute: (name: string) => attrs.has(name),
    setAttribute: (name: string) => void attrs.add(name),
    removeAttribute: (name: string) => void attrs.delete(name),
    held: () => attrs.has(ENTRANCE_HELD_ATTR),
  } as unknown as Element & { held: () => boolean };
}

describe("holdEntranceForFirstFrame", () => {
  test("keeps the row held until the next frame, then releases it", () => {
    const node = row();
    const clock = frames();
    holdEntranceForFirstFrame(node, clock);
    expect(node.held()).toBe(true);
    clock.flush();
    expect(node.held()).toBe(false);
  });

  test("cancelling an unmount removes the hold and queued frame", () => {
    const node = row();
    const clock = frames();
    const cancel = holdEntranceForFirstFrame(node, clock);
    cancel();
    expect(node.held()).toBe(false);
    expect(clock.queued.size).toBe(0);
  });
});
