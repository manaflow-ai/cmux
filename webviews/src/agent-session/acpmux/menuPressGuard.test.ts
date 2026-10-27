// A press outside an open composer menu only closes it (menuPressGuard.ts). A chip that still says
// its menu is open when no menu is on screen must not take every press in the composer (Leo,
// 2026-10-21: "WHY THE FUCK CANT I CLICK THESE BUTTONS"). The queued rows' buttons always pass, so
// these presses land on the field, which the guard swallows whenever a chip's menu is on screen.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { installMenuPressGuard } from "./menuPressGuard";

const scope = globalThis as Record<string, unknown>;
const hadElement = "Element" in scope;
const savedElement = scope.Element;
let release: (() => void) | undefined;
afterEach(() => {
  release?.();
  release = undefined;
  if (hadElement) scope.Element = savedElement;
  else delete scope.Element;
});

/**
 * A composer with a chip that says its menu is open (`chip` adds its attributes), `menu` beside
 * it, the field, and a queued row's Delete button.
 */
function composer(menu: string, chip = "") {
  const dom = new JSDOM(
    `<!doctype html><body><div id="root"><div class="acpmux-composer">
      <button id="chip" aria-haspopup="listbox" aria-expanded="true"${chip}>Model</button>${menu}
      <div id="field" contenteditable="true"></div>
      <div class="acpmux-composer-queue"><button id="delete">Delete</button></div>
    </div></div></body>`,
    { url: "http://localhost/" },
  );
  const doc = dom.window.document;
  // The guard reads event targets as this page's elements.
  scope.Element = dom.window.Element;
  release = installMenuPressGuard(doc);
  // What the page's own handlers (React's, on the root) see.
  const seen: string[] = [];
  for (const type of ["pointerdown", "mousedown", "click"])
    doc.getElementById("root")!.addEventListener(type, () => seen.push(type));
  const press = (id: string) => {
    const target = doc.getElementById(id)!;
    const { PointerEvent, MouseEvent } = dom.window;
    const pointer = { bubbles: true, cancelable: true, button: 0, pointerId: 1, isPrimary: true };
    const mouse = { bubbles: true, cancelable: true, button: 0, detail: 1 };
    target.dispatchEvent(new PointerEvent("pointerdown", pointer));
    target.dispatchEvent(new MouseEvent("mousedown", mouse));
    target.dispatchEvent(new PointerEvent("pointerup", pointer));
    target.dispatchEvent(new MouseEvent("mouseup", mouse));
    const click = new MouseEvent("click", mouse);
    target.dispatchEvent(click);
    return { seen: seen.splice(0), cancelled: click.defaultPrevented };
  };
  return press;
}

const TAKEN = { seen: ["pointerdown", "mousedown", "click"], cancelled: false };
const SWALLOWED = { seen: [], cancelled: true };

test("a chip left saying its menu is open, with no menu on screen, lets the field take the press", () => {
  const press = composer("");
  expect(press("field")).toEqual(TAKEN);
});

test("a chip whose named menu is gone lets the press through, though another chip's menu is open", () => {
  const press = composer(
    `<div class="ui-positioner"><div class="ui-popup">elsewhere</div></div>`,
    ` aria-controls="gone"`,
  );
  expect(press("field")).toEqual(TAKEN);
});

test("an unnamed chip left open does not count the slash menu in the field as its menu", () => {
  const press = composer(`<div class="ui-popup acpmux-slash-menu">/</div>`);
  expect(press("field")).toEqual(TAKEN);
});

test("a press outside a named menu that is open only closes it; the menu and the chips still take theirs", () => {
  const press = composer(
    `<div class="ui-popup"><div id="menu" role="listbox"><button id="option">Opus</button></div></div>`,
    ` aria-controls="menu"`,
  );
  expect(press("field")).toEqual(SWALLOWED);
  expect(press("delete")).toEqual(TAKEN);
  expect(press("option")).toEqual(TAKEN);
  expect(press("chip")).toEqual(TAKEN);
});

test("a press outside an unnamed chip's positioned menu only closes it", () => {
  const press = composer(`<div class="ui-positioner"><div class="ui-popup">menu</div></div>`);
  expect(press("field")).toEqual(SWALLOWED);
});
