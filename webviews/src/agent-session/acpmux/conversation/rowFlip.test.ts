// The list's FLIP of the rows under a disclosure (rowFlip.ts; docs/design/transcript-motion-model.md
// rule 7, step 5): rows play from where they were drawn to their new place on one clock, only
// `translate` moves, and the end leaves no animation.
import { describe, expect, test } from "bun:test";
import { captureRowFlip, endRowFlip, playRowFlip } from "./rowFlip";
import { MOTION_MS } from "../../../motion/scale.generated";

const MS = MOTION_MS.micro;

type Move = { frames: Keyframe[]; duration: number; cancelled: boolean };
const fakeRow = (top: number) => {
  const moves: Move[] = [];
  const row = {
    offsetTop: top,
    isConnected: true,
    translateNow: 0,
    getBoundingClientRect: () => ({ top: row.offsetTop + row.translateNow }) as DOMRect,
    animate: (frames: Keyframe[], timing: KeyframeAnimationOptions) => {
      const move: Move = { frames, duration: Number(timing.duration), cancelled: false };
      moves.push(move);
      return {
        cancel: () => {
          move.cancelled = true;
        },
      } as unknown as Animation;
    },
  };
  return { row, moves, el: row as unknown as HTMLElement };
};

describe("row flip", () => {
  test("rows under an opened toggle start where they were drawn and go home on one clock", () => {
    const anchor = fakeRow(0);
    const below = fakeRow(40);
    const flip = captureRowFlip(anchor.el, [anchor.el, below.el], { now: 0, ms: MS, easing: "ease-out" })!;
    expect(flip.rows.size).toBe(1);
    below.row.offsetTop = 140; // the body took 100px in one frame
    expect(playRowFlip(flip, 10)).toBe(true);
    expect(below.moves).toHaveLength(1);
    expect(below.moves[0]!.frames).toEqual([{ translate: "0 -100px" }, { translate: "0 0" }]);
    expect(below.moves[0]!.duration).toBe(110);
    expect(anchor.moves).toHaveLength(0);
  });

  test("a scroll that holds the anchor is no move", () => {
    const anchor = fakeRow(200);
    const below = fakeRow(240);
    const flip = captureRowFlip(anchor.el, [below.el], { now: 0, ms: MS, easing: "linear" })!;
    playRowFlip(flip, 5);
    expect(below.moves).toHaveLength(0);
  });

  test("a second placement plays from where the row is drawn, inside what is left of the clock", () => {
    const anchor = fakeRow(0);
    const below = fakeRow(40);
    const flip = captureRowFlip(anchor.el, [below.el], { now: 0, ms: MS, easing: "linear" })!;
    below.row.offsetTop = 140;
    playRowFlip(flip, 0);
    below.row.translateNow = -50; // half way
    below.row.offsetTop = 160;
    playRowFlip(flip, 60);
    expect(below.moves[0]!.cancelled).toBe(true);
    expect(below.moves[1]!.frames[0]).toEqual({ translate: "0 -70px" });
    expect(below.moves[1]!.duration).toBe(60);
  });

  test("the clock's end and the settle leave no animation", () => {
    const anchor = fakeRow(0);
    const below = fakeRow(40);
    const flip = captureRowFlip(anchor.el, [below.el], { now: 0, ms: MS, easing: "linear" })!;
    below.row.offsetTop = 90;
    playRowFlip(flip, 0);
    expect(playRowFlip(flip, MS)).toBe(false);
    endRowFlip(flip);
    expect(below.moves.every((move) => move.cancelled)).toBe(true);
    expect(flip.rows.size).toBe(0);
  });

  test("no motion time (Reduce Motion, motion off) captures nothing", () => {
    const anchor = fakeRow(0);
    expect(captureRowFlip(anchor.el, [fakeRow(40).el], { now: 0, ms: 0, easing: "linear" })).toBeUndefined();
  });
});
