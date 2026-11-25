// The narrow Settings pane's category strip (components/sectionStrip.ts; first-run audit row 13): a
// wheel turned up or down scrolls it sideways, the shown category scrolls into view clear of the
// edge fade, and a strip that fits (the wide pane's column) is left alone.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { followStripWheel, revealInStrip, revealOffset, STRIP_REVEAL_INSET } from "./components/sectionStrip";

const dom = new JSDOM("<nav></nav>");
const { window } = dom;

/** A strip `clientWidth` wide over `scrollWidth` of categories, its offset kept and clamped as a browser does. */
function strip(clientWidth: number, scrollWidth: number): HTMLElement {
  const node = window.document.createElement("nav");
  let offset = 0;
  Object.defineProperties(node, {
    clientWidth: { get: () => clientWidth },
    scrollWidth: { get: () => scrollWidth },
    scrollLeft: {
      get: () => offset,
      set: (value: number) => {
        offset = Math.min(Math.max(0, scrollWidth - clientWidth), Math.max(0, value));
      },
    },
    getBoundingClientRect: { value: () => ({ left: 0, top: 0, width: clientWidth, height: 32 }) },
  });
  return node;
}

function wheel(node: HTMLElement, deltaY: number, deltaX = 0, deltaMode = 0): boolean {
  const event = new window.WheelEvent("wheel", { deltaY, deltaX, deltaMode, cancelable: true });
  node.dispatchEvent(event);
  return event.defaultPrevented;
}

test("a wheel turned down scrolls an overflowing strip sideways", () => {
  const node = strip(320, 2400);
  const stop = followStripWheel(node);
  expect(wheel(node, 120)).toBe(true);
  expect(node.scrollLeft).toBe(120);
  // A mouse that steps in lines.
  expect(wheel(node, 3, 0, 1)).toBe(true);
  expect(node.scrollLeft).toBe(168);
  expect(wheel(node, -500)).toBe(true);
  expect(node.scrollLeft).toBe(0);
  stop();
  wheel(node, 120);
  expect(node.scrollLeft).toBe(0);
});

test("at its start a wheel up passes on to the page", () => {
  const node = strip(320, 2400);
  const stop = followStripWheel(node);
  expect(wheel(node, -40)).toBe(false);
  stop();
});

test("a sideways swipe stays the browser's, and a strip that fits ignores the wheel", () => {
  const over = strip(320, 2400);
  const stopOver = followStripWheel(over);
  expect(wheel(over, 4, 60)).toBe(false);
  expect(over.scrollLeft).toBe(0);
  stopOver();
  const column = strip(220, 220);
  const stopColumn = followStripWheel(column);
  expect(wheel(column, 120)).toBe(false);
  stopColumn();
});

test("the shown category scrolls into view clear of the fade, and one in view stays put", () => {
  const view = { scrollLeft: 0, clientWidth: 320, scrollWidth: 2400 };
  // Appearance, the fourth category, cut at the right edge.
  expect(revealOffset(view, { left: 300, width: 110 })).toBe(300 + 110 + STRIP_REVEAL_INSET - 320);
  // A category left of the view.
  expect(revealOffset({ ...view, scrollLeft: 900 }, { left: 700, width: 90 })).toBe(700 - STRIP_REVEAL_INSET);
  // Already in view.
  expect(revealOffset({ ...view, scrollLeft: 100 }, { left: 200, width: 80 })).toBe(100);
  // Never past either end.
  expect(revealOffset(view, { left: 2350, width: 50 })).toBe(2400 - 320);
  expect(revealOffset({ ...view, scrollLeft: 40 }, { left: 10, width: 60 })).toBe(0);
});

test("revealInStrip moves an overflowing strip to its shown category", () => {
  const node = strip(320, 2400);
  const link = window.document.createElement("a");
  Object.defineProperty(link, "getBoundingClientRect", { value: () => ({ left: 1500 - node.scrollLeft, width: 120 }) });
  revealInStrip(node, link);
  expect(node.scrollLeft).toBe(1500 + 120 + STRIP_REVEAL_INSET - 320);
  const column = strip(220, 220);
  revealInStrip(column, link);
  expect(column.scrollLeft).toBe(0);
});
