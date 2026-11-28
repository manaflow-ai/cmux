import { describe, expect, test } from "bun:test";
import type { ConversationLayout } from "../model";
import { heldWarmAnchor, warmAnchor, warmAnchorTop } from "./scrollAnchors";

// Leo: "we need to be able to have infinite chats, infinitely long chats, that sort of thing on, you
// know, current day hardware". A fling through a 100,000-row chat mounted 105 rows a frame against 18 in
// a 1,000-row one: once an older page landed and the window let the newer pages go, the warm rows' held
// place named a row no longer there, and the warm rows followed the live offset every frame.

/// `count` rows, each `pitch` px tall, back to back.
function rowsOf(count: number, pitch: number): ConversationLayout {
  const tops = new Float64Array(count);
  const heights = new Float64Array(count).fill(pitch);
  for (let at = 0; at < count; at += 1) tops[at] = at * pitch;
  return { tops, heights, totalHeight: count * pitch };
}

const PITCH = 40;
const STEP = 400;
const ids = (from: number, count: number) => Array.from({ length: count }, (_, at) => ({ id: `row-${from + at}` }));

describe("heldWarmAnchor", () => {
  test("a held place whose row is still shown stays held", () => {
    const shown = ids(0, 1000);
    const layout = rowsOf(1000, PITCH);
    const held = warmAnchor(layout, shown, 30_000, STEP);
    expect(heldWarmAnchor(layout, shown, held)).toBe(held);
  });

  test("older history paged in above moves the row, not the hold", () => {
    const layout = rowsOf(1000, PITCH);
    const held = warmAnchor(layout, ids(500, 1000), 10_000, STEP);
    // 300 older rows land above; the window lets the 300 newest go. The held row is now at another index.
    const paged = ids(200, 1000);
    expect(heldWarmAnchor(layout, paged, held)).toBe(held);
    expect(warmAnchorTop(layout, paged, held)).toBe(10_000 + 300 * PITCH);
  });

  test("a held place whose row the window let go is held as no place, which has no offset", () => {
    const layout = rowsOf(1000, PITCH);
    // Held near the newest rows; then pages land above until those rows leave the window.
    const held = warmAnchor(layout, ids(1000, 1000), 38_000, STEP);
    const paged = ids(0, 1000);
    expect(warmAnchorTop(layout, paged, held)).toBeUndefined();
    const kept = heldWarmAnchor(layout, paged, held);
    expect(kept).toBe("");
    // No place is looked for again: it stays no place, and names no offset to build warm rows at.
    expect(heldWarmAnchor(layout, paged, kept)).toBe("");
    expect(warmAnchorTop(layout, paged, kept)).toBeUndefined();
  });
});
