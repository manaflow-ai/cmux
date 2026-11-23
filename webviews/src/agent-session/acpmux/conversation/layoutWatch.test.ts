// The motion model's watcher (layoutWatch.ts; docs/design/transcript-motion-model.md, "The watcher"):
// a move no transition declared is flagged, a declared one, a follow scroll and input are not (Leo:
// "all this shift stuff is so goofy like we should be able to have a system that just detects when
// things are coming in or out").
import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  clockSeconds,
  type Expectation,
  judgeFrame,
  leftovers,
  newJudgeState,
  type RowBox,
  type WatchFrame,
} from "./layoutWatch";

const frame = (
  n: number,
  rows: [string, Partial<RowBox> & { top: number; height: number }][],
  extra: Partial<WatchFrame> = {},
): WatchFrame => ({
  frame: n,
  at: 1000 + n * 16,
  scrollTop: 0,
  order: rows.map(([id]) => id),
  rows: new Map(rows.map(([id, box]) => [id, box as RowBox])),
  lastRowId: rows.at(-1)?.[0],
  streaming: false,
  ...extra,
});
const quiet = (expects: Expectation[] = []) => ({ inputAt: -10_000, expects, state: newJudgeState() });
const three = (n: number, bTop = 50) =>
  frame(n, [
    ["a", { top: 0, height: 40 }],
    ["b", { top: bTop, height: 40 }],
    ["c", { top: bTop + 50, height: 40 }],
  ]);

describe("clockSeconds", () => {
  test("reads the transcript's clock shapes", () => {
    expect(clockSeconds("14h 53m")).toBe(14 * 3600 + 53 * 60);
    expect(clockSeconds("1m 05s")).toBe(65);
    expect(clockSeconds("12s")).toBe(12);
    expect(clockSeconds("1:05")).toBe(65);
    expect(clockSeconds("soon")).toBeUndefined();
  });
});

describe("judgeFrame", () => {
  test("a still frame flags nothing", () => {
    expect(judgeFrame(three(1), three(2), quiet())).toEqual([]);
  });
  test("an undeclared move of a visible row is I2", () => {
    const flags = judgeFrame(three(1), three(2, 80), quiet());
    expect(flags.map((f) => [f.rowId, f.invariant])).toContainEqual(["b", "I2"]);
  });
  test("a declared move of named rows is not flagged", () => {
    const declared: Expectation = { reason: "disclosure", rows: new Set(["b", "c"]), from: 0, until: 1e9 };
    expect(judgeFrame(three(1), three(2, 80), quiet([declared]))).toEqual([]);
  });
  test("the anchor of a declared move leaving its pixel is flagged", () => {
    const declared: Expectation = { reason: "disclosure", rows: new Set(["c"]), anchorRow: "b", from: 0, until: 1e9 };
    const flags = judgeFrame(three(1), three(2, 80), quiet([declared]));
    expect(flags.some((f) => f.rowId === "b" && f.invariant === "I2" && f.detail?.includes("anchor"))).toBe(true);
  });
  test("input in the grace window explains a move", () => {
    const next = three(2, 80);
    expect(judgeFrame(three(1), next, { ...quiet(), inputAt: next.at - 50 })).toEqual([]);
  });
  test("a row unmounted and mounted again within three frames is I6", () => {
    const state = newJudgeState();
    const opts = { inputAt: -10_000, expects: [], state };
    const gone = frame(2, [
      ["a", { top: 0, height: 40 }],
      ["c", { top: 50, height: 40 }],
    ]);
    judgeFrame(three(1), gone, opts);
    const flags = judgeFrame(gone, three(3), opts);
    expect(flags.some((f) => f.rowId === "b" && f.invariant === "I6")).toBe(true);
  });
  test("a blank band between rows is I3", () => {
    const next = frame(2, [
      ["a", { top: 0, height: 40 }],
      ["b", { top: 200, height: 40 }],
    ]);
    expect(judgeFrame(undefined, next, quiet()).some((f) => f.invariant === "I3")).toBe(true);
  });
  test("a clock running backwards is I9", () => {
    const state = newJudgeState();
    const opts = { inputAt: -10_000, expects: [], state };
    judgeFrame(undefined, frame(1, [["t", { top: 0, height: 20, clockText: "1m 05s" }]]), opts);
    const flags = judgeFrame(undefined, frame(2, [["t", { top: 0, height: 20, clockText: "59s" }]]), opts);
    expect(flags.some((f) => f.invariant === "I9")).toBe(true);
  });
  test("a streaming last row growing is no move", () => {
    const grow = (n: number, h: number) =>
      frame(
        n,
        [
          ["a", { top: 0, height: 40 }],
          ["z", { top: 50, height: h }],
        ],
        { streaming: true },
      );
    const state = newJudgeState();
    const opts = { inputAt: -10_000, expects: [], state };
    judgeFrame(grow(1, 40), grow(2, 60), opts);
    expect(judgeFrame(grow(2, 60), grow(3, 80), opts)).toEqual([]);
  });
  test("a row resizing on consecutive frames outside streaming is I5", () => {
    const sized = (n: number, h: number) =>
      frame(n, [
        ["a", { top: 0, height: h }],
        ["b", { top: 300, height: 40 }],
      ]);
    const state = newJudgeState();
    const opts = { inputAt: -10_000, expects: [], state };
    judgeFrame(sized(1, 40), sized(2, 60), opts);
    expect(judgeFrame(sized(2, 60), sized(3, 80), opts).some((f) => f.invariant === "I5")).toBe(true);
  });
});

describe("leftovers (I4)", () => {
  test("flags an inline transform, a fold height, and a ghost", () => {
    const { document } = new JSDOM(
      `<div id="r"><div class="acpmux-row" data-row-id="a" style="transform: translateY(4px)"></div>` +
        `<div class="acpmux-row" data-row-id="b"><div class="cv-fold" style="height: 20px"></div></div>` +
        `<div class="acpmux-row acpmux-row--fold-ghost" data-row-id="c"></div>` +
        `<div class="acpmux-row" data-row-id="d"></div></div>`,
    ).window;
    const flags = leftovers(document.getElementById("r")!);
    expect(flags.map((f) => f.rowId).sort()).toEqual(["a", "b", "c"]);
    expect(flags.every((f) => f.invariant === "I4")).toBe(true);
  });
});
