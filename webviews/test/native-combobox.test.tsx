import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Combobox } from "../src/ui/Combobox";
import { UiProvider } from "../src/ui/UiProvider";
import { comboboxDescription } from "../src/ui/popupDescriptors";
import type { PopupHost } from "../src/ui/popupHost";
import type { NativePopupEvent, NativePopupModel } from "../src/ui/nativePopup";

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

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function nativeHost() {
  const shown: NativePopupModel[] = [];
  const listeners = new Set<(event: NativePopupEvent) => void>();
  const host: PopupHost = {
    show: async () => ({ shown: false }),
    update() {},
    hide() {},
    owner: () => null,
    listen: () => () => {},
    native: {
      show: async (model) => {
        shown.push(model);
        return { shown: true };
      },
      update() {},
      hide() {},
      listen(listener) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    },
  };
  return { host, shown, listeners };
}

test("native combobox submits a picked action ID without a value payload", async () => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  const submitted: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Combobox
          inline
          label="Projects"
          suggestions={["alpha"]}
          onQuery={() => {}}
          onSubmit={(value) => submitted.push(value)}
          onCancel={() => {}}
          native={{ model: comboboxDescription({ suggestions: ["alpha"] }), anchor: () => container }}
        />
      </UiProvider>,
    );
  });
  expect(shown).toHaveLength(1);
  expect(container.querySelector('[role="option"]')).toBeNull();
  const model = shown[0]!;
  await act(async () => {
    for (const listener of listeners)
      listener({ type: "pick", popupId: model.id, revision: model.revision, id: "alpha" });
  });
  expect(submitted).toEqual(["alpha"]);
});

test("native combobox presents once its own input anchor mounts", async () => {
  const container = installDom();
  const { host, shown } = nativeHost();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Combobox
          inline
          label="Projects"
          suggestions={["alpha"]}
          onQuery={() => {}}
          onSubmit={() => {}}
          onCancel={() => {}}
          native={{ model: comboboxDescription({ suggestions: ["alpha"] }) }}
        />
      </UiProvider>,
    );
  });
  expect(shown).toHaveLength(1);
  expect(container.querySelector('[role="option"]')).toBeNull();
});
