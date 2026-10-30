import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { installMenuPressGuard, swallowsPress } from "../src/agent-session/acpmux/menuPressGuard";

let dom: JSDOM | undefined;
let remove: (() => void) | undefined;
const previousElement = globalThis.Element;

afterEach(() => {
  remove?.();
  remove = undefined;
  dom?.window.close();
  dom = undefined;
  if (previousElement === undefined) delete (globalThis as Record<string, unknown>).Element;
  else globalThis.Element = previousElement;
});

function fixture() {
  dom = new JSDOM(
    '<!doctype html><html><body><main><div class="acpmux-composer"><button aria-haspopup="menu" aria-expanded="true">Model</button></div><button id="action">Dictate</button></main><div class="ui-positioner"><div class="ui-popup" role="menu"></div></div></body></html>',
  );
  const view = dom.window;
  const doc = view.document;
  globalThis.Element = view.Element;
  remove = installMenuPressGuard(doc);
  const trigger = doc.querySelector<HTMLButtonElement>("[aria-haspopup]")!;
  const action = doc.querySelector<HTMLButtonElement>("#action")!;
  const received: string[] = [];
  // Menu dismissal runs in document capture; application actions run above the target,
  // like React's handlers on its root. The guard must let dismissal run first.
  doc.addEventListener("pointerdown", () => trigger.setAttribute("aria-expanded", "false"), true);
  for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"])
    doc.querySelector("main")!.addEventListener(type, () => received.push(type));
  const pointer = (type: string, pointerId = 1, isPrimary = true) => {
    const event = new view.PointerEvent(type, {
      bubbles: true,
      cancelable: true,
      button: 0,
      pointerId,
      pointerType: "mouse",
      isPrimary,
    });
    action.dispatchEvent(event);
    return event;
  };
  const mouse = (type: string, detail = 1) => {
    const event = new view.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, detail });
    action.dispatchEvent(event);
    return event;
  };
  return { view, doc, trigger, action, received, pointer, mouse };
}

test("a completed outside press only dismisses the menu and the next press works", () => {
  const f = fixture();
  f.pointer("pointerdown");
  expect(f.trigger.getAttribute("aria-expanded")).toBe("false");
  expect(f.mouse("mousedown").defaultPrevented).toBe(true);
  f.pointer("pointerup");
  f.mouse("mouseup");
  expect(f.mouse("click").defaultPrevented).toBe(true);
  expect(f.received).toEqual([]);

  f.pointer("pointerdown");
  f.mouse("mousedown");
  f.pointer("pointerup");
  f.mouse("mouseup");
  expect(f.mouse("click").defaultPrevented).toBe(false);
  expect(f.received).toEqual(["pointerdown", "mousedown", "pointerup", "mouseup", "click"]);
});

test("other press handlers can tell a press that only closes the menu (the transcript's margin drag)", () => {
  const f = fixture();
  expect(swallowsPress(f.doc)).toBe(false);
  f.pointer("pointerdown");
  expect(swallowsPress(f.doc)).toBe(true);
  f.mouse("mousedown");
  f.pointer("pointerup");
  f.mouse("mouseup");
  f.mouse("click");
  expect(swallowsPress(f.doc)).toBe(false);
  // The menu is closed now: the next press is the page's own.
  f.pointer("pointerdown");
  expect(swallowsPress(f.doc)).toBe(false);
});

test("a canceled outside gesture does not consume the next keyboard activation", () => {
  const f = fixture();
  f.pointer("pointerdown");
  f.pointer("pointercancel");
  expect(f.mouse("click", 0).defaultPrevented).toBe(false);
  expect(f.received).toEqual(["click"]);
});

test("losing window focus during an outside gesture does not consume keyboard activation", () => {
  const f = fixture();
  f.pointer("pointerdown");
  f.view.dispatchEvent(new f.view.Event("blur"));
  expect(f.mouse("click", 0).defaultPrevented).toBe(false);
  expect(f.received).toEqual(["click"]);
});

test("a keyboard activation is independent of an unfinished outside mouse press", () => {
  const f = fixture();
  f.pointer("pointerdown");
  expect(f.mouse("click", 0).defaultPrevented).toBe(false);
  expect(f.received).toEqual(["click"]);
  // The unrelated keyboard click must not release the still-active pointer's guard.
  f.pointer("pointerup");
  f.mouse("mouseup");
  expect(f.mouse("click").defaultPrevented).toBe(true);
  expect(f.received).toEqual(["click"]);
});

test("another pointer being canceled does not release the outside primary press", () => {
  const f = fixture();
  f.pointer("pointerdown", 1);
  f.pointer("pointercancel", 2, false);
  f.pointer("pointerup", 1);
  f.mouse("mouseup");
  expect(f.mouse("click").defaultPrevented).toBe(true);
  expect(f.received).toEqual([]);
});

// WebKit and Chromium dispatch click as a PointerEvent whose pointerId need not match its
// pointerdown's (WebKit reports -1); the dismissing click is still swallowed.
test("a dismissing click delivered as a PointerEvent is swallowed whatever its pointerId", () => {
  const f = fixture();
  f.pointer("pointerdown");
  f.mouse("mousedown");
  f.pointer("pointerup");
  f.mouse("mouseup");
  const click = new f.view.PointerEvent("click", {
    bubbles: true,
    cancelable: true,
    button: 0,
    detail: 1,
    pointerId: -1,
    pointerType: "mouse",
  });
  f.action.dispatchEvent(click);
  expect(click.defaultPrevented).toBe(true);
  expect(f.received).toEqual([]);
});

// A queued prompt's controls (ComposerQueue.tsx) act on the press that closes a chip's menu: Steer
// and the trash can on nightly 331e2e9 only closed the menu (Leo: "WHY CAN'T I CLICK THESE BUTTONS").
test("a press on a queued prompt's control closes the menu and still reaches the control", () => {
  dom = new JSDOM(
    '<!doctype html><html><body><main><div class="acpmux-composer"><ol class="acpmux-composer-queue"><li class="acpmux-queued"><button id="steer">Steer</button></li></ol><button aria-haspopup="menu" aria-expanded="true">Model</button><div id="field" contenteditable="true"></div></div></main><div class="ui-positioner"><div class="ui-popup" role="menu"></div></div></body></html>',
  );
  const view = dom.window;
  const doc = view.document;
  globalThis.Element = view.Element;
  remove = installMenuPressGuard(doc);
  const trigger = doc.querySelector<HTMLButtonElement>("[aria-haspopup]")!;
  const received: string[] = [];
  doc.addEventListener("pointerdown", () => trigger.setAttribute("aria-expanded", "false"), true);
  doc.querySelector("main")!.addEventListener("click", (event) => received.push((event.target as Element).id));
  const press = (target: Element) => {
    const options = { bubbles: true, cancelable: true, button: 0, pointerId: 1, pointerType: "mouse", isPrimary: true };
    target.dispatchEvent(new view.PointerEvent("pointerdown", options));
    target.dispatchEvent(new view.MouseEvent("mousedown", { ...options, detail: 1 }));
    target.dispatchEvent(new view.PointerEvent("pointerup", options));
    target.dispatchEvent(new view.MouseEvent("mouseup", { ...options, detail: 1 }));
    const click = new view.MouseEvent("click", { ...options, detail: 1 });
    target.dispatchEvent(click);
    return click;
  };
  expect(press(doc.getElementById("steer")!).defaultPrevented).toBe(false);
  expect(trigger.getAttribute("aria-expanded")).toBe("false");
  expect(received).toEqual(["steer"]);
  // The prompt field still takes nothing from the press that closes a menu.
  trigger.setAttribute("aria-expanded", "true");
  expect(press(doc.getElementById("field")!).defaultPrevented).toBe(true);
  expect(received).toEqual(["steer"]);
});
