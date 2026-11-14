import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { attachUserScrollIntent, userScrollIntent } from "./userScroll";

let detach: (() => void) | undefined;
let dom: JSDOM | undefined;
afterEach(() => {
  detach?.();
  dom?.window.close();
});

function scroller() {
  dom = new JSDOM('<div id="scroll"><span>Message</span><button>Copy</button></div>');
  const node = dom.window.document.getElementById("scroll")!;
  Object.defineProperties(node, {
    offsetWidth: { value: 100 },
    clientWidth: { value: 88 },
    clientLeft: { value: 0 },
  });
  node.getBoundingClientRect = () => ({ left: 0, width: 100 }) as DOMRect;
  detach = attachUserScrollIntent(node);
  return { node, intent: userScrollIntent(node) };
}

function pointer(target: EventTarget, type: string, x: number, buttons = 1, pointerType = "mouse") {
  const event = new dom!.window.MouseEvent(type, { bubbles: true, clientX: x, buttons });
  Object.defineProperty(event, "pointerType", { value: pointerType });
  target.dispatchEvent(event);
}

test("only the native scrollbar lane starts a thumb hold, distinct from the quiet input interval", () => {
  const { node, intent } = scroller();
  pointer(node, "pointerdown", 95);
  expect(intent.isScrollbarDragging()).toBe(true);
  pointer(dom!.window.document, "pointerup", 95, 0);
  expect(intent.isScrollbarDragging()).toBe(false);
  expect(intent.isHeld()).toBe(true);

  pointer(node.querySelector("span")!, "pointerdown", 40);
  expect(intent.isScrollbarDragging()).toBe(false);
  pointer(dom!.window.document, "pointerup", 40, 0);
  pointer(node, "pointerdown", 95, 1, "touch");
  expect(intent.isScrollbarDragging()).toBe(false);
});

for (const end of ["pointercancel", "lostpointercapture", "buttons=0", "blur"])
  test(`a scrollbar hold ends after ${end}`, () => {
    const { node, intent } = scroller();
    pointer(node, "pointerdown", 95);
    if (end === "blur") dom!.window.dispatchEvent(new dom!.window.Event("blur"));
    else pointer(dom!.window.document, end === "buttons=0" ? "pointermove" : end, 95, 0);
    expect(intent.isScrollbarDragging()).toBe(false);
    expect(intent.isHeld()).toBe(true);
  });
