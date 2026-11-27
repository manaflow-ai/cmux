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
});
