// Leo 2026-11-22: "when hovering your mouse to the sidebar, do you want to see the thumb? claude code,
// you dont see it... unless you scroll first. hovering only doesnt show. this completely eliminates the
// problem where for us right now, when you're near the thumb and the sliding repositioner, it gets
// confused and sometimes goes to the thumb instead of the dragger."
//
// scrollers.ts installScrollerProximity, in jsdom with the scroller's geometry stubbed: the pointer on
// a scroller's bar lane with no scroll marks nothing (no scrolling mark, no near mark, so no rule
// draws a thumb); after a scroll the thumb shows, widens under the pointer, holds while the pointer
// stays, and goes once the pointer leaves after the linger (`SCROLLING_HIDE_MS`); and the pointer over
// a resize handle (`RESIZE_HANDLE_ATTRIBUTE`) never marks the scroller under it. The stylesheet keeps
// no hover-only reveal. The painted behavior is scroller-near-grow.test.ts; the handle's hit-testing
// in a real engine is resize-handle-over-scroller-browser.test.ts (both browser lane).
import { afterEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  CARD_SCROLLER_CSS,
  installScrollerProximity,
  installScrollingMarks,
  MINIMAL_SCROLLER_CSS,
  MONACO_SCROLLER_CSS,
  NEAR_ATTRIBUTE,
  RESIZE_HANDLE_ATTRIBUTE,
  RESIZE_HANDLE_CSS,
  RESIZE_HANDLE_SELECTOR,
  SCROLLER_FADE_ATTRIBUTE,
  SCROLLER_ROOT_CSS,
  SCROLLING_ATTRIBUTE,
  SCROLLING_HIDE_MS,
  SHOWN_SCROLLER_ATTRIBUTE,
  SIDEWAYS_SCROLLER_CSS,
  type ScrollTimers,
} from "../src/scrollers";

/** A 200 x 200 box at the page's top left over 2000 px of content, with an 8 px lane on its right
    (x 192 to 200), and a resize handle band from x 196 to 204 over its edge, as SplitEdge draws one. */
function page(options: { fade?: boolean; shown?: boolean } = {}) {
  const dom = new JSDOM(
    `<!doctype html><html ${options.fade ? SCROLLER_FADE_ATTRIBUTE : ""}><body>
      <div id="pane">
        <div id="list" ${options.shown ? SHOWN_SCROLLER_ATTRIBUTE : ""} style="overflow-y: auto"><p id="row">row</p></div>
        <div id="handle" ${RESIZE_HANDLE_ATTRIBUTE}></div>
      </div>
    </body></html>`,
  );
  const window = dom.window;
  const document = window.document;
  const list = document.getElementById("list")!;
  const handle = document.getElementById("handle")!;
  const define = (element: Element, values: Record<string, number>) => {
    for (const [name, value] of Object.entries(values))
      Object.defineProperty(element, name, { configurable: true, get: () => value });
  };
  define(list, { offsetWidth: 200, clientWidth: 192, offsetHeight: 200, clientHeight: 200, scrollHeight: 2000 });
  define(list, { scrollWidth: 192 });
  list.getBoundingClientRect = () => ({ left: 0, top: 0, right: 200, bottom: 200, width: 200, height: 200 }) as DOMRect;
  // Frames run when the test says so.
  const frames: FrameRequestCallback[] = [];
  window.requestAnimationFrame = (callback: FrameRequestCallback) => frames.push(callback);
  window.cancelAnimationFrame = () => {};
  const flush = () => {
    for (const callback of frames.splice(0)) callback(0);
  };
  // The scrolling mark's linger runs when the test says so.
  const callbacks = new Map<number, () => void>();
  const delays: number[] = [];
  let next = 0;
  const timers: ScrollTimers = {
    set(callback, ms) {
      delays.push(ms);
      callbacks.set(++next, callback);
      return next;
    },
    clear(handle) {
      callbacks.delete(handle as number);
    },
  };
  const linger = () => {
    const due = [...callbacks.values()];
    callbacks.clear();
    for (const callback of due) callback();
  };
  installScrollingMarks(document as unknown as Document, timers);
  installScrollerProximity(document as unknown as Document);
  /** A pointer move with no button down onto `target` at `x`, `y`, and the frame it is read in. */
  const move = (target: Element, x: number, y = 100) => {
    target.dispatchEvent(
      new window.MouseEvent("pointermove", { bubbles: true, composed: true, clientX: x, clientY: y, buttons: 0 }),
    );
    flush();
  };
  /** A wheel over the list's content, as a person scrolls. */
  const wheel = () => {
    document
      .getElementById("row")!
      .dispatchEvent(
        new window.WheelEvent("wheel", { bubbles: true, composed: true, deltaY: 120, clientX: 40, clientY: 100 }),
      );
    flush();
  };
  const state = () => ({ scrolling: list.hasAttribute(SCROLLING_ATTRIBUTE), near: list.hasAttribute(NEAR_ATTRIBUTE) });
  return { dom, document, list, handle, move, wheel, linger, delays, state };
}

let open: JSDOM | undefined;
afterEach(() => {
  open?.window.close();
  open = undefined;
});

describe("hover alone never shows a thumb", () => {
  for (const [name, options] of [
    ["an ordinary scroller", {}],
    ["a chat transcript under the fade", { fade: true, shown: true }],
  ] as const)
    test(`${name}: the pointer across its lane and edge, no scroll: no scrolling or near mark`, () => {
      const p = page(options);
      open = p.dom;
      const seen: string[] = [];
      // From the content in to the lane, every column, then out past the edge.
      for (let x = 150; x < 210; x += 1) {
        p.move(p.list, x);
        const now = p.state();
        if (now.scrolling || now.near) seen.push(`x ${x}: ${JSON.stringify(now)}`);
      }
      expect(seen).toEqual([]);
    });
});

describe("a scroll shows it, the linger hides it", () => {
  test("shown while it scrolls, hidden SCROLLING_HIDE_MS after; the pointer on the lane afterwards shows nothing", () => {
    const p = page({ fade: true, shown: true });
    open = p.dom;
    p.move(p.list, 40);
    p.wheel();
    const scrolling = p.state();
    p.linger();
    const rested = p.state();
    p.move(p.list, 196);
    const hovered = p.state();
    expect({ scrolling, rested, hovered, linger: p.delays.at(-1) }).toEqual({
      scrolling: { scrolling: true, near: false },
      rested: { scrolling: false, near: false },
      hovered: { scrolling: false, near: false },
      linger: SCROLLING_HIDE_MS,
    });
  });

  test("near a shown thumb it widens and holds past the linger while the pointer stays; leaving hides it", () => {
    const p = page({ fade: true, shown: true });
    open = p.dom;
    p.move(p.list, 40);
    p.wheel();
    p.move(p.list, 196);
    const near = p.state();
    p.linger();
    p.move(p.list, 195);
    const held = p.state();
    p.move(p.list, 40);
    const left = p.state();
    p.move(p.list, 196);
    const back = p.state();
    expect({ near, held, left, back }).toEqual({
      near: { scrolling: true, near: true },
      held: { scrolling: false, near: true },
      left: { scrolling: false, near: false },
      back: { scrolling: false, near: false },
    });
  });

  test("a scroll under a pointer resting on the lane widens the thumb with no move", () => {
    const p = page({ fade: true, shown: true });
    open = p.dom;
    p.move(p.list, 196);
    const before = p.state();
    p.wheel();
    expect({ before, after: p.state() }).toEqual({
      before: { scrolling: false, near: false },
      after: { scrolling: true, near: true },
    });
  });
});

describe("a resize handle beats the scrollbar lane", () => {
  test("the pointer over the handle band, at every x across it, never marks the scroller near, even while it scrolls", () => {
    const p = page({ fade: true, shown: true });
    open = p.dom;
    p.move(p.list, 40);
    p.wheel();
    const seen: string[] = [];
    // The band is 8 px, centred on the list's right edge (x 200): half of it over the lane.
    for (let x = 196; x < 204; x += 1) {
      p.move(p.handle, x);
      if (p.state().near) seen.push(`x ${x}`);
    }
    // Off the handle, back on the lane while it still shows: it widens there.
    p.move(p.list, 194);
    expect({ seen, offHandle: p.state().near }).toEqual({ seen: [], offHandle: true });
  });

  test("a handle inside the scroller (a table's column grip) wins too", () => {
    const p = page({ fade: true, shown: true });
    open = p.dom;
    const grip = p.document.createElement("div");
    grip.setAttribute(RESIZE_HANDLE_ATTRIBUTE, "");
    p.list.append(grip);
    p.move(p.list, 40);
    p.wheel();
    p.move(grip, 196);
    expect(p.state().near).toBe(false);
  });

  test("one selector, and the handle's layer over raised content in the installed rules", () => {
    expect(RESIZE_HANDLE_SELECTOR).toBe(`[${RESIZE_HANDLE_ATTRIBUTE}]`);
    expect(RESIZE_HANDLE_CSS).toContain(
      `:root ${RESIZE_HANDLE_SELECTOR} {\n  z-index: var(--cmux-resize-handle-layer);`,
    );
    expect(RESIZE_HANDLE_CSS).toContain("--cmux-resize-handle-layer: calc(var(--layer-raised, 1) + 1);");
  });
});

test("no stylesheet rule shows a thumb on hover", () => {
  // The @pierre rules keep `:hover` only to override the libraries' own hover reveal; they are not
  // installed here, and set the thumb to its resting value.
  const css =
    SCROLLER_ROOT_CSS + CARD_SCROLLER_CSS + MINIMAL_SCROLLER_CSS + MONACO_SCROLLER_CSS + SIDEWAYS_SCROLLER_CSS;
  expect(css.match(/[^\n]*:hover[^\n]*/g) ?? []).toEqual([]);
});

describe("Monaco's slider holds under the pointer", () => {
  const scrollerModule = import("../src/scrollers");
  test("hover alone marks nothing; after a scroll the pointer holds it until it leaves", async () => {
    const { installMonacoThumbHold, MONACO_HELD_ATTRIBUTE, SCROLLING_ATTRIBUTE } = await scrollerModule;
    const dom = new JSDOM("<!doctype html><body></body>");
    const document = dom.window.document;
    document.body.innerHTML = `<div class="monaco-editor"><div class="monaco-scrollable-element"><div class="scrollbar"><div class="slider"></div></div></div></div>`;
    installMonacoThumbHold(document);
    const editor = document.querySelector(".monaco-editor") as HTMLElement;
    const bar = document.querySelector(".scrollbar") as HTMLElement;
    const fire = (type: string, target: Element, related: Element | null = null) =>
      target.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, relatedTarget: related }));
    fire("pointerover", bar);
    expect(editor.hasAttribute(MONACO_HELD_ATTRIBUTE)).toBe(false);
    fire("pointerout", bar, document.body);
    editor.setAttribute(SCROLLING_ATTRIBUTE, "");
    fire("pointerover", bar);
    editor.removeAttribute(SCROLLING_ATTRIBUTE);
    expect(editor.hasAttribute(MONACO_HELD_ATTRIBUTE)).toBe(true);
    fire("pointerout", bar, document.body);
    expect(editor.hasAttribute(MONACO_HELD_ATTRIBUTE)).toBe(false);
  });
});
