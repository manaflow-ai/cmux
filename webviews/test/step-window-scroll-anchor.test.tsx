// An opened list of steps in the transcript's scroller (stepWindow.tsx) moves the transcript's offset
// only for a change the reader could see move: a step above the view's top, in a list whose row the
// view's top cuts through (the row the transcript holds in place), once the list has drawn. Its first
// draw shows the steps at their real heights, never at the 22px guess, and the transcript keeps the
// row at the top of its view in place as rows above it change height, so a row wholly above the view
// moves nothing either. Moved there, each tool row that mounted above a reader scrolling up pushed the
// view back down (the guess against a 32px step: 10px a step): the scroll fought the reader.
// A test DOM reads no layout: the list's top, each step's height and the scroller's box are set below.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useMemo, useRef } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

/// The scroller's view height, and the list's top in the view (negative: above the view's top).
const VIEW = 600;
let listTop = 0;
/// What the list's row draws under the list (a thought line), in px.
let below = 0;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    getComputedStyle: window.getComputedStyle.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const height = (node: Element): number => {
    const el = node as HTMLElement;
    if (el.dataset.h) return Number(el.dataset.h);
    if (el.dataset.list !== undefined) return [...el.children].reduce((sum, child) => sum + height(child), 0);
    return parseFloat(el.style.height) || 0;
  };
  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    const el = this as HTMLElement;
    const scroller = el.classList.contains("acpmux-scroll");
    const row = el.classList.contains("acpmux-row");
    const top = scroller ? 0 : el.dataset.list !== undefined || row ? listTop : 0;
    const list = row ? el.querySelector("[data-list]")! : el;
    const h = scroller ? VIEW : row ? height(list) + below : height(el);
    return {
      top,
      bottom: top + h,
      height: h,
      left: 0,
      right: 0,
      width: 0,
      x: 0,
      y: top,
      toJSON: () => ({}),
    } as DOMRect;
  };
  window.Element.prototype.getClientRects = function () {
    return [{}] as unknown as DOMRectList;
  };
  // The scroller's offset starts at 5,000 px; every other element keeps a test DOM's 0.
  const offsets = new WeakMap<Element, number>();
  Object.defineProperty(window.Element.prototype, "scrollTop", {
    configurable: true,
    get(this: Element) {
      return offsets.get(this) ?? (this.classList.contains("acpmux-scroll") ? 5_000 : 0);
    },
    set(this: Element, value: number) {
      offsets.set(this, value);
    },
  });
  // A run's own box (`.cv-run-scroll`) scrolls: 224px high over 1,000px of steps.
  Object.defineProperty(window.Element.prototype, "clientHeight", {
    configurable: true,
    get(this: Element) {
      return this.classList.contains("acpmux-scroll") ? VIEW : this.classList.contains("cv-run-scroll") ? 224 : 0;
    },
  });
  Object.defineProperty(window.Element.prototype, "scrollHeight", {
    configurable: true,
    get(this: Element) {
      return this.classList.contains("cv-run-scroll") ? 1_000 : 0;
    },
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

async function Harness() {
  const { useStepWindow, windowedSteps } = await import("../src/agent-session/acpmux/conversation/stepWindow");
  return function List({ heights, box }: { heights: readonly number[]; box: boolean }) {
    const list = useRef<HTMLDivElement>(null);
    const stepKeys = useMemo(() => heights.map((_, at) => `s${at}`), [heights.length]);
    const pieces = useStepWindow({ list, keys: stepKeys });
    return (
      <div className="acpmux-scroll">
        <article className="acpmux-row">
          <div className={box ? "cv-run-scroll" : undefined}>
            <div ref={list} data-list="">
              {windowedSteps(pieces, (from, to) =>
                stepKeys
                  .slice(from, to)
                  .map((key, at) => <div key={key} data-step={key} data-h={heights[from + at]} />),
              )}
            </div>
          </div>
        </article>
      </div>
    );
  };
}

/// A fresh list at `top` with `under` px of its row under it (in a run's own box with `box`);
/// `draw(heights)` draws it and returns the offset of what clips it after the draw.
async function drawList(top: number, under = 0, box = false) {
  const List = await Harness();
  const { createRoot } = await import("react-dom/client");
  act(() => root?.unmount());
  host.replaceChildren();
  root = createRoot(host);
  listTop = top;
  below = under;
  const draw = async (heights: readonly number[]) => {
    await act(async () => root!.render(<List heights={heights} box={box} />));
    return host.querySelector<HTMLElement>(box ? ".cv-run-scroll" : ".acpmux-scroll")!.scrollTop;
  };
  return draw;
}

test("a row wholly above the view moves no offset: not when its list first draws, nor when a step grows", async () => {
  // The list ends 300 - 96 px above the view's top, inside the steps the window mounts.
  const draw = await drawList(-300);
  expect(await draw([32, 32, 32])).toBe(5_000);
  expect(await draw([42, 32, 32])).toBe(5_000);
});

test("a list far above the view moves no offset when it first draws", async () => {
  const draw = await drawList(-2_000);
  expect(await draw([32, 32, 32])).toBe(5_000);
});

test("a list above the view's top in a row the view's top cuts through moves the offset by a step's growth", async () => {
  // The list ends 300 - 96 px above the view's top; the row's thought line under it reaches past it.
  const draw = await drawList(-300, 400);
  expect(await draw([32, 32, 32])).toBe(5_000);
  expect(await draw([42, 32, 32])).toBe(5_010);
});

test("a row that shrinks off the view's top still moves the offset: the transcript held it in place", async () => {
  // The row reaches 44px below the view's top until step 0 shrinks by 68px.
  const draw = await drawList(-300, 200);
  expect(await draw([80, 32, 32])).toBe(5_000);
  expect(await draw([12, 32, 32])).toBe(4_932);
});

test("the last step shrinking above a view's top under the list, in the same row, moves the offset", async () => {
  const draw = await drawList(-300, 200);
  expect(await draw([32, 32, 80])).toBe(5_000);
  expect(await draw([32, 32, 12])).toBe(4_932);
});

test("a row that grows onto the view's top moves no offset: the transcript corrects the row under it", async () => {
  // The row ends 4px above the view's top until step 0 grows by 30px.
  const draw = await drawList(-300, 200);
  expect(await draw([32, 32, 32])).toBe(5_000);
  expect(await draw([62, 32, 32])).toBe(5_000);
});

test("a step growing above the view's top inside the list moves the offset by its growth", async () => {
  // The view's top is 50px into the list: in step 1, under step 0.
  const draw = await drawList(-50);
  expect(await draw([32, 32, 32])).toBe(5_000);
  expect(await draw([52, 32, 32])).toBe(5_020);
  // A step under the view's top moves nothing above it.
  expect(await draw([52, 32, 60])).toBe(5_020);
});

test("a list in its run's own box moves the box's offset for a step above its view, wherever the row is", async () => {
  // The box is scrolled 100px into the 96px list: every step is above its view, and still mounted.
  const draw = await drawList(-100, 0, true);
  expect(await draw([32, 32, 32])).toBe(0);
  expect(await draw([42, 32, 32])).toBe(10);
});
