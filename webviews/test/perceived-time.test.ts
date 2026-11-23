// The per pull request perceived-time gate (bench/perceived-time.ts): which numbers regress, which are noise, and that
// every key state names its visible, settled and interactive rows (or says it has none).
import { describe, expect, test } from "bun:test";
import { judge, markdown, parseRows, quantile, roundsOf, STATES, WAIVER } from "../bench/perceived-time";
import { PERF_ROW_MARK } from "../bench/perfRow";

const base = [400, 410, 405, 395, 402, 398, 407, 401, 399, 404];

describe("perceived-time judge", () => {
  test("a head slower in most rounds, past the ratio and the floor, regresses", () => {
    const head = base.map((v) => v + 120);
    expect(judge("settled", "r", base, head, 40).verdict).toBe("regressed");
  });

  test("within the ratio or the floor is a pass", () => {
    expect(
      judge(
        "settled",
        "r",
        base,
        base.map((v) => v + 30),
        40,
      ).verdict,
    ).toBe("pass");
    // 15 % of a 50 ms number is 7.5 ms; the 25 ms floor holds a 20 ms change as noise.
    const small = [50, 52, 49, 51, 50];
    expect(
      judge(
        "visible",
        "r",
        small,
        small.map((v) => v + 20),
        25,
      ).verdict,
    ).toBe("pass");
  });

  test("one or two slow head rounds do not regress (the head's lower quartile must be over the base median)", () => {
    const head = [...base.slice(0, 7), 2000, 2000, 2000, 2000, 2000];
    expect(judge("visible", "r", base, head, 40).verdict).toBe("pass");
    const outliers = [...base.slice(0, 8), 3000, 3000];
    expect(judge("visible", "r", base, outliers, 40).verdict).toBe("pass");
  });

  test("a clear speed-up says faster", () => {
    expect(
      judge(
        "visible",
        "r",
        base,
        base.map((v) => v - 150),
        40,
      ).verdict,
    ).toBe("faster");
  });

  test("no row, no base and a missing head row each say so", () => {
    expect(judge("interactive", null, [], [], 25).verdict).toBe("no row");
    expect(judge("visible", "r", [], [400], 25).verdict).toBe("no base");
    expect(judge("visible", "r", base, [], 25).verdict).toBe("head missing");
    // Broken in both trees is not this change's failure.
    expect(judge("visible", "r", [], [], 25).verdict).toBe("unmeasured");
  });
});

describe("perceived-time rows", () => {
  test("rounds come from samples, else the row's median", () => {
    expect(roundsOf({ name: "a", p50: 3, p95: 4, samples: [1, 2] })).toEqual([1, 2]);
    expect(roundsOf({ name: "a", p50: 3, p95: 4 })).toEqual([3]);
    expect(roundsOf({ name: "a", p95: 4 })).toEqual([4]);
  });

  test("parseRows keeps well-formed rows only", () => {
    const out = [`${PERF_ROW_MARK}{"name":"a.b","p95":1}`, `${PERF_ROW_MARK}{bad`, "noise"].join("\n");
    expect(parseRows(out).map((r) => r.name)).toEqual(["a.b"]);
  });

  test("quantile interpolates between ranks", () => {
    expect(quantile([1, 2, 3, 4], 0.25)).toBeCloseTo(1.75);
    expect(quantile([5], 0.75)).toBe(5);
  });

  test("every state names a row or null for visible, settled and interactive, and visible and settled exist", () => {
    for (const state of STATES) {
      expect(Object.keys(state.rows).sort()).toEqual(["interactive", "settled", "visible"]);
      expect(state.rows.visible).toBeTruthy();
      expect(state.rows.settled).toBeTruthy();
      expect(state.floorMs).toBeGreaterThan(0);
    }
    expect(STATES.some((state) => state.rows.interactive)).toBe(true);
  });

  test("the waiver is a description line of its own", () => {
    expect(WAIVER.test("fix\nperceived-time: the new pane is worth 30 ms\n")).toBe(true);
    expect(WAIVER.test("perceived-time:\n")).toBe(false);
    expect(WAIVER.test("we measured perceived-time: fine")).toBe(false);
  });

  test("the table marks a regression and says how to accept it", () => {
    const state = STATES[0];
    const regressed = judge(
      "settled",
      state.rows.settled,
      base,
      base.map((v) => v + 200),
      state.floorMs,
    );
    const text = markdown([{ state, judgements: [regressed], blocks: 2 }], "a".repeat(40), "b".repeat(40), false);
    expect(text).toContain("**regressed**");
    expect(text).toContain("perceived-time: <why");
  });
});
