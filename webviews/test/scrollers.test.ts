import { afterEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { EDITOR_DEFAULTS, monacoOptions } from "../src/pages/editor/settings";
import {
  SCROLLING_ATTRIBUTE,
  SCROLLING_HIDE_MS,
  installScrollers,
  markScrolling,
  onScrollerStyleChange,
  scrollerStyle,
  wheelTarget,
  type ScrollTimers,
} from "../src/scrollers";

// SCROLLBARS-FOLLOW-MACOS: library scrollers follow the host's data-scrollers.

let dom: JSDOM | null = null;
afterEach(() => {
  dom?.window.close();
  dom = null;
});

function page(attribute?: string): Document {
  dom = new JSDOM(`<!doctype html><html${attribute ? ` data-scrollers="${attribute}"` : ""}><body></body></html>`);
  return dom.window.document;
}

/** Timers the test runs by hand: `advance(ms)` fires what is due. */
function manualTimers(): ScrollTimers & { advance(ms: number): void; pending(): number } {
  let now = 0;
  let next = 1;
  const due = new Map<number, { at: number; run: () => void }>();
  return {
    set(callback, ms) {
      const id = next++;
      due.set(id, { at: now + ms, run: callback });
      return id;
    },
    clear(handle) {
      due.delete(handle as number);
    },
    advance(ms) {
      now += ms;
      for (const [id, timer] of due) {
        if (timer.at <= now) {
          due.delete(id);
          timer.run();
        }
      }
    },
    pending: () => due.size,
  };
}

/** Gives `element` a layout jsdom does not compute. */
function overflowing(element: HTMLElement, axis: "y" | "x"): void {
  Object.defineProperty(element, axis === "y" ? "scrollHeight" : "scrollWidth", { value: 500 });
  Object.defineProperty(element, axis === "y" ? "clientHeight" : "clientWidth", { value: 100 });
  element.style.setProperty(axis === "y" ? "overflow-y" : "overflow-x", "auto");
}

describe("scrollerStyle", () => {
  test("is the host's answer, and overlay without a host", () => {
    expect(scrollerStyle(page("legacy").documentElement)).toBe("legacy");
    expect(scrollerStyle(page("overlay").documentElement)).toBe("overlay");
    expect(scrollerStyle(page().documentElement)).toBe("overlay");
  });

  test("a live change from the host reaches the page once per change", async () => {
    const root = page("overlay").documentElement;
    const seen: string[] = [];
    const stop = onScrollerStyleChange((style) => seen.push(style), root);
    root.setAttribute("data-scrollers", "legacy");
    await Promise.resolve();
    root.setAttribute("data-scrollers", "legacy");
    await Promise.resolve();
    root.setAttribute("data-scrollers", "overlay");
    await Promise.resolve();
    stop();
    root.setAttribute("data-scrollers", "legacy");
    await Promise.resolve();
    expect(seen).toEqual(["legacy", "overlay"]);
  });
});

describe("markScrolling", () => {
  test("marks while scrolling and clears after the last step", () => {
    const element = page().createElement("div");
    const timers = manualTimers();
    markScrolling(element, timers);
    expect(element.hasAttribute(SCROLLING_ATTRIBUTE)).toBe(true);
    timers.advance(SCROLLING_HIDE_MS - 100);
    // Another step restarts the wait.
    markScrolling(element, timers);
    timers.advance(SCROLLING_HIDE_MS - 100);
    expect(element.hasAttribute(SCROLLING_ATTRIBUTE)).toBe(true);
    timers.advance(100);
    expect(element.hasAttribute(SCROLLING_ATTRIBUTE)).toBe(false);
    expect(timers.pending()).toBe(0);
  });
});

describe("wheelTarget", () => {
  test("is the first element on the path that overflows on the wheel's axis", () => {
    const doc = page();
    const outer = doc.createElement("div");
    const row = doc.createElement("div");
    const cell = doc.createElement("span");
    outer.append(row);
    row.append(cell);
    doc.body.append(outer);
    overflowing(outer, "y");
    overflowing(row, "x");
    const path = [cell, row, outer, doc.body, doc.documentElement, doc];
    const event = (deltaX: number, deltaY: number) => ({ composedPath: () => path, deltaX, deltaY });
    expect(wheelTarget(event(0, 10))).toBe(outer);
    expect(wheelTarget(event(10, 0))).toBe(row);
  });

  test("an element that clips (overflow hidden) is not a scroller", () => {
    const doc = page();
    const clipped = doc.createElement("div");
    doc.body.append(clipped);
    overflowing(clipped, "y");
    clipped.style.setProperty("overflow-y", "hidden");
    expect(wheelTarget({ composedPath: () => [clipped, doc.body], deltaX: 0, deltaY: 5 })).toBeNull();
  });
});

describe("installScrollers", () => {
  test("installs the root rules once", () => {
    const doc = page();
    installScrollers(doc, manualTimers());
    installScrollers(doc, manualTimers());
    expect(doc.querySelectorAll("#cmux-scrollers").length).toBe(1);
  });
});

describe("Monaco follows the setting", () => {
  const context = { readOnly: true, large: false, ariaLabel: "E" };

  test("overlay: Monaco's auto scrollbars, no ruler border or cursor mark at rest", () => {
    const options = monacoOptions(EDITOR_DEFAULTS, undefined, { ...context, scrollers: "overlay" }) as any;
    expect(options.scrollbar).toEqual({
      vertical: "auto",
      horizontal: "auto",
      useShadows: false,
      alwaysConsumeMouseWheel: false,
    });
    expect(options.overviewRulerBorder).toBe(false);
    expect(options.hideCursorInOverviewRuler).toBe(true);
  });

  test("legacy (Always): the scrollbars stay visible", () => {
    const options = monacoOptions(EDITOR_DEFAULTS, undefined, { ...context, scrollers: "legacy" }) as any;
    expect(options.scrollbar.vertical).toBe("visible");
    expect(options.scrollbar.horizontal).toBe("visible");
  });

  test("without a host answer the editor is overlay", () => {
    const options = monacoOptions(EDITOR_DEFAULTS, undefined, context) as any;
    expect(options.scrollbar.vertical).toBe("auto");
  });
});
