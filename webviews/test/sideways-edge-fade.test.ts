// l10n-allow-file: test fixture markup, not shipped UI.
// A wide table in a reply scrolls sideways in its own box and fades the edge with more table past
// it: the right edge at rest, both while scrolled partway, the left alone at the end (user
// 2026-11-07: "markdown missing fade now", on a table cut hard at the right edge). Before, only the
// right edge was ever marked, so a scrolled table's left edge stayed hard. The marks drive the
// mask in conversation.css and the Markdown viewer's styles.css.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { watchSideways } from "../src/agent-session/acpmux/conversation/sideways";

let window: JSDOM["window"];

beforeAll(() => {
  ({ window } = new JSDOM("<!doctype html><body></body>", { url: "http://localhost/", pretendToBeVisual: true }));
});
afterAll(() => window.close());

/** A box `width` wide holding content `content` wide, scrolled to `left`. */
function box(width: number, content: number) {
  const element = window.document.createElement("div");
  element.className = "cv-table-wrap";
  window.document.body.append(element);
  let left = 0;
  Object.defineProperties(element, {
    clientWidth: { get: () => width },
    scrollWidth: { get: () => content },
    scrollLeft: { get: () => left, set: (value: number) => (left = Math.max(0, Math.min(content - width, value))) },
  });
  const scroll = (to: number) => {
    element.scrollLeft = to;
    element.dispatchEvent(new window.Event("scroll"));
  };
  return { element, scroll };
}

const edges = (element: Element) => ({
  left: element.hasAttribute("data-more-left"),
  right: element.hasAttribute("data-more-right"),
});

test("a wide table marks its right edge at rest, both edges mid-scroll, and its left edge at the end", () => {
  const { element, scroll } = box(300, 900);
  const stop = watchSideways(element);
  expect(edges(element)).toEqual({ left: false, right: true });
  scroll(200);
  expect(edges(element)).toEqual({ left: true, right: true });
  scroll(600);
  expect(edges(element)).toEqual({ left: true, right: false });
  scroll(0);
  expect(edges(element)).toEqual({ left: false, right: true });
  stop();
});

test("a table that fits marks neither edge", () => {
  const { element } = box(300, 300);
  const stop = watchSideways(element);
  expect(edges(element)).toEqual({ left: false, right: false });
  stop();
});
