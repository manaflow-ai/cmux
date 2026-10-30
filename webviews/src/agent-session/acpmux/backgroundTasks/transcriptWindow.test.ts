import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { WINDOW, windowRange } from "./SubagentTranscript";

const rows = (n: number): AcpmuxRow[] =>
  Array.from({ length: n }, (_, index) => ({ id: `r${index}`, version: 1, at: index, kind: "assistant", text: "x" }));

describe("windowRange", () => {
  test("with no anchor it mounts the newest window and follows the newest row", () => {
    expect(windowRange(rows(500))).toEqual({ start: 500 - WINDOW });
    expect(windowRange(rows(10))).toEqual({ start: 0 });
  });

  test("around an anchor early in a long transcript it bounds both ends to one window", () => {
    const range = windowRange(rows(500), "r100");
    expect(range).toEqual({ start: 100 - Math.floor(WINDOW / 4), end: 100 - Math.floor(WINDOW / 4) + WINDOW });
  });

  test("an anchor near the newest rows follows the newest row; an unknown anchor reads as none", () => {
    expect(windowRange(rows(500), "r480")).toEqual({ start: 500 - WINDOW });
    expect(windowRange(rows(500), "missing")).toEqual({ start: 500 - WINDOW });
  });
});
