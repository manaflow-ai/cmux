// A menu over the composer keeps its underlay, so the composer's text never reads through it
// (chatUnderGlass.ts hostGlassCover). On the New chat screen the dock is `display: contents`
// (bottomStack.css): its own rect is empty, and only its parts lie under the menu. Lucas,
// 2026-11-10: the permission menu there went clear and the composer showed through it.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { hostGlassCover, chatUnderHoverCard } from "../src/agent-session/acpmux/chatUnderGlass";
import { attachSeeThroughBlur, KEEPS_UNDERLAY_ATTRIBUTE, OVER_ATTRIBUTE } from "../src/ui/glass/seeThroughBlur";

let dom: JSDOM | undefined;
let detach: (() => void) | undefined;

afterEach(() => {
  detach?.();
  detach = undefined;
  dom?.window.close();
  dom = undefined;
});

type Box = { left: number; top: number; width: number; height: number };

/** A chat page whose dock floats (a box of its own) or not (`display: contents`, an empty rect). */
function chat(
  dockFloats: boolean,
  menuBox: Box = { left: 100, top: 480, width: 300, height: 200 },
): { doc: Document; menu: HTMLElement } {
  dom = new JSDOM(
    `<!doctype html><html><body>
      <section class="acpmux-shell"><div class="acpmux-main">
        <div class="acpmux-stage"><div class="acpmux-empty"></div></div>
        <div class="acpmux-dock"><div class="acpmux-composer"></div></div>
      </div></section>
      <div class="positioner"><div class="menu"></div></div>
    </body></html>`,
    { pretendToBeVisual: true },
  );
  const window = dom.window as unknown as Window & typeof globalThis;
  // Chromium: no -webkit-backdrop-filter, so the page blurs in place under a glass.
  Object.defineProperty(window, "CSS", { value: { supports: () => false }, configurable: true });
  (window as unknown as { ResizeObserver: unknown }).ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  const doc = window.document;
  const boxes = new Map<Element, Box>([
    [doc.querySelector(".acpmux-empty")!, { left: 0, top: 0, width: 800, height: 600 }],
    [doc.querySelector(".acpmux-composer")!, { left: 100, top: 600, width: 600, height: 140 }],
    // The menu opens up from the chip under the field, over the composer and the stage.
    [doc.querySelector(".menu")!, menuBox],
  ]);
  if (dockFloats) boxes.set(doc.querySelector(".acpmux-dock")!, { left: 0, top: 590, width: 800, height: 160 });
  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    const box = boxes.get(this) ?? { left: 0, top: 0, width: 0, height: 0 };
    return {
      ...box,
      x: box.left,
      y: box.top,
      right: box.left + box.width,
      bottom: box.top + box.height,
    } as DOMRect;
  };
  return { doc, menu: doc.querySelector<HTMLElement>(".menu")! };
}

for (const dockFloats of [true, false])
  test(`a menu over the composer keeps its underlay (dock ${dockFloats ? "floats" : "has no box"})`, () => {
    const { menu } = chat(dockFloats);
    detach = attachSeeThroughBlur(menu, chatUnderHoverCard, hostGlassCover);
    expect(menu.hasAttribute(KEEPS_UNDERLAY_ATTRIBUTE)).toBe(true);
    expect(menu.hasAttribute(OVER_ATTRIBUTE)).toBe(false);
  });

test("a menu over the stage alone blurs it in place and keeps no underlay", () => {
  const { menu } = chat(false, { left: 100, top: 100, width: 300, height: 200 });
  detach = attachSeeThroughBlur(menu, chatUnderHoverCard, hostGlassCover);
  expect(menu.hasAttribute(OVER_ATTRIBUTE)).toBe(true);
  expect(menu.hasAttribute(KEEPS_UNDERLAY_ATTRIBUTE)).toBe(false);
});
