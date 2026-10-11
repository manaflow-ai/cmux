import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextMenu } from "../src/ui/ContextMenu";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM(
    "<!doctype html><html><body><main id=root></main></body></html>",
    { pretendToBeVisual: true },
  );
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

  await act(async () =>
    menu.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }),
    ),
  );
  expect(
    menu.querySelector('[role="menuitem"][data-highlighted]')?.textContent,
  ).toBe("Rename");
  await act(async () =>
    menu.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Enter", bubbles: true }),
    ),
  );
  expect(fixtureState.actions).toEqual(["rename"]);
  expect(document.querySelector('[role="menu"]')).toBeNull();

  await act(async () => openContextMenu(target));
  const reopened = document.querySelector<HTMLElement>('[role="menu"]')!;
  await act(async () =>
    reopened.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
    ),
  );
  expect(document.querySelector('[role="menu"]')).toBeNull();
  expect(document.activeElement).toBe(target);
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
