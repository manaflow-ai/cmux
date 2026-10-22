// A press outside an open composer menu only closes it (menuPressGuard.ts). A chip that still says
// its menu is open when no menu is on screen must not take every press in the composer: the queued
// rows' buttons then did nothing (Leo, 2026-10-21: "WHY THE FUCK CANT I CLICK THESE BUTTONS").
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { installMenuPressGuard } from "./menuPressGuard";

let release: (() => void) | undefined;
afterEach(() => {
  release?.();
  release = undefined;
});

/** A composer with a chip whose menu says it is open, and a queued row's Delete button. */
function composer(menu: string, chip = "") {
  const dom = new JSDOM(
    `<!doctype html><body><div id="root"><div class="acpmux-composer">
      <button id="chip" aria-haspopup="listbox" aria-expanded="true"${chip}>Model</button>${menu}
      <div class="acpmux-composer-queue"><button id="delete">Delete</button></div>
    </div></div></body>`,
    { url: "http://localhost/" },
  );
  const doc = dom.window.document;
  release = installMenuPressGuard(doc);
  // What the page's own handlers (React's, on the root) see.
  const seen: string[] = [];
  for (const type of ["pointerdown", "mousedown", "click"])
    doc.getElementById("root")!.addEventListener(type, () => seen.push(type));
  const press = (id: string) => {
    const target = doc.getElementById(id)!;
    const { PointerEvent, MouseEvent } = dom.window;
    const pointer = { bubbles: true, cancelable: true, button: 0, pointerId: 1, isPrimary: true };
    target.dispatchEvent(new PointerEvent("pointerdown", pointer));
    target.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0, detail: 1 }));
    target.dispatchEvent(new PointerEvent("pointerup", pointer));
    target.dispatchEvent(new MouseEvent("mouseup", { bubbles: true, cancelable: true, button: 0, detail: 1 }));
    const click = new MouseEvent("click", { bubbles: true, cancelable: true, button: 0, detail: 1 });
    target.dispatchEvent(click);
    return { click };
  };
  return { seen, press };
}

test("a chip left saying its menu is open, with no menu on screen, lets the queued row's buttons take the press", () => {
  const { seen, press } = composer("");
  const { click } = press("delete");
  expect(seen).toEqual(["pointerdown", "mousedown", "click"]);
  expect(click.defaultPrevented).toBe(false);
});

test("a chip whose menu names a popup that is gone lets the press through, though another popup is open", () => {
  const { seen, press } = composer(`<div class="ui-popup">elsewhere</div>`, ` aria-controls="gone"`);
  const { click } = press("delete");
  expect(seen).toEqual(["pointerdown", "mousedown", "click"]);
  expect(click.defaultPrevented).toBe(false);
});

test("a press outside a menu that is open still only closes it", () => {
  const { seen, press } = composer(`<div class="ui-popup"><div id="menu" role="listbox">menu</div></div>`, ` aria-controls="menu"`);
  const { click } = press("delete");
  expect(seen).toEqual([]);
  expect(click.defaultPrevented).toBe(true);
});
