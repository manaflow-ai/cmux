// The "is any overlay open" check feature tips use (ui/openOverlay.ts): a surface counts only when it
// is drawn. Every page keeps one hidden title tooltip in its body (ui/titleTooltips.ts, installed by
// pages/shared/desktop.ts); counting it held every tip back on every page.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { installTooltips } from "./titleTooltips";
import { isRendered, openOverlay } from "./openOverlay";

let dom: JSDOM;
let uninstall: (() => void) | undefined;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><body></body>", { url: "http://localhost/", pretendToBeVisual: true });
});

afterEach(() => {
  uninstall?.();
  uninstall = undefined;
  dom.window.close();
});

/** An element of `html` in the page, drawn with a box (jsdom lays nothing out). */
function drawn(html: string): HTMLElement {
  dom.window.document.body.insertAdjacentHTML("beforeend", html);
  const element = dom.window.document.body.lastElementChild as HTMLElement;
  element.getBoundingClientRect = () => new dom.window.DOMRect(10, 10, 200, 80);
  return element;
}

test("the pages' hidden title tooltip is not an open overlay", () => {
  uninstall = installTooltips(dom.window.document);
  const tip = dom.window.document.querySelector('[role="tooltip"]');
  expect(tip?.hasAttribute("hidden")).toBe(true);
  expect(openOverlay(dom.window.document)).toBe(false);
});

test("a visible tooltip or dialog is open", () => {
  const tooltip = drawn('<div role="tooltip" class="ui-tooltip ui-glass">Hint</div>');
  expect(openOverlay(dom.window.document)).toBe(true);
  tooltip.remove();
  drawn('<div role="dialog" class="ui-tooltip ui-card ui-glass">Card</div>');
  expect(openOverlay(dom.window.document)).toBe(true);
});

test("a dialog closed by [hidden] is no longer open", () => {
  const dialog = drawn('<div role="dialog" class="ui-popup">Dialog</div>');
  expect(openOverlay(dom.window.document)).toBe(true);
  dialog.hidden = true;
  expect(openOverlay(dom.window.document)).toBe(false);
  dialog.hidden = false;
  expect(openOverlay(dom.window.document)).toBe(true);
});

test("hidden by an ancestor, inert, aria-hidden, display none, visibility hidden or no box: not drawn", () => {
  const doc = dom.window.document;
  const cases = [
    '<div hidden><div role="menu"></div></div>',
    '<div inert><div role="menu"></div></div>',
    '<div aria-hidden="true"><div role="menu"></div></div>',
    '<div><div role="menu" style="display: none"></div></div>',
    '<div><div role="menu" style="visibility: hidden"></div></div>',
  ];
  for (const html of cases) {
    const wrapper = drawn(html);
    const menu = wrapper.querySelector<HTMLElement>('[role="menu"]')!;
    menu.getBoundingClientRect = () => new dom.window.DOMRect(10, 10, 200, 80);
    expect(`${html}: ${isRendered(menu)}`).toBe(`${html}: false`);
    expect(openOverlay(doc)).toBe(false);
    wrapper.remove();
  }
  const empty = doc.createElement("div");
  empty.setAttribute("role", "menu");
  doc.body.append(empty);
  expect(isRendered(empty)).toBe(false);
});
