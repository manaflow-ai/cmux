// The web UI perf harness lists rows slowest first relative to their target (bench/web-ui-suite.ts); a row whose
// target is 0 (a layout shift or an idle wakeup count, bench/stability.ts) is over it whenever it is above 0.
import { describe, expect, test } from "bun:test";
import { overTarget, slowestFirst } from "../bench/web-ui-suite";

describe("web-ui-suite slowestFirst", () => {
  test("a target of 0 ranks above every finite ratio once missed, and with the met rows when met", () => {
    const rows = [
      { name: "a.settled", p95: 150, target: 100 },
      { name: "b.idle_wakeups", p95: 3, target: 0 },
      { name: "c.cls", p95: 0, target: 0 },
      { name: "d.long_ms", p95: 40 },
      { name: "e.latest", p95: 50, target: 100 },
    ];
    expect(slowestFirst(rows).map((row) => row.name)).toEqual([
      "b.idle_wakeups",
      "a.settled",
      "e.latest",
      "c.cls",
      "d.long_ms",
    ]);
    expect(overTarget({ name: "x", p95: 0, target: 0 })).toBe(0);
    expect(overTarget({ name: "x", p95: 1 })).toBe(-1);
  });
});
