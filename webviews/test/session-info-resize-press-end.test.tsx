// Session Info's edge resizes it while the press lasts (SessionInfo.tsx, the panel marked
// data-resizing). The press ends on its pointerup, and also where the page never hears one: the
// window's own blur, or a move with no button down (released over another window). A resize that
// never ended would keep the panel marked resizing and resize it under a plain hover of the edge.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SessionInfoPanel } from "../src/agent-session/acpmux/session-info/SessionInfo";
import { settleReact } from "./support/domTeardown";

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

function renderPanel() {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(globals)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() =>
    root!.render(
      <SessionInfoPanel width={320} placement="push">
        <div className="acpmux-session-info__body" />
      </SessionInfoPanel>,
    ),
  );
  const panel = dom.window.document.querySelector<HTMLElement>(".acpmux-session-info")!;
  const edge = dom.window.document.querySelector<HTMLElement>(".acpmux-session-info__resize")!;
  const pointer = (target: EventTarget, type: string, clientX: number, buttons: number) =>
    act(() => {
      target.dispatchEvent(
        new dom!.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientX, buttons }),
      );
    });
  return { window: dom.window, panel, edge, pointer };
}

for (const ending of ["the window's blur", "a move with no button down"] as const)
  test(`a resize of Session Info ends on ${ending}`, () => {
    const { window, panel, edge, pointer } = renderPanel();
    pointer(edge, "pointerdown", 100, 1);
    expect(panel.hasAttribute("data-resizing")).toBe(true);
    // Held: a move with the button down and an element's blur do not end it.
    pointer(edge, "pointermove", 90, 1);
    act(() => {
      window.document.body.dispatchEvent(new window.FocusEvent("blur"));
    });
    expect(panel.hasAttribute("data-resizing")).toBe(true);
    act(() => {
      if (ending === "the window's blur") window.dispatchEvent(new window.FocusEvent("blur"));
      else
        window.document.body.dispatchEvent(
          new window.MouseEvent("pointermove", { bubbles: true, clientX: 50, buttons: 0 }),
        );
    });
    expect(panel.hasAttribute("data-resizing")).toBe(false);
  });

test("a resize of Session Info still ends on its pointerup", () => {
  const { panel, edge, pointer } = renderPanel();
  pointer(edge, "pointerdown", 100, 1);
  pointer(edge, "pointerup", 100, 0);
  expect(panel.hasAttribute("data-resizing")).toBe(false);
});
