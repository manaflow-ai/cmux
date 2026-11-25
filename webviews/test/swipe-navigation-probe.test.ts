// The DOM half of two-finger Back / Forward (swipeNavigation/probe.ts): which element under the
// fingers keeps a horizontal gesture for itself, so the swipe scrolls or edits there instead.
import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { keepsSwipe } from "../src/swipeNavigation/probe";

const dom = new JSDOM("<!doctype html><body></body>", { url: "http://localhost/", pretendToBeVisual: true });
const doc = dom.window.document;
const scope = globalThis as Record<string, unknown>;
const saved = { Node: scope.Node, Element: scope.Element, HTMLElement: scope.HTMLElement };
Object.assign(scope, { Node: dom.window.Node, Element: dom.window.Element, HTMLElement: dom.window.HTMLElement });
afterAll(() => Object.assign(scope, saved));
// jsdom keeps no scroll offsets: store them per element, as an engine would.
for (const name of ["scrollTop", "scrollLeft"] as const) {
  const offsets = new WeakMap<Element, number>();
  Object.defineProperty(dom.window.Element.prototype, name, {
    configurable: true,
    get(this: Element) {
      return offsets.get(this) ?? 0;
    },
    set(this: Element, value: number) {
      offsets.set(this, value);
    },
  });
}

/** jsdom does no layout: give an element the scroll geometry a real engine would. */
function geometry(el: Element, scrollWidth: number, clientWidth: number, scrollLeft = 0): void {
  Object.defineProperty(el, "scrollWidth", { configurable: true, value: scrollWidth });
  Object.defineProperty(el, "clientWidth", { configurable: true, value: clientWidth });
  let left = scrollLeft;
  Object.defineProperty(el, "scrollLeft", { configurable: true, get: () => left, set: (v: number) => (left = v) });
}

function page(html: string): void {
  doc.body.innerHTML = html;
  doc.getSelection()?.removeAllRanges();
}

const at = (id: string) => doc.getElementById(id);
const quiet = { now: 10_000, preventedAt: -Infinity };

describe("what keeps a horizontal gesture", () => {
  test("plain content lets the swipe through", () => {
    page(`<main><p id=t>hello</p></main>`);
    expect(keepsSwipe(at("t"), "back", quiet)).toBe(false);
  });

  test("a nested horizontal scroller keeps the way it can still scroll", () => {
    page(`<div id=s style="overflow-x:auto"><table><tr><td id=t>wide</td></tr></table></div>`);
    const scroller = at("s")!;
    geometry(scroller, 1200, 400, 0);
    // At its left edge: Back (content toward the left edge) has nowhere to scroll, Forward does.
    expect(keepsSwipe(at("t"), "back", quiet)).toBe(false);
    expect(keepsSwipe(at("t"), "forward", quiet)).toBe(true);
    scroller.scrollLeft = 300;
    expect(keepsSwipe(at("t"), "back", quiet)).toBe(true);
  });

  test("a right-to-left scroller counts from its right edge", () => {
    page(`<div id=s style="overflow-x:auto;direction:rtl"><span id=t>wide</span></div>`);
    geometry(at("s")!, 1200, 400, 0);
    expect(keepsSwipe(at("t"), "forward", quiet)).toBe(false);
    expect(keepsSwipe(at("t"), "back", quiet)).toBe(true);
  });

  test("the walk crosses an open shadow root", () => {
    page(`<div id=s style="overflow-x:auto"><div id=host></div></div>`);
    geometry(at("s")!, 1200, 400, 0);
    const root = at("host")!.attachShadow({ mode: "open" });
    root.innerHTML = `<span id=inner>x</span>`;
    expect(keepsSwipe(root.getElementById("inner"), "forward", quiet)).toBe(true);
  });

  test("a horizontal scroller with overscroll-behavior-x other than auto keeps it at either edge", () => {
    page(`<div id=s style="overflow-x:auto;overscroll-behavior-x:contain"><canvas id=t></canvas></div>`);
    geometry(at("s")!, 800, 300, 0);
    expect(keepsSwipe(at("t"), "back", quiet)).toBe(true);
    expect(keepsSwipe(at("t"), "forward", quiet)).toBe(true);
  });

  test("a vertical list's overscroll containment does not take the swipe (popovers, the Home dock)", () => {
    page(`<div id=s style="overflow:auto;overscroll-behavior-x:contain"><p id=t>row</p></div>`);
    geometry(at("s")!, 300, 300, 0);
    expect(keepsSwipe(at("t"), "back", quiet)).toBe(false);
  });

  test("an editable element and the composer keep it", () => {
    page(`<textarea id=a></textarea><div contenteditable=true><p id=b>draft</p></div><div role=textbox id=c></div>`);
    for (const id of ["a", "b", "c"]) expect(keepsSwipe(at(id), "back", quiet)).toBe(true);
  });

  test("a gesture over selected text keeps it", () => {
    page(`<p id=t>select <b id=w>these</b> words</p><p id=o>elsewhere</p>`);
    const range = doc.createRange();
    range.selectNodeContents(at("w")!);
    doc.getSelection()!.addRange(range);
    expect(keepsSwipe(at("w"), "back", quiet)).toBe(true);
    expect(keepsSwipe(at("o"), "back", quiet)).toBe(false);
  });

  test("the app's own anti-bounce rule on the root lets the swipe through (shared/desktop.css)", () => {
    page(`<main><p id=t>hello</p></main>`);
    // An engine expands the shorthand; jsdom does not, so set the longhand it computes too.
    const rules = ["overscroll-behavior", "overscroll-behavior-x"];
    for (const el of [doc.documentElement, doc.body]) for (const rule of rules) el.style.setProperty(rule, "none");
    try {
      expect(keepsSwipe(at("t"), "back", quiet)).toBe(false);
      expect(keepsSwipe(at("t"), "forward", quiet)).toBe(false);
    } finally {
      for (const el of [doc.documentElement, doc.body]) for (const rule of rules) el.style.removeProperty(rule);
    }
  });

  test("a page that recently took horizontal wheels keeps it", () => {
    page(`<p id=t>carousel</p>`);
    expect(keepsSwipe(at("t"), "back", { now: 10_000, preventedAt: 9_700 })).toBe(true);
    expect(keepsSwipe(at("t"), "back", { now: 10_000, preventedAt: 9_000 })).toBe(false);
  });
});
