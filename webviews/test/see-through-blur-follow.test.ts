// The see-through blur's follow loop (src/ui/glass/seeThroughBlur.ts) under the rail's preview card,
// which moves to the next row by its own inline transform about every 40 ms of a sweep (Leo,
// 2026-11-04: "hover previews kinda lag across me hovering over the sidebar stuff :("). Each move
// restarted the loop that follows a fade or a resize until STABLE_FRAMES unchanged frames, so through
// a sweep it never stopped: every frame re-read the card's rect and style and the transcript's rect.
// A move by the surface's inline style is final when written: one frame measures it. A CSS transition
// (transitionrun) and a resize still follow until they settle.
//
// jsdom has no layout or Chromium backdrop: the window says it draws backdrops over the page (as a
// see-through Chromium page does), the surface's rect follows its transform, and frames run when the
// test says.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { attachSeeThroughBlur, OVER_ATTRIBUTE, UNDER_ATTRIBUTE } from "../src/ui/glass/seeThroughBlur";

const dom = new JSDOM(
  "<!doctype html><div id=layer><div id=rows></div><div id=card></div><div id=positioner><div id=popup></div></div></div>",
  {
    pretendToBeVisual: true,
  },
);
const win = dom.window as unknown as Window & typeof globalThis & Record<string, unknown>;
const queued = new Map<number, FrameRequestCallback>();
let lastFrame = 0;
Object.assign(win, {
  CSS: { supports: (property: string) => property !== "-webkit-backdrop-filter" },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => {
    queued.set(++lastFrame, callback);
    return lastFrame;
  },
  cancelAnimationFrame: (handle: number) => void queued.delete(handle),
});
afterAll(() => dom.window.close());

const document = dom.window.document;
const rows = document.getElementById("rows")!;
const card = document.getElementById("card")!;
const rect = (x: number, y: number, width: number, height: number) =>
  ({ x, y, left: x, top: y, width, height, right: x + width, bottom: y + height, toJSON() {} }) as DOMRect;
rows.getBoundingClientRect = () => rect(0, 0, 800, 600);
/// The card's measures: each pass of the loop reads its rect once.
let measures = 0;
card.getBoundingClientRect = () => {
  measures += 1;
  const y = Number(/translate3d\([^,]+,\s*([-\d.]+)px/.exec(card.style.transform)?.[1] ?? 0);
  return rect(40, y, 300, 120);
};
card.style.transform = "translate3d(40px, 0px, 0)";

/// Lets the style's mutation record reach its observer, then runs every frame asked for until none is.
async function frames(): Promise<number> {
  await Promise.resolve();
  let ran = 0;
  for (let round = 0; round < 20 && queued.size > 0; round += 1) {
    const due = [...queued.values()];
    queued.clear();
    for (const callback of due) callback(0);
    ran += 1;
  }
  return ran;
}
/// The hole's top in the rows' box, as the rows' filter has it.
const holeTop = () => Number(document.querySelector("filter feGaussianBlur")?.getAttribute("y") ?? Number.NaN);

test("a surface moved by its inline transform measures once, and its hole moves with it", async () => {
  const detach = attachSeeThroughBlur(card, () => [rows]);
  try {
    await frames();
    expect(rows.hasAttribute(UNDER_ATTRIBUTE)).toBe(true);
    expect(holeTop()).toBe(0);
    const passes: number[] = [];
    for (const y of [40, 80, 120, 160]) {
      measures = 0;
      card.style.transform = `translate3d(40px, ${y}px, 0)`;
      await frames();
      passes.push(measures);
      expect(holeTop()).toBe(y);
    }
    expect(passes).toEqual([1, 1, 1, 1]);
  } finally {
    detach();
  }
});

test("a transition on the surface still follows until it settles", async () => {
  const detach = attachSeeThroughBlur(card, () => [rows]);
  try {
    await frames();
    measures = 0;
    card.dispatchEvent(new dom.window.Event("transitionrun"));
    // Nothing moved: STABLE_FRAMES (3) unchanged frames, each a measure.
    expect(await frames()).toBe(3);
    expect(measures).toBe(3);
  } finally {
    detach();
  }
});

// A hover card's popup is placed by its positioner (Base UI writes the positioner's inline style, on
// scroll too), not by its own style: the hole follows the positioner. A card on a page with nothing
// it can blur (the changelog's pull request cards) keeps its underlay.
const positioner = document.getElementById("positioner")!;
const popup = document.getElementById("popup")!;
popup.getBoundingClientRect = () => {
  const y = Number(/translate\([^,]+,\s*([-\d.]+)px/.exec(positioner.style.transform)?.[1] ?? 0);
  return rect(40, y, 300, 120);
};
positioner.style.transform = "translate(40px, 100px)";

test("a popup moved by its positioner's inline style moves its hole with it", async () => {
  const detach = attachSeeThroughBlur(popup, () => [rows]);
  try {
    await frames();
    expect(holeTop()).toBe(100);
    positioner.style.transform = "translate(40px, 180px)";
    await frames();
    expect(holeTop()).toBe(180);
  } finally {
    detach();
  }
});

test("a surface with nothing it can blur keeps its underlay", async () => {
  const detach = attachSeeThroughBlur(popup, () => []);
  try {
    await frames();
    expect(popup.hasAttribute(OVER_ATTRIBUTE)).toBe(false);
  } finally {
    detach();
  }
});
