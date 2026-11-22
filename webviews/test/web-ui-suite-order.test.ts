// The web UI perf harness lists rows slowest first relative to their target (bench/web-ui-suite.ts); a row whose
// target is 0 (a layout shift or an idle wakeup count, bench/stability.ts) is over it whenever it is above 0.
import { describe, expect, test } from "bun:test";
import { BENCHES, failureTail, overTarget, slowestFirst, SUITE_CAP_MS } from "../bench/web-ui-suite";
import { PERF_ROW_MARK } from "../bench/perfRow";

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

// A failed bench's report entry says why: state-growth printed its FAIL lines on stdout and nothing on stderr, and the
// suite kept only stderr, so the perf cron saw "state-growth: exit 1" with an empty tail (run 43331891010).
describe("web-ui-suite failureTail", () => {
  test("a bench that explains itself on stdout only still leaves its reason in the tail", () => {
    const stdout = [
      "chat-reopen small ops 120  FAIL",
      "  heap 4614 B/op over its band 4096",
      `${PERF_ROW_MARK}{"name":"x","p95":1}`,
      "",
    ].join("\n");
    expect(failureTail(stdout, "", [])).toEqual([
      "chat-reopen small ops 120  FAIL",
      "  heap 4614 B/op over its band 4096",
    ]);
  });

  test("malformed rows, then stdout, then stderr, each bounded", () => {
    const stdout = Array.from({ length: 20 }, (_, i) => `out ${i}`).join("\n");
    const stderr = Array.from({ length: 20 }, (_, i) => `err ${i}`).join("\n");
    const tail = failureTail(stdout, stderr, [`${PERF_ROW_MARK}{bad`]);
    expect(tail[0]).toBe(`${PERF_ROW_MARK}{bad`);
    expect(tail.slice(1, 9)).toEqual(Array.from({ length: 8 }, (_, i) => `out ${i + 12}`));
    expect(tail.slice(9)).toEqual(Array.from({ length: 12 }, (_, i) => `err ${i + 8}`));
  });
});

// A bench's timeout raised past the suite's cap would let perf-cron.py kill the whole suite with no report at all.
describe("web-ui-suite timeouts", () => {
  test("the benches the suite runs by default fit perf-cron.py's cap on it", () => {
    const sum = BENCHES.filter((bench) => !bench.ownPart).reduce((total, bench) => total + bench.timeoutMs, 0);
    expect(sum).toBeLessThanOrEqual(SUITE_CAP_MS);
  });
});
