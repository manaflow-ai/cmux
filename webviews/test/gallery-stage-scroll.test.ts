import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  readScrollPosition,
  restoreScrollPosition,
  restoreScrollPositionUnlessMoved,
  SCROLL_KEYS,
  scrollBaselineAfterEvent,
  scrollTargetFor,
} from "../src/gallery/shell/scroll";

const dom = new JSDOM(`<!doctype html><main class="gallery-main"><iframe></iframe></main>`);
const iframe = dom.window.document.querySelector("iframe")!;
const main = dom.window.document.querySelector(".gallery-main")! as HTMLElement;

afterAll(() => dom.window.close());

describe("gallery stage scroll restoration", () => {
  test("uses the shell scroll container on desktop and the window on mobile", () => {
    main.style.overflowY = "auto";
    expect(scrollTargetFor(iframe)).toBe(main);
    main.style.overflowY = "visible";
    expect(scrollTargetFor(iframe)).toBeNull();
  });

  test("captures and restores one element position", () => {
    main.scrollLeft = 12;
    main.scrollTop = 34;
    const position = readScrollPosition(main);
    main.scrollLeft = 0;
    main.scrollTop = 0;
    restoreScrollPosition(main, position);
    expect(readScrollPosition(main)).toEqual({ x: 12, y: 34 });
  });

  test("restores an iframe-induced move when no user input occurred", () => {
    const initial = { x: 12, y: 34 };
    main.scrollLeft = initial.x;
    main.scrollTop = initial.y;
    main.scrollTop = 99;
    expect(restoreScrollPositionUnlessMoved(main, initial, false)).toBe(true);
    expect(readScrollPosition(main)).toEqual(initial);
  });

  test("preserves a target moved by intentional input", () => {
    const initial = { x: 12, y: 34 };
    main.scrollLeft = initial.x;
    main.scrollTop = 99;
    expect(restoreScrollPositionUnlessMoved(main, initial, true)).toBe(false);
    expect(readScrollPosition(main)).toEqual({ x: 12, y: 99 });
    expect(SCROLL_KEYS.has("PageDown")).toBe(true);
    expect(SCROLL_KEYS.has("a")).toBe(false);
  });

  test("updates the baseline for navigation, restores a focused iframe jump, and honors intent", () => {
    const initial = { x: 0, y: 10 };
    main.scrollLeft = initial.x;
    main.scrollTop = initial.y;
    main.scrollTop = 40;
    let result = scrollBaselineAfterEvent(main, iframe, initial, false);
    expect(result).toEqual({ baseline: { x: 0, y: 40 }, restore: false });

    iframe.focus();
    main.scrollTop = 90;
    result = scrollBaselineAfterEvent(main, iframe, result.baseline, false);
    expect(result).toEqual({ baseline: { x: 0, y: 40 }, restore: true });

    main.scrollTop = 120;
    result = scrollBaselineAfterEvent(main, iframe, result.baseline, true);
    expect(result).toEqual({ baseline: { x: 0, y: 40 }, restore: false });
  });
});
