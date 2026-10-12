// Leo, 2026-10-12: a tooltip for truncated text was narrower than the row it came from, so the
// full text wrapped into a tall thin column. A tooltip for truncated text shows the full text,
// wrapping, up to the source row's width (at least ~480 px), and never narrower than the line.
// Tooltips also carry a shortcut hint in the secondary ink, like the native one.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { installTooltips, TOOLTIP_DELAY, tooltipWidth } from "./titleTooltips";

test("a tooltip for truncated text wraps up to its source's width, never narrower than the line", () => {
  // Untruncated: the standard tooltip width.
  expect(tooltipWidth({ width: 120, truncated: false, view: 1000 })).toEqual({ min: 0, max: 320 });
  // A truncated 600 px line: at least the line, wrapping up to it.
  expect(tooltipWidth({ width: 600, truncated: true, view: 1000 })).toEqual({ min: 600, max: 600 });
  // A narrow truncated chip: up to 480 px.
  expect(tooltipWidth({ width: 140, truncated: true, view: 1000 })).toEqual({ min: 140, max: 480 });
  // Never wider than the window's room.
  expect(tooltipWidth({ width: 900, truncated: true, view: 700 })).toEqual({ min: 688, max: 688 });
});

let dom: JSDOM | undefined;
let uninstall: (() => void) | undefined;
afterEach(() => {
  uninstall?.();
  dom?.window.close();
  uninstall = undefined;
  dom = undefined;
});

/** Hovers `element` and waits out the first tooltip's delay. */
async function hover(element: Element) {
  element.dispatchEvent(new dom!.window.MouseEvent("pointerover", { bubbles: true }));
  await new Promise((resolve) => setTimeout(resolve, TOOLTIP_DELAY + 50));
}

function page(body: string) {
  dom = new JSDOM(`<!doctype html><body>${body}</body>`, { pretendToBeVisual: true });
  Object.defineProperty(dom.window.document.documentElement, "clientWidth", { value: 1000 });
  Object.defineProperty(dom.window.document.documentElement, "clientHeight", { value: 800 });
  uninstall = installTooltips(dom.window.document);
  return dom.window.document;
}

test("hovering a truncated row shows its full text as wide as the row", async () => {
  const doc = page(`<div id="row" title="A long chat title that the sidebar row cuts off with an ellipsis">A long…</div>`);
  const row = doc.getElementById("row")!;
  Object.defineProperty(row, "scrollWidth", { value: 900 });
  Object.defineProperty(row, "clientWidth", { value: 600 });
  row.getBoundingClientRect = () => ({ left: 10, top: 10, width: 600, height: 24 }) as DOMRect;
  await hover(row);
  const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  expect(tip.hidden).toBe(false);
  expect(tip.textContent).toBe("A long chat title that the sidebar row cuts off with an ellipsis");
  expect(tip.style.minWidth).toBe("600px");
  expect(tip.style.maxWidth).toBe("600px");
});

test("an untruncated control's tooltip keeps the standard width and shows its shortcut hint", async () => {
  const doc = page(`<button id="new" title="New Tab" data-tooltip-shortcut="⌘T"></button>`);
  const button = doc.getElementById("new")!;
  button.getBoundingClientRect = () => ({ left: 10, top: 10, width: 24, height: 24 }) as DOMRect;
  await hover(button);
  const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  expect(tip.hidden).toBe(false);
  expect(tip.style.maxWidth).toBe("320px");
  expect(tip.querySelector(".ui-tooltip-text")?.textContent).toBe("New Tab");
  expect(tip.querySelector(".ui-tooltip-hint")?.textContent).toBe("⌘T");
});
