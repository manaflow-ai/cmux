import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { FileMenu } from "./FileMenu";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(container: HTMLElement, onToggleCollapsed = () => {}) {
  await act(async () => {
    root = createRoot(container);
    root.render(<FileMenu path="src/App.tsx" name="App.tsx" collapsed={false} onToggleCollapsed={onToggleCollapsed} />);
  });
}

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

function trigger(container: HTMLElement): HTMLButtonElement {
  return container.querySelector<HTMLButtonElement>("button.acpmux-fh-btn")!;
}

function item(label: string): HTMLButtonElement {
  return [...document.querySelectorAll<HTMLButtonElement>('[role="menuitem"]')].find(
    (candidate) => candidate.textContent === label,
  )!;
}

test("a synchronous file action returns focus to the More button", async () => {
  const container = installDom();
  let toggled = 0;
  await render(container, () => {
    toggled += 1;
  });

  await act(async () => trigger(container).click());
  await settle();
  const collapse = item("Collapse file");
  await act(async () => collapse.focus());
  await act(async () => collapse.click());
  await settle();

  expect(toggled).toBe(1);
  expect(document.activeElement).toBe(trigger(container));
});

test("a pending copy does not steal focus from a field reached afterward", async () => {
  const container = installDom();
  let finish!: () => void;
  Object.defineProperty(dom!.window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: () => new Promise<void>((resolve) => (finish = resolve)) },
  });
  await render(container);

  await act(async () => trigger(container).click());
  await settle();
  const copy = item("Copy path");
  await act(async () => copy.focus());
  await act(async () => copy.click());

  const field = document.createElement("input");
  container.append(field);
  await act(async () => field.focus());
  await act(async () => finish());
  await settle();

  expect(document.activeElement).toBe(field);
});
