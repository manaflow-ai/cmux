// An anchored menu opens on the side it fits (useUiAnchor, src/ui/anchor.ts): above its chip when
// there is room, flipped below for want of room, whatever side it asked for. It opens in one frame,
// with no travel out of its trigger (Leo 2026-10-24: "When you open it up, no animation"), so the
// placement sets no `--ui-popup-y` for an open animation to read.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useRef } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "getComputedStyle",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: window.HTMLElement,
    getComputedStyle: window.getComputedStyle.bind(window),
  });
  Object.defineProperty(window, "innerWidth", { configurable: true, value: 800 });
  Object.defineProperty(window, "innerHeight", { configurable: true, value: 600 });
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const rect = (left: number, top: number, width: number, height: number) =>
  ({ left, top, right: left + width, bottom: top + height, width, height, x: left, y: top, toJSON() {} }) as DOMRect;

/// A 200px menu anchored to a chip whose top is at `chipTop` in a 600px window: the side it opened
/// on, and any travel its placement set.
async function placed(chipTop: number, side: "above" | "below"): Promise<{ side: string; travel: string }> {
  const { createRoot } = await import("react-dom/client");
  const { useUiAnchor } = await import("../src/ui/anchor");
  function Menu() {
    const trigger = useRef<HTMLButtonElement>(null);
    const menu = useRef<HTMLDivElement>(null);
    const style = useUiAnchor(trigger, menu, true, { side });
    return (
      <>
        <button ref={trigger}>Model</button>
        <div ref={menu} className="ui-popup" style={style} />
      </>
    );
  }
  const proto = window.HTMLElement.prototype;
  const original = proto.getBoundingClientRect;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    if (this.tagName === "BUTTON") return rect(100, chipTop, 120, 28);
    if (this.classList.contains("ui-popup")) return rect(0, 0, 300, 200);
    return rect(0, 0, 0, 0);
  };
  try {
    act(() => root?.unmount());
    root = createRoot(window.document.getElementById("root")!);
    act(() => root!.render(<Menu />));
    const popup = window.document.querySelector<HTMLElement>(".ui-popup")!;
    return {
      side: Number.parseFloat(popup.style.top) > chipTop ? "below" : "above",
      travel: popup.style.getPropertyValue("--ui-popup-y"),
    };
  } finally {
    proto.getBoundingClientRect = original;
  }
}

test("a menu with room above its chip opens above it, with no travel", async () => {
  expect(await placed(500, "above")).toEqual({ side: "above", travel: "" });
});

test("a menu that asked for above but has no room there flips below its chip", async () => {
  expect(await placed(40, "above")).toEqual({ side: "below", travel: "" });
});

test("a menu that opens below its chip stays below, and one with no room below flips above", async () => {
  expect(await placed(40, "below")).toEqual({ side: "below", travel: "" });
  expect(await placed(540, "below")).toEqual({ side: "above", travel: "" });
});
