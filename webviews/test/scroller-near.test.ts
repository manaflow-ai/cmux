// Lawrence 2026-10-23 (msg 11494): scrollbars grow near the pointer and fade at rest. The pure
// parts of scrollers.ts: when the pointer is near a scroller's trailing edge, and which scrolls
// show a fading chat thumb (the transcript following new rows does not). The painted behavior is
// in scroller-near-grow.test.ts (browser lane).
import { describe, expect, test } from "bun:test";
import {
  MINIMAL_SCROLLER_ATTRIBUTE,
  NEAR_PX,
  SCROLLING_HIDE_MS,
  SHOWN_SCROLLER_ATTRIBUTE,
  isUserScroll,
  nearBottomEdge,
  nearTrailingEdge,
} from "../src/scrollers";

/** An element with only the given attributes, for `isUserScroll`. */
function element(...attributes: string[]): Element {
  return { hasAttribute: (name: string) => attributes.includes(name) } as unknown as Element;
}

describe("near the trailing edge", () => {
  const box = { left: 100, right: 300, top: 0, bottom: 200 };
  test("within NEAR_PX of the right edge, inside the box, is near", () => {
    expect(nearTrailingEdge(box, 300, 50)).toBe(true);
    expect(nearTrailingEdge(box, 300 - NEAR_PX, 50)).toBe(true);
    expect(nearTrailingEdge(box, 300 - NEAR_PX - 1, 50)).toBe(false);
    expect(nearTrailingEdge(box, 301, 50)).toBe(false);
    expect(nearTrailingEdge(box, 295, 201)).toBe(false);
  });
  test("a box narrower than NEAR_PX is near only inside itself", () => {
    expect(nearTrailingEdge({ left: 290, right: 300, top: 0, bottom: 10 }, 285, 5)).toBe(false);
  });
});

describe("near the bottom edge (a sideways bar)", () => {
  const box = { left: 0, right: 400, top: 100, bottom: 300 };
  test("within NEAR_PX above the bottom edge, inside the box, is near", () => {
    expect(nearBottomEdge(box, 200, 300)).toBe(true);
    expect(nearBottomEdge(box, 200, 300 - NEAR_PX)).toBe(true);
    expect(nearBottomEdge(box, 200, 300 - NEAR_PX - 1)).toBe(false);
    expect(nearBottomEdge(box, 200, 301)).toBe(false);
    expect(nearBottomEdge(box, 401, 295)).toBe(false);
  });
});

describe("a scroll the user made", () => {
  test("any scroll counts on an ordinary scroller", () => {
    expect(isUserScroll(element(), undefined, 10_000)).toBe(true);
  });
  for (const attribute of [SHOWN_SCROLLER_ATTRIBUTE, MINIMAL_SCROLLER_ATTRIBUTE]) {
    test(`${attribute}: only right after a wheel, key or button`, () => {
      expect(isUserScroll(element(attribute), undefined, 10_000)).toBe(false);
      expect(isUserScroll(element(attribute), 10_000 - SCROLLING_HIDE_MS - 1, 10_000)).toBe(false);
      expect(isUserScroll(element(attribute), 10_000 - 100, 10_000)).toBe(true);
    });
  }
});
