// A press-drag-release session (trackPressRelease) ends when the press does, also where the page
// never hears a pointerup: a mouse let go over another window, or after the window lost focus
// mid-press. Then it picks and closes nothing, and a later release on a row picks nothing either.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { trackPressRelease, type PressReleaseHandlers } from "./pressRelease";

let dom: JSDOM | undefined;
let stop: (() => void) | undefined;

afterEach(() => {
  stop?.();
  stop = undefined;
  dom?.window.close();
  dom = undefined;
});

function session() {
  dom = new JSDOM('<!doctype html><body><button id="trigger">Model</button><div role="option">Opus</div></body>', {
    pretendToBeVisual: true,
  });
  const win = dom.window;
  const doc = win.document;
  const trigger = doc.getElementById("trigger")!;
  const row = doc.querySelector<HTMLElement>('[role="option"]')!;
  // jsdom lays nothing out: the row is under the pointer everywhere but the press point.
  let under: Element = trigger;
  (doc as unknown as { elementFromPoint: () => Element }).elementFromPoint = () => under;
  const calls: string[] = [];
  const handlers: PressReleaseHandlers = {
    hover: () => calls.push("hover"),
    pick: () => calls.push("pick"),
    close: () => calls.push("close"),
    end: (onTrigger) => calls.push(`end ${onTrigger}`),
  };
  stop = trackPressRelease({ pointerId: 1, clientX: 0, clientY: 0, currentTarget: trigger }, handlers);
  const pointer = (type: string, init: PointerEventInit = {}) =>
    doc.dispatchEvent(new win.PointerEvent(type, { pointerId: 1, clientX: 50, clientY: 50, bubbles: true, ...init }));
  /** Drags onto the row with the button down. */
  const dragOntoRow = () => {
    under = row;
    pointer("pointermove", { buttons: 1 });
  };
  return { win, trigger, calls, pointer, dragOntoRow };
}

test("the window's blur ends the press: nothing picked or closed, a later release picks nothing", () => {
  const { win, calls, pointer, dragOntoRow } = session();
  dragOntoRow();
  win.dispatchEvent(new win.Event("blur"));
  expect(calls).toEqual(["hover", "end false"]);
  pointer("pointerup");
  expect(calls).toEqual(["hover", "end false"]);
});

test("a move with no button down ends the press: the button came up outside the page", () => {
  const { calls, pointer, dragOntoRow } = session();
  dragOntoRow();
  pointer("pointermove", { buttons: 0 });
  expect(calls).toEqual(["hover", "end false"]);
  pointer("pointerup");
  expect(calls).toEqual(["hover", "end false"]);
});

test("an element's blur does not end the press: a release on the row still picks it", () => {
  const { win, trigger, calls, pointer, dragOntoRow } = session();
  dragOntoRow();
  trigger.dispatchEvent(new win.FocusEvent("blur"));
  expect(calls).toEqual(["hover"]);
  pointer("pointerup");
  expect(calls).toEqual(["hover", "pick", "end false"]);
});

test("another pointer's release does not end the press", () => {
  const { calls, pointer, dragOntoRow } = session();
  dragOntoRow();
  pointer("pointerup", { pointerId: 2 });
  pointer("pointermove", { pointerId: 2, buttons: 0 });
  expect(calls).toEqual(["hover"]);
});
