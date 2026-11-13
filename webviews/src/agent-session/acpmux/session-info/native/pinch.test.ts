// The page tells the App of its trackpad pinch, so the native Session Info panel zooms and pans with
// the page (Leo, 2026-11-12: "evidently you zoom in and it doesn't really, you know, it doesn't follow").
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { NO_PINCH, readPinch, reportPinch, type Pinch } from "./pinch";

let dom: JSDOM | undefined;
let stop: (() => void) | undefined;

afterEach(() => {
  stop?.();
  stop = undefined;
  dom?.window.close();
  dom = undefined;
});

/// A window whose visual viewport the test moves, and fires its events as a pinch does.
function pinchable(initial: Pinch = NO_PINCH) {
  dom = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true });
  const view = dom.window as unknown as Window;
  const visual = new dom.window.EventTarget() as EventTarget & { scale: number; offsetLeft: number; offsetTop: number };
  Object.assign(visual, { scale: initial.scale, offsetLeft: initial.left, offsetTop: initial.top });
  Object.defineProperty(view, "visualViewport", { value: visual, configurable: true });
  const pinch = (next: Pinch) => {
    Object.assign(visual, { scale: next.scale, offsetLeft: next.left, offsetTop: next.top });
    visual.dispatchEvent(new dom!.window.Event("resize"));
    visual.dispatchEvent(new dom!.window.Event("scroll"));
  };
  return { view, pinch };
}

const frame = (view: Window) => new Promise<void>((resolve) => view.requestAnimationFrame(() => resolve()));

test("no pinch sends nothing; a pinch sends its scale and offset once a frame; its end sends no pinch", async () => {
  const { view, pinch } = pinchable();
  const reports: Pinch[] = [];
  stop = reportPinch(view, (next) => reports.push(next));
  await frame(view);
  expect(reports).toEqual([]);

  pinch({ scale: 2, left: 300, top: 40 });
  await frame(view);
  // Two events in the frame, one report.
  expect(reports).toEqual([{ scale: 2, left: 300, top: 40 }]);

  pinch({ scale: 1, left: 0, top: 0 });
  await frame(view);
  expect(reports.at(-1)).toEqual(NO_PINCH);
  expect(reports).toHaveLength(2);
});

test("a panel that opens on a pinched page sends the pinch at once, and its close sends no pinch", () => {
  const { view } = pinchable({ scale: 1.5, left: 12.5, top: 0 });
  const reports: Pinch[] = [];
  stop = reportPinch(view, (next) => reports.push(next));
  expect(reports).toEqual([{ scale: 1.5, left: 12.5, top: 0 }]);
  stop();
  stop = undefined;
  expect(reports.at(-1)).toEqual(NO_PINCH);
});

test("a page with no visual viewport reads as no pinch", () => {
  dom = new JSDOM("<!doctype html><html><body></body></html>");
  const view = dom.window as unknown as Window;
  Object.defineProperty(view, "visualViewport", { value: undefined, configurable: true });
  expect(readPinch(view)).toEqual(NO_PINCH);
});
