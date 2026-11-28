// The edited-files card's file stack scrolls where the reader is looking (stackWheel.ts): the transcript
// brings the card into view first, then the stack scrolls, then the rest goes on to the transcript.
import { expect, test } from "bun:test";
import { splitWheel } from "./stackWheel";

// The transcript's view, above the composer, and the stack with room both ways.
const VIEW = { top: 0, bottom: 600 };

test("a card half under the composer comes into view before its stack scrolls", () => {
  // Its bottom is 108px under the view's foot (with the 8px edge room).
  expect(splitWheel(40, { top: 300, bottom: 700 }, VIEW, 500)).toEqual({ bring: 40, stack: 0, after: 0 });
  expect(splitWheel(150, { top: 300, bottom: 700 }, VIEW, 500)).toEqual({ bring: 108, stack: 42, after: 0 });
});

test("a card cut at the top comes into view scrolling up", () => {
  expect(splitWheel(-30, { top: -50, bottom: 400 }, VIEW, 200)).toEqual({ bring: -30, stack: 0, after: 0 });
  expect(splitWheel(-100, { top: -50, bottom: 400 }, VIEW, 200)).toEqual({ bring: -58, stack: -42, after: 0 });
});

test("a card in full view scrolls its stack, then hands the rest on at the stack's end", () => {
  expect(splitWheel(60, { top: 100, bottom: 500 }, VIEW, 500)).toEqual({ bring: 0, stack: 60, after: 0 });
  expect(splitWheel(60, { top: 100, bottom: 500 }, VIEW, 20)).toEqual({ bring: 0, stack: 20, after: 40 });
  expect(splitWheel(-60, { top: 100, bottom: 500 }, VIEW, 0)).toEqual({ bring: 0, stack: 0, after: -60 });
});

test("a card taller than the view is never pushed past its other edge", () => {
  // Its top is already at the view's top: going down, the stack scrolls instead.
  expect(splitWheel(80, { top: 8, bottom: 900 }, VIEW, 500)).toEqual({ bring: 0, stack: 80, after: 0 });
  // Brought down only until its top reaches the view's top.
  expect(splitWheel(80, { top: 38, bottom: 900 }, VIEW, 500)).toEqual({ bring: 30, stack: 50, after: 0 });
});
