// Lawrence 2026-11-20 (msg 42498): "for scrollbar, it is possible for me to hover close, and for the
// width to change, but after i mousedown and drag, it fails to scroll. fix so we get it pixel
// perfect". The page marked a scroller near (its thumb widens, `NEAR_ATTRIBUTE`) 20 px from its
// trailing edge, but WebKit takes a press on a scrollbar only on the scrollbar's own lane (8 px for
// the shared thin one): a press on the 12 px between went to the content and dragged nothing. Every
// pixel column from the edge in: the pointer is near exactly where a press lands on the scrollbar.
// The drag itself, in a real engine, is scroller-grab-zone-browser.test.ts (browser lane).
import { describe, expect, test } from "bun:test";
import { nearScroller } from "../src/scrollers";

type Axis = "y" | "x";

/** A 200 x 200 box at x 100 whose content overflows on `axis`, with a scrollbar lane `lane` px thick
    (0: an overlay scrollbar, which takes no layout and draws and hit-tests itself). */
function box(axis: Axis, lane: number, border = 0): Element {
  const px = `${border}px`;
  const style = {
    overflowY: axis === "y" ? "auto" : "hidden",
    overflowX: axis === "x" ? "auto" : "hidden",
    borderTopWidth: px,
    borderRightWidth: px,
    borderBottomWidth: px,
    borderLeftWidth: px,
  };
  const document = { defaultView: { getComputedStyle: () => style, innerWidth: 1000, innerHeight: 1000 } } as Record<
    string,
    unknown
  >;
  document.documentElement = {};
  const inner = 200 - 2 * border;
  return {
    ownerDocument: document,
    getBoundingClientRect: () => ({ left: 100, top: 0, right: 300, bottom: 200, width: 200, height: 200 }),
    offsetWidth: 200,
    offsetHeight: 200,
    clientWidth: axis === "y" ? inner - lane : inner,
    clientHeight: axis === "x" ? inner - lane : inner,
    scrollWidth: axis === "x" ? 2000 : inner - (axis === "y" ? lane : 0),
    scrollHeight: axis === "y" ? 2000 : inner - (axis === "x" ? lane : 0),
  } as unknown as Element;
}

/** The columns (a sideways bar: rows), counted from the box's outer edge in, where the pointer is near. */
function nearColumns(element: Element, axis: Axis): number[] {
  const near: number[] = [];
  for (let column = 0; column < 200; column += 1) {
    const x = axis === "y" ? 300 - column - 0.5 : 200;
    const y = axis === "y" ? 100 : 200 - column - 0.5;
    if (nearScroller([element], x, y) === element) near.push(column);
  }
  return near;
}

const range = (start: number, end: number) => Array.from({ length: end - start }, (_, index) => start + index);

describe("near is exactly the scrollbar a press lands on", () => {
  for (const axis of ["y", "x"] as const)
    for (const lane of [8, 6, 15]) {
      test(`${axis === "y" ? "vertical" : "sideways"}, a ${lane} px lane: near on its ${lane} columns, nowhere else`, () => {
        expect(nearColumns(box(axis, lane), axis)).toEqual(range(0, lane));
      });
    }

  test("a border moves the lane in by its width", () => {
    expect(nearColumns(box("y", 8, 2), "y")).toEqual(range(2, 10));
  });

  test("an overlay scrollbar (no lane) is never marked: the engine draws and widens its own", () => {
    expect(nearColumns(box("y", 0), "y")).toEqual([]);
    expect(nearColumns(box("x", 0), "x")).toEqual([]);
  });
});
