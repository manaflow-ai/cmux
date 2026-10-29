import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextMenu } from "../src/ui/ContextMenu";
import { UiProvider } from "../src/ui/UiProvider";
import type { PopupHost } from "../src/ui/popupHost";
import type { NativePopupEvent, NativePopupModel } from "../src/ui/nativePopup";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "MouseEvent",
    "KeyboardEvent",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
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

function fixture(selection?: "menu") {
  const actions: string[] = [];
  return {
    actions,
    element: (
      <ContextMenu
        selection={selection}
        items={[
          { id: "open", label: "Open", onSelect: () => actions.push("open") },
          {
            id: "rename",
            label: "Rename",
            onSelect: () => actions.push("rename"),
          },
          {
            id: "disabled",
            label: "Disabled",
            disabled: true,
            onSelect: () => actions.push("disabled"),
          },
        ]}
      >
        <button type="button" data-target>
          Target
        </button>
        <p data-copy>Selectable copy</p>
      </ContextMenu>
    ),
  };
}

function openContextMenu(target: HTMLElement) {
  target.dispatchEvent(
    new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: 80,
      clientY: 64,
    }),
  );
}

const nativeModel = {
  side: "bottom" as const,
  align: "start" as const,
  width: 220,
  rows: [{ id: "open", kind: "action" as const, label: "Open" }],
};

test("a declarative context menu keeps the page fallback without a native transport", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ContextMenu native={{ model: nativeModel }} items={[{ id: "open", label: "Open", onSelect() {} }]}>
        <button type="button" data-target>Target</button>
      </ContextMenu>,
    );
  });
  await act(async () => openContextMenu(container.querySelector<HTMLButtonElement>("[data-target]")!));
  expect(document.querySelector('[role="menuitem"]')?.textContent).toBe("Open");
});

test("a native context menu anchors nested SVG targets and routes picks without page rows", async () => {
  const container = installDom();
  const shown: NativePopupModel[] = [];
  const listeners = new Set<(event: NativePopupEvent) => void>();
  const picked: string[] = [];
  let dismissed = 0;
  const host: PopupHost = {
    show: async () => ({ shown: false }),
    update() {},
    hide() {},
    owner: () => null,
    listen: () => () => {},
    native: {
      show: async (model) => { shown.push(model); return { shown: true }; },
      update() {},
      hide() {},
      listen(listener) { listeners.add(listener); return () => { listeners.delete(listener); }; },
    },
  };
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <ContextMenu
          native={{ model: nativeModel, onDismiss: () => { dismissed++; } }}
          items={[{ id: "open", label: "Open", onSelect: () => picked.push("open") }]}
        >
          <button type="button"><svg><g><path data-target d="M0 0h1" /></g></svg></button>
        </ContextMenu>
      </UiProvider>,
    );
  });
  const button = container.querySelector("button")!;
  button.getBoundingClientRect = () => new window.DOMRect(20, 30, 40, 24);
  const event = new MouseEvent("contextmenu", { bubbles: true, cancelable: true });
  await act(async () => { container.querySelector("[data-target]")!.dispatchEvent(event); });
  expect(event.defaultPrevented).toBe(true);
  expect(shown).toHaveLength(1);
  expect(shown[0]?.anchor).toEqual({ left: 20, top: 30, right: 60, bottom: 54 });
  expect(document.querySelector('[role="menu"]')).toBeNull();
  const model = shown[0]!;
  await act(async () => {
    for (const listener of listeners) listener({ type: "pick", popupId: model.id, revision: model.revision, id: "open" });
  });
  expect(picked).toEqual(["open"]);
  await act(async () => {
    for (const listener of listeners) listener({ type: "dismiss", popupId: model.id, revision: model.revision });
  });
  expect(dismissed).toBe(1);
  expect(listeners.size).toBe(0);
});

test("opens at the pointer, skips disabled rows, selects by keyboard, and restores focus", async () => {
  const container = installDom();
  const fixtureState = fixture();
  await act(async () => {
    root = createRoot(container);
    root.render(fixtureState.element);
  });
  const target = container.querySelector<HTMLButtonElement>("[data-target]")!;

  await act(async () => openContextMenu(target));
  const menu = document.querySelector<HTMLElement>('[role="menu"]')!;
  expect(menu.style.left).toBe("80px");
  expect(menu.style.top).toBe("64px");
  expect(menu.querySelectorAll('[role="menuitem"]')).toHaveLength(3);

  await act(async () => menu.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })));
  expect(menu.querySelector('[role="menuitem"][data-highlighted]')?.textContent).toBe("Rename");
  await act(async () => menu.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
  expect(fixtureState.actions).toEqual(["rename"]);
  expect(document.querySelector('[role="menu"]')).toBeNull();
  expect(document.activeElement).toBe(target);

  await act(async () => openContextMenu(target));
  const reopened = document.querySelector<HTMLElement>('[role="menu"]')!;
  await act(async () => reopened.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
  expect(document.querySelector('[role="menu"]')).toBeNull();
  expect(document.activeElement).toBe(target);
});

test("restores focus after a pointer action", async () => {
  const container = installDom();
  const fixtureState = fixture();
  await act(async () => {
    root = createRoot(container);
    root.render(fixtureState.element);
  });
  const target = container.querySelector<HTMLButtonElement>("[data-target]")!;

  await act(async () => openContextMenu(target));
  const menu = document.querySelector<HTMLElement>('[role="menu"]')!;
  const open = [...menu.querySelectorAll<HTMLButtonElement>('[role="menuitem"]')].find(
    (item) => item.textContent === "Open",
  )!;
  await act(async () => open.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true })));
  expect(document.querySelector('[role="menu"]')).toBe(menu);
  expect(fixtureState.actions).toEqual([]);
  // Browser pointer activation focuses the row before pointerup/click.
  open.focus();
  await act(async () => {
    open.dispatchEvent(new MouseEvent("pointerup", { bubbles: true }));
    open.click();
  });

  expect(fixtureState.actions).toEqual(["open"]);
  expect(document.querySelector('[role="menu"]')).toBeNull();
  expect(document.activeElement).toBe(target);
});

test("restores focus when clicking outside the menu", async () => {
  const container = installDom();
  const fixtureState = fixture();
  await act(async () => {
    root = createRoot(container);
    root.render(fixtureState.element);
  });
  const target = container.querySelector<HTMLButtonElement>("[data-target]")!;

  await act(async () => openContextMenu(target));
  const backdrop = document.querySelector<HTMLElement>(".ui-context-menu-backdrop")!;
  await act(async () => backdrop.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true })));

  expect(document.querySelector('[role="menu"]')).toBeNull();
  expect(document.activeElement).toBe(target);
});

test("skips restoration when an action synchronously removes the opener", async () => {
  const container = installDom();
  function RemovingFixture() {
    const [visible, setVisible] = useState(true);
    return visible ? (
      <ContextMenu items={[{ id: "remove", label: "Remove", onSelect: () => setVisible(false) }]}>
        <button type="button" data-target>
          Target
        </button>
      </ContextMenu>
    ) : (
      <p data-after>Removed</p>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<RemovingFixture />);
  });
  const target = container.querySelector<HTMLButtonElement>("[data-target]")!;

  await act(async () => openContextMenu(target));
  const menu = document.querySelector<HTMLElement>('[role="menu"]')!;
  await act(async () => menu.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })));

  expect(container.querySelector("[data-target]")).toBeNull();
  expect(container.querySelector("[data-after]")).not.toBeNull();
  expect(document.activeElement).toBe(document.body);
});

test.each(["Escape", "Enter"])("restores focus to a contenteditable opener after %s", async (key) => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ContextMenu items={[{ id: "open", label: "Open", onSelect: () => {} }]}>
        <div contentEditable data-editor suppressContentEditableWarning>
          <span data-text>Composer</span>
        </div>
      </ContextMenu>,
    );
  });
  const editor = container.querySelector<HTMLElement>("[data-editor]")!;

  await act(async () => openContextMenu(editor.querySelector<HTMLElement>("[data-text]")!));
  const menu = document.querySelector<HTMLElement>('[role="menu"]')!;
  await act(async () => menu.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true })));

  expect(document.activeElement).toBe(editor);
});

test("preserves focus deliberately moved by an action", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <>
        <ContextMenu
          items={[
            {
              id: "edit",
              label: "Edit",
              onSelect: () => container.querySelector<HTMLInputElement>("[data-destination]")!.focus(),
            },
          ]}
        >
          <button type="button" data-target>
            Target
          </button>
        </ContextMenu>
        <input data-destination aria-label="Destination" />
      </>,
    );
  });
  await act(async () => openContextMenu(container.querySelector<HTMLButtonElement>("[data-target]")!));
  const menu = document.querySelector<HTMLElement>('[role="menu"]')!;
  await act(async () => menu.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })));

  expect(document.querySelector('[role="menu"]')).toBeNull();
  expect(document.activeElement).toBe(container.querySelector("[data-destination]"));
});

test("keeps the native selection menu unless selection mode opts into the app menu", async () => {
  const container = installDom();
  const native = fixture();
  await act(async () => {
    root = createRoot(container);
    root.render(native.element);
  });
  const copy = container.querySelector<HTMLElement>("[data-copy]")!;
  const range = document.createRange();
  range.selectNodeContents(copy);
  document.getSelection()!.removeAllRanges();
  document.getSelection()!.addRange(range);
  await act(async () => openContextMenu(copy));
  expect(document.querySelector('[role="menu"]')).toBeNull();

  act(() => root!.unmount());
  const menuFixture = fixture("menu");
  await act(async () => {
    root = createRoot(container);
    root.render(menuFixture.element);
  });
  const menuCopy = container.querySelector<HTMLElement>("[data-copy]")!;
  const menuRange = document.createRange();
  menuRange.selectNodeContents(menuCopy);
  document.getSelection()!.removeAllRanges();
  document.getSelection()!.addRange(menuRange);
  await act(async () => openContextMenu(menuCopy));
  expect(document.querySelector('[role="menu"]')).not.toBeNull();
});

test("Home and End jump to the first and last enabled rows", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(fixture().element);
  });
  await act(async () => openContextMenu(container.querySelector<HTMLElement>("[data-target]")!));
  const menu = document.querySelector<HTMLElement>('[role="menu"]')!;
  const highlighted = () => menu.querySelector('[role="menuitem"][data-highlighted]')?.textContent;
  await act(async () => menu.dispatchEvent(new KeyboardEvent("keydown", { key: "End", bubbles: true })));
  expect(highlighted()).toBe("Rename");
  await act(async () => menu.dispatchEvent(new KeyboardEvent("keydown", { key: "Home", bubbles: true })));
  expect(highlighted()).toBe("Open");
});

test("a disabled row is dimmed and a long label has no tooltip", async () => {
  const container = installDom();
  const long = "Open https://example.com/a/very/long/path/that/would/stretch/the/menu/past/the/window";
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ContextMenu
        items={[
          { id: "long", label: long, onSelect: () => {} },
          { id: "off", label: "Unavailable", disabled: true, onSelect: () => {} },
        ]}
      >
        <button type="button" data-target>
          Target
        </button>
      </ContextMenu>,
    );
  });
  await act(async () => openContextMenu(container.querySelector<HTMLElement>("[data-target]")!));
  const rows = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')];
  // The selector ui.css dims must match the disabled row.
  const css = readFileSync(join(import.meta.dir, "../src/ui/ui.css"), "utf8");
  const dimmed = /([^{}]+)\{\s*opacity:\s*0\.45;\s*\}/.exec(css)![1]!.trim();
  expect(rows[1]!.matches(dimmed)).toBe(true);
  // A long label shows its own text, cut off, with no tooltip (test/tooltip-rules.ts).
  expect(rows[0]!.querySelector<HTMLElement>(".ui-menu-label")?.textContent).toBe(long);
  expect(rows[0]!.querySelector<HTMLElement>(".ui-menu-label")?.title).toBe("");
});
