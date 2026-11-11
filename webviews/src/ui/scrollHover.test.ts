// ui/scrollHover.ts: content moving under a still pointer is no hover, and a wheel reaches every
// hover card (Leo, 2026-11-10: "just tried this touchpad scrolling the github preview is kinda bad").
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  movedFrom,
  onWheel,
  pointerPlace,
  resetPointerRestForTests,
  slidUnderStillPointer,
  trackPointerRest,
} from "./scrollHover";

afterEach(() => resetPointerRestForTests());

function page() {
  const dom = new JSDOM("<!doctype html><p id=link>link</p>");
  const doc = dom.window.document;
  trackPointerRest(doc);
  const move = (x: number, y: number, pointerType = "mouse") => {
    const event = new dom.window.MouseEvent("pointermove", { clientX: x, clientY: y, bubbles: true });
    Object.defineProperty(event, "pointerType", { value: pointerType });
    doc.body.dispatchEvent(event);
  };
  return { dom, doc, move };
}

test("an enter at the last pointer place came from content sliding under a still pointer", () => {
  const { move } = page();
  // No pointer seen yet: any enter is a real one.
  expect(slidUnderStillPointer({ clientX: 10, clientY: 20 })).toBe(false);
  move(10, 20);
  expect(pointerPlace()).toEqual({ x: 10, y: 20 });
  expect(slidUnderStillPointer({ clientX: 10, clientY: 20 })).toBe(true);
  // A real move into a target sends its enter at the new place, before its pointermove.
  expect(slidUnderStillPointer({ clientX: 12, clientY: 20 })).toBe(false);
  // Touch has no hover to guard.
  expect(slidUnderStillPointer({ clientX: 10, clientY: 20, pointerType: "touch" })).toBe(false);
});

test("a touch pointermove is not the pointer's place", () => {
  const { move } = page();
  move(10, 20);
  move(50, 60, "touch");
  expect(pointerPlace()).toEqual({ x: 10, y: 20 });
});

test("only a move to a new place counts as the pointer moving", () => {
  expect(movedFrom({ x: 10, y: 20 }, { clientX: 10, clientY: 20 })).toBe(false);
  expect(movedFrom({ x: 10, y: 20 }, { clientX: 10, clientY: 21 })).toBe(true);
  expect(movedFrom(undefined, { clientX: 10, clientY: 20 })).toBe(true);
  expect(movedFrom({ x: NaN, y: NaN }, { clientX: 10, clientY: 20 })).toBe(true);
});

test("a wheel anywhere on the page reaches every listener with its target, until it unsubscribes", () => {
  const { dom, doc } = page();
  const seen: (EventTarget | null)[] = [];
  const stop = onWheel((target) => seen.push(target));
  const link = doc.getElementById("link")!;
  link.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: 10, bubbles: true }));
  expect(seen).toEqual([link]);
  stop();
  link.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: 10, bubbles: true }));
  expect(seen).toHaveLength(1);
});
