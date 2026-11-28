import { describe, expect, test } from "bun:test";
import { holdSettle, releaseSettle, settledRead, whenSettled } from "./paneSettle";

describe("paneSettle", () => {
  test("a store's news waits for the pending draw, the newest per key", () => {
    const owner = {};
    const heard: string[] = [];
    holdSettle(owner);
    whenSettled("a", () => heard.push("a1"));
    whenSettled("a", () => heard.push("a2"));
    whenSettled("b", () => heard.push("b"));
    expect(heard).toEqual([]);
    releaseSettle(owner);
    expect(heard).toEqual(["a2", "b"]);
    whenSettled("a", () => heard.push("now"));
    expect(heard).toEqual(["a2", "b", "now"]);
  });

  test("a read keeps its value while a draw is pending", () => {
    const owner = {};
    let value = 1;
    const read = settledRead(() => value);
    expect(read()).toBe(1);
    holdSettle(owner);
    value = 2;
    expect(read()).toBe(1);
    expect(settledRead(() => value)()).toBe(2);
    releaseSettle(owner);
    expect(read()).toBe(2);
  });

  test("with frames, a frame's notifies run once at that frame, the newest per key", () => {
    const frames: Array<() => void> = [];
    const scope = globalThis as { requestAnimationFrame?: unknown; cancelAnimationFrame?: unknown };
    scope.requestAnimationFrame = (run: () => void) => frames.push(run);
    scope.cancelAnimationFrame = () => {};
    try {
      const heard: string[] = [];
      for (let chunk = 1; chunk <= 5; chunk += 1) whenSettled("stream", () => heard.push(`stream${chunk}`));
      whenSettled("rows", () => heard.push("rows"));
      expect(heard).toEqual([]);
      expect(frames.length).toBe(1);
      frames.shift()!();
      expect(heard).toEqual(["stream5", "rows"]);
      // A draw that begins before the frame holds them to its commit.
      const owner = {};
      whenSettled("stream", () => heard.push("later"));
      holdSettle(owner);
      frames.shift()!();
      expect(heard).toEqual(["stream5", "rows"]);
      releaseSettle(owner);
      expect(heard).toEqual(["stream5", "rows", "later"]);
    } finally {
      delete scope.requestAnimationFrame;
      delete scope.cancelAnimationFrame;
    }
  });

  test("with frames that stop, a notify still runs", async () => {
    const scope = globalThis as { requestAnimationFrame?: unknown; cancelAnimationFrame?: unknown };
    scope.requestAnimationFrame = () => 1;
    scope.cancelAnimationFrame = () => {};
    try {
      const heard: string[] = [];
      whenSettled("stream", () => heard.push("late"));
      expect(heard).toEqual([]);
      await new Promise((done) => setTimeout(done, 150));
      expect(heard).toEqual(["late"]);
    } finally {
      delete scope.requestAnimationFrame;
      delete scope.cancelAnimationFrame;
    }
  });
});
