import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextMenu } from "./ContextMenu";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("a context-menu item opens a copy submenu and child actions close the menu", async () => {
  const container = installDom();
  const selected: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ContextMenu
        items={[
          {
            id: "copy",
            label: "Copy",
            onSelect: () => undefined,
            children: [
              { id: "deeplink", label: "Copy deeplink", onSelect: () => selected.push("deeplink") },
              { id: "markdown", label: "Copy as Markdown", onSelect: () => selected.push("markdown") },
            ],
          },
        ]}
      >
        <button type="button">Chat</button>
      </ContextMenu>,
    );
  });
  const target = container.querySelector("button")!;
  await act(async () =>
    target.dispatchEvent(
      new dom!.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    ),
  );
  await act(async () => await Promise.resolve());
  expect(document.querySelector('[role="menu"]')).not.toBeNull();
  const copy = [...document.querySelectorAll<HTMLButtonElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.startsWith("Copy"),
  )!;
  await act(async () => copy.click());
  const deeplink = [...document.querySelectorAll<HTMLButtonElement>('[role="menuitem"]')].find(
    (item) => item.textContent === "Copy deeplink",
  )!;
  expect(deeplink).toBeDefined();
  await act(async () => deeplink.click());
  expect(selected).toEqual(["deeplink"]);
  expect(document.querySelector('[role="menu"]')).toBeNull();
});
