// A press in the suggestion list keeps the field's blur from cancelling (a native scrollbar press
// blurs it with no relatedTarget). That press ends where the page hears it end, and also on the
// window's own blur: released over another window, the page hears no pointerup, and a press that
// never ended would keep the next real outside blur from cancelling.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Combobox } from "./Combobox";
import { UiProvider } from "./UiProvider";
import { settleReact } from "../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(globals)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  return dom.window.document.getElementById("root")!;
}

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

function renderCombobox() {
  const container = installDom();
  let cancels = 0;
  root = createRoot(container);
  act(() => {
    root!.render(
      <UiProvider container={container}>
        <Combobox
          inline
          label="Projects"
          suggestions={["alpha", "beta"]}
          onQuery={() => {}}
          onSubmit={() => {}}
          onCancel={() => cancels++}
        />
      </UiProvider>,
    );
  });
  const doc = container.ownerDocument;
  const input = doc.querySelector<HTMLInputElement>("input")!;
  const option = doc.querySelector<HTMLElement>('[role="option"]')!;
  expect(option).not.toBeNull();
  act(() => input.focus());
  const press = () =>
    act(() => {
      option.dispatchEvent(new dom!.window.MouseEvent("pointerdown", { bubbles: true, button: 0, buttons: 1 }));
    });
  const blurField = () => act(() => input.blur());
  return { press, blurField, cancels: () => cancels, window: dom!.window };
}

test("a list press keeps the field's blur from cancelling while it lasts", () => {
  const view = renderCombobox();
  view.press();
  view.blurField();
  expect(view.cancels()).toBe(0);
});

test("the window's blur ends a list press: the field's next outside blur cancels", () => {
  const view = renderCombobox();
  view.press();
  // Released over another window: no pointerup reaches the page, the window loses focus.
  act(() => {
    view.window.dispatchEvent(new view.window.Event("blur"));
  });
  view.blurField();
  expect(view.cancels()).toBe(1);
});
