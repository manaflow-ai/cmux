// The shared context menu (src/ui/ContextMenu.tsx). POLISH.md's right-click contract (Leo,
// 2026-10-08): WebKit's default menu never shows. A surface that owns its selected-text items opts
// in with `selection="menu"`; the default still leaves a selection to the host's native menu
// until every surface has its own selected-text menu.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { act, createElement } from "react";
import { installDom, restoreDom, settle } from "./viewer-empty-dom";
import { ContextMenu } from "../src/ui/ContextMenu";

let createRoot: typeof import("react-dom/client").createRoot;
let mounted: { unmount(): void; container: HTMLElement } | null = null;
beforeAll(async () => {
  installDom();
  ({ createRoot } = await import("react-dom/client"));
});
afterAll(async () => {
  unmount();
  await new Promise((resolve) => setTimeout(resolve, 20));
  restoreDom();
});
afterEach(() => unmount());

function unmount(): void {
  if (!mounted) return;
  const current = mounted;
  mounted = null;
  act(() => current.unmount());
  current.container.remove();
}

async function render(selection?: "menu"): Promise<HTMLElement> {
  unmount();
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const items = [{ id: "copy", label: "Copy", onSelect: () => {} }];
  await act(async () =>
    root.render(
      createElement(ContextMenu, { items, selection } as never, createElement("p", { id: "text" }, "some words")),
    ),
  );
  mounted = { unmount: () => root.unmount(), container };
  await settle();
  return container;
}

async function rightClickOverSelection(): Promise<MouseEvent> {
  const text = document.getElementById("text")!;
  window.getSelection()!.selectAllChildren(text);
  const event = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
  await act(async () => text.dispatchEvent(event));
  return event;
}

test('selection="menu" opens the menu over selected text, never the native one', async () => {
  await render("menu");
  const event = await rightClickOverSelection();
  expect(event.defaultPrevented).toBe(true);
  expect(document.querySelector('[role="menu"]')).not.toBeNull();
});

test("by default a selection still goes to the host's menu", async () => {
  await render();
  const event = await rightClickOverSelection();
  expect(event.defaultPrevented).toBe(false);
  expect(document.querySelector('[role="menu"]')).toBeNull();
});
