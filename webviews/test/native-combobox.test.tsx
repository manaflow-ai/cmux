import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Combobox } from "../src/ui/Combobox";
import { UiProvider } from "../src/ui/UiProvider";
import { Menu, MenuButton, MenuPopup } from "../src/ui/Menu";
import { Popover } from "../src/ui/Popover";
import { comboboxDescription } from "../src/ui/popupDescriptors";
import type { PopupHost } from "../src/ui/popupHost";
import type { NativePopupEvent, NativePopupModel } from "../src/ui/nativePopup";

const menuModel = {
  side: "bottom" as const,
  align: "start" as const,
  width: 220,
  rows: [
    { id: "hold", kind: "action" as const, label: "Keep open", keepOpen: true },
    { id: "done", kind: "action" as const, label: "Done" },
  ],
};

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

test("controlled native menu closes on terminal picks and reopens without a dismiss event", async () => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  const changes: boolean[] = [];
  function Fixture() {
    const [open, setOpen] = useState(true);
    return (
      <>
        <button type="button" data-reopen onClick={() => setOpen(true)}>Reopen</button>
        <Menu open={open} onOpenChange={(next) => { changes.push(next); setOpen(next); }} native={{ model: menuModel }}>
          <MenuButton label="Actions">Actions</MenuButton>
          <MenuPopup>Page rows must not mount</MenuPopup>
        </Menu>
      </>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<UiProvider container={container} popupHost={host}><Fixture /></UiProvider>);
  });
  expect(shown).toHaveLength(1);
  const model = shown[0]!;
  await act(async () => {
    for (const listener of listeners) listener({ type: "pick", popupId: model.id, revision: model.revision, id: "hold" });
  });
  expect(changes).toEqual([]);
  expect(listeners.size).toBe(1);
  await act(async () => {
    for (const listener of listeners) listener({ type: "pick", popupId: model.id, revision: model.revision, id: "done" });
  });
  expect(changes).toEqual([false]);
  expect(listeners.size).toBe(0);
  await act(async () => container.querySelector<HTMLButtonElement>("[data-reopen]")!.click());
  expect(shown).toHaveLength(2);
});

test("native popover preserves Escape cancellation details", async () => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  const changes: { open: boolean; escape: boolean | undefined }[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Popover open label="Details" anchor={container} native={{ model: menuModel, anchor: () => container }}
          onOpenChange={(open, details) => changes.push({ open, escape: details?.escape })}>
          Page rows must not mount
        </Popover>
      </UiProvider>,
    );
  });
  const model = shown[0]!;
  await act(async () => {
    for (const listener of listeners) listener({ type: "dismiss", popupId: model.id, revision: model.revision, reason: "escape" });
  });
  expect(changes).toEqual([{ open: false, escape: true }]);
});
