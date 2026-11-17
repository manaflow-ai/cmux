// The flicker log's `first-load` record (firstLoadWatch.ts): a chat page's first load judged in the field
// as the first-load bench judges it, with no row id or chat text in what it sends.
import { describe, expect, test } from "bun:test";
import type { FrameRecord, FrameRow } from "./firstLoadFrames";
import { firstLoadFields } from "./firstLoadWatch";

const ROWS: FrameRow[] = [
  { id: "user-117", top: 120 },
  { id: "assistant-118", top: 260 },
];
const COMPOSER = { top: 680, height: 96 };
const frame = (t: number, overrides: Partial<FrameRecord> = {}): FrameRecord => ({
  t,
  copyShown: false,
  rows: ROWS,
  composer: COMPOSER,
  scrollTop: 4000,
  ...overrides,
});

describe("first-load record", () => {
  test("a copy that the live page replaces in place records no shift, settled at its first frame", () => {
    expect(
      firstLoadFields([frame(40, { copyShown: true }), frame(56, { copyShown: true }), frame(72), frame(88)]),
    ).toEqual({
      copy: true,
      frames: 4,
      first: 40,
      settled: 40,
      shifts: 0,
      blank: 0,
      why: "",
    });
  });

  test("a composer that moves after the first paint counts, by kind only", () => {
    const fields = firstLoadFields([
      frame(40),
      frame(56, { composer: { top: 640, height: 136 } }),
      frame(72, { composer: { top: 640, height: 136 } }),
    ]);
    expect(fields?.shifts).toBe(1);
    expect(fields?.settled).toBe(56);
    expect(fields?.why).toBe("composer top");
  });

  test("a bottom row replaced names no row id", () => {
    const fields = firstLoadFields([frame(40), frame(56, { rows: [{ id: "assistant-200", top: 300 }] })]);
    expect(fields?.why).toBe("bottom row replaced");
    expect(JSON.stringify(fields)).not.toContain("assistant");
  });

  test("a load that never painted content records nothing", () => {
    expect(firstLoadFields([frame(40, { rows: [] }), frame(56, { rows: [] })])).toBeUndefined();
  });
});
