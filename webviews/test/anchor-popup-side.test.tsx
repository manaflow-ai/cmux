// An anchored menu travels out of its trigger on the side it opened (Leo 2026-10-20, directional
// motion): one that fits above its chip rises (`--ui-popup-y: 4px`), and one that flips below for
// want of room drops (`-4px`), whatever side it asked for. useUiAnchor (src/ui/anchor.ts) resolves
// the side, so it sets the travel with the position.
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

/// A 200px menu anchored to a chip whose top is at `chipTop` in a 600px window.
async function travel(chipTop: number, side: "above" | "below"): Promise<string> {
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
    return window.document.querySelector<HTMLElement>(".ui-popup")!.style.getPropertyValue("--ui-popup-y");
  } finally {
    proto.getBoundingClientRect = original;
  }
}

test("a menu with room above its chip rises out of it", async () => {
  expect(await travel(500, "above")).toBe("4px");
});

test("a menu that asked for above but flipped below for want of room drops out of its chip", async () => {
  expect(await travel(40, "above")).toBe("-4px");
});

test("a menu that opens below its chip drops, and one that flips above rises", async () => {
  expect(await travel(40, "below")).toBe("-4px");
  expect(await travel(540, "below")).toBe("4px");
});
