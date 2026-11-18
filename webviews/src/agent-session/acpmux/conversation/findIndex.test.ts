// Find in Chat over the whole transcript (findIndex.ts): which daemon hits count, where they go
// among the loaded matches, and which match stands for a hit once its turn is loaded.
import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import type { FindMatch } from "./chatFind";
import {
  findSteps,
  hitKey,
  hitLoaded,
  landedStep,
  mergeHits,
  nearestStep,
  readAnswer,
  rowsWindow,
  type IndexHit,
} from "./findIndex";
import { revealedFind } from "./findReveal";

const row = (id: string, at: number, text = ""): AcpmuxRow => ({ id, version: 1, at, kind: "user", text });
const match = (rowIndex: number, rowId: string, occurrence = 0): FindMatch => ({ rowIndex, rowId, occurrence });

describe("readAnswer", () => {
  test("reads the daemon's hits and total, skipping hits with no time", () => {
    expect(
      readAnswer({
        hits: [
          { at: 5, seq: 9, messageId: "m1", line: 3, matchStart: 2, role: "user", snippet: "a retry", inWindow: true },
          { seq: 10 },
          { at: 7 },
        ],
        total: 41,
      }),
    ).toEqual({
      hits: [
        { at: 5, seq: 9, messageId: "m1", line: 3, matchStart: 2, role: "user", snippet: "a retry", inWindow: true },
        { at: 7 },
      ],
      total: 41,
    });
  });
  test("an answer with no hits list is none", () => {
    expect(readAnswer({ error: "x" })).toBeUndefined();
    expect(readAnswer(undefined)).toBeUndefined();
  });
});

describe("mergeHits", () => {
  test("puts several answers in transcript order, each hit once (an older acpmux answers newest first)", () => {
    const a: IndexHit = { at: 30, seq: 3 };
    const b: IndexHit = { at: 10, seq: 1 };
    const c: IndexHit = { at: 20, seq: 2 };
    expect(mergeHits([a, b], [b, c]).map((hit) => hit.seq)).toEqual([1, 2, 3]);
  });
  test("two hits in one line are told apart by where they match", () => {
    const first: IndexHit = { at: 10, seq: 1, matchStart: 0 };
    const second: IndexHit = { at: 10, seq: 1, matchStart: 8 };
    expect(hitKey(first)).not.toBe(hitKey(second));
    expect(mergeHits([second, first])).toEqual([first, second]);
  });
});

describe("hitLoaded", () => {
  const rows = [row("r1", 100), row("r2", 200)];
  test("by seq when the daemon placed the hit in the chat's log", () => {
    const holdsSeq = (seq: number) => seq >= 50;
    expect(hitLoaded({ at: 0, seq: 49 }, rows, { holdsSeq })).toBe(false);
    expect(hitLoaded({ at: 0, seq: 50 }, rows, { holdsSeq })).toBe(true);
  });
  test("by its message's rows, else by the oldest loaded row's time", () => {
    const rowsOfMessage = (id: string) => (id === "held" ? ["r1"] : []);
    expect(hitLoaded({ at: 10, messageId: "held" }, rows, { rowsOfMessage })).toBe(true);
    expect(hitLoaded({ at: 10, messageId: "older" }, rows, { rowsOfMessage })).toBe(false);
    expect(hitLoaded({ at: 150 }, rows, {})).toBe(true);
    expect(hitLoaded({ at: 99 }, rows, {})).toBe(false);
  });
  test("nothing is loaded in a chat with no rows", () => {
    expect(hitLoaded({ at: 10 }, [], {})).toBe(false);
  });
});

describe("findSteps", () => {
  const rows = [row("r1", 100), row("r2", 200), row("r3", 300)];
  test("a hit goes before the first loaded match whose row is newer", () => {
    const steps = findSteps(
      [match(0, "r1"), match(2, "r3")],
      rows,
      [{ at: 10, seq: 1 }, { at: 250, seq: 2 }, { at: 400, seq: 3 }],
    );
    expect(steps.map((step) => (step.match ? step.match.rowId : `seq${step.hit!.seq}`))).toEqual([
      "seq1",
      "r1",
      "seq2",
      "r3",
      "seq3",
    ]);
    expect(steps[1]!.match && steps[1]!.matchIndex).toBe(0);
    expect(steps[3]!.match && steps[3]!.matchIndex).toBe(1);
  });
  test("with no index the steps are the loaded matches", () => {
    expect(findSteps([match(1, "r2")], rows, []).map((step) => step.key)).toEqual(["r2#0"]);
  });
});

describe("nearestStep and landedStep", () => {
  const rows = [row("r1", 1_000), row("r2", 2_000), row("r3", 900_000)];
  const steps = findSteps([match(0, "r1"), match(1, "r2"), match(2, "r3")], rows, [{ at: 500, seq: 1 }]);
  test("the step nearest a reveal's time", () => {
    expect(nearestStep(steps, 600)).toBe(0);
    expect(nearestStep(steps, 1_900)).toBe(2);
    expect(nearestStep([], 1)).toBe(-1);
  });
  test("a landed hit hands its place to a row of its message", () => {
    const landed = findSteps([match(0, "r1"), match(1, "r2"), match(2, "r3")], rows, []);
    expect(landedStep(landed, { at: 1, messageId: "m" }, (id) => (id === "m" ? ["r2"] : []))).toBe(1);
  });
  test("else to the first match no older than it, else the nearest", () => {
    const landed = findSteps([match(0, "r1"), match(1, "r2"), match(2, "r3")], rows, []);
    expect(landedStep(landed, { at: 1_500 })).toBe(1);
    // Nothing within a few minutes after it: the nearest stands in.
    expect(landedStep(landed, { at: 100_000 })).toBe(1);
    expect(landedStep([], { at: 1 })).toBe(-1);
  });
});

test("rowsWindow is the time span of the rows on screen", () => {
  const rows = [row("r1", 100), row("r2", 200), row("r3", 300)];
  expect(rowsWindow(rows, ["r2", "r3"])).toEqual({ fromMs: 200, toMs: 300 });
  expect(rowsWindow(rows, [])).toBeUndefined();
  expect(rowsWindow(rows, null)).toBeUndefined();
});

describe("revealedFind", () => {
  test("reads `find:<atMs>:<query>`, the query as written", () => {
    expect(revealedFind("find:1700000000000:retry: loop")).toEqual({ query: "retry: loop", atMs: 1_700_000_000_000 });
    expect(revealedFind("find::Retry")).toEqual({ query: "Retry" });
  });
  test("anything else is no find", () => {
    expect(revealedFind("said:prompt:retry")).toBeUndefined();
    expect(revealedFind("find:12:   ")).toBeUndefined();
    expect(revealedFind("find:soon:retry")).toBeUndefined();
    expect(revealedFind("find:retry")).toBeUndefined();
  });
});
