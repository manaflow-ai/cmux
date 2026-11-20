// A drag on the picture moves it while the press lasts. The press ends on its pointerup, and also
// where the page never hears one: the window's own blur, or a move with no button down (released
// over another window). A drag that never ended would move the picture under a plain hover.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PictureCrop } from "./PictureCrop";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function renderCrop() {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(globals)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const moves: unknown[] = [];
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() =>
    root!.render(
      <PictureCrop
        url="data:,"
        size={{ width: 400, height: 300 }}
        crop={{ x: 0.5, y: 0.5, zoom: 2 }}
        onChange={(crop) => moves.push(crop)}
        labels={{ zoom: "Zoom", hint: "Drag to place" }}
      />,
    ),
  );
  const view = dom.window.document.querySelector<HTMLElement>(".lg-picture-crop-view")!;
  const pointer = (target: EventTarget, type: string, clientX: number, buttons: number) =>
    act(() => {
      target.dispatchEvent(new dom!.window.MouseEvent(type, { bubbles: true, clientX, clientY: 0, buttons }));
    });
  return { window: dom.window, view, moves, pointer };
}

for (const ending of ["the window's blur", "a move with no button down"] as const)
  test(`a drag on the picture ends on ${ending}: a later hover moves nothing`, () => {
    const { window, view, moves, pointer } = renderCrop();
    pointer(view, "pointerdown", 0, 1);
    // Held: a move with the button down moves the picture, and an element's blur does not end it.
    pointer(view, "pointermove", 10, 1);
    expect(moves).toHaveLength(1);
    act(() => {
      window.document.body.dispatchEvent(new window.FocusEvent("blur"));
    });
    pointer(view, "pointermove", 20, 1);
    expect(moves).toHaveLength(2);
    if (ending === "the window's blur") {
      act(() => {
        window.dispatchEvent(new window.FocusEvent("blur"));
      });
      // Even a move that claims a button now moves nothing: the press is over.
      pointer(view, "pointermove", 40, 1);
    } else pointer(view, "pointermove", 40, 0);
    pointer(view, "pointermove", 60, 0);
    expect(moves).toHaveLength(2);
  });
