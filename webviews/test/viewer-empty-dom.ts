// Test helpers for the viewer empty states: a jsdom window as globals and a React DOM client that
// sees it (installDom in beforeAll, restoreDom in afterAll).
// React DOM decides when its module first evaluates whether native `input` events drive onChange;
// bun shares one module cache across files, so this evaluates its own copy of the client build
// after the DOM exists (the pattern of src/pages/settings/testing.tsx).
import { JSDOM, VirtualConsole } from "jsdom";
import { act, type ReactNode } from "react";
import { fileURLToPath } from "node:url";
import type { Root } from "react-dom/client";

const names = [
  "window",
  "document",
  "navigator",
  "Element",
  "HTMLElement",
  "HTMLInputElement",
  "Node",
  "Event",
  "KeyboardEvent",
  "MouseEvent",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

let dom: JSDOM | null = null;
let saved = new Map<string, unknown>();
const globals = globalThis as Record<string, unknown>;
let createRoot: typeof import("react-dom/client").createRoot;

/**
 * Installs a fresh jsdom as globals and loads a React DOM client that sees it. Call from beforeAll
 * (bun shares one process and module cache across files, so this is per file, not per import).
 */
export function installDom(): void {
  dom = new JSDOM(`<!doctype html><html><head></head><body></body></html>`, {
    url: "http://localhost/",
    pretendToBeVisual: true,
    virtualConsole: new VirtualConsole(),
  });
  saved = new Map(names.map((name) => [name, globals[name]]));
  for (const name of names) globals[name] = (dom.window as unknown as Record<string, unknown>)[name];
  globals.window = dom.window;
  globals.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  globals.IS_REACT_ACT_ENVIRONMENT = true;
  const clientBuild = process.env.NODE_ENV === "production" ? "production" : "development";
  const clientPath = fileURLToPath(
    new URL(`./cjs/react-dom-client.${clientBuild}.js`, import.meta.resolve("react-dom/client")),
  );
  // Load a private copy, then put the shared one back so other files keep theirs.
  const shared = require.cache[clientPath];
  delete require.cache[clientPath];
  ({ createRoot } = require(clientPath) as typeof import("react-dom/client"));
  if (shared) require.cache[clientPath] = shared;
  else delete require.cache[clientPath];
}

/** Restores the globals installDom replaced (call from afterAll). */
export function restoreDom(): void {
  unmount();
  dom?.window.close();
  dom = null;
  for (const [name, value] of saved) {
    if (value === undefined) delete globals[name];
    else globals[name] = value;
  }
}

/** Lets pending promises and React updates run. */
export async function settle(): Promise<void> {
  await act(async () => {
    for (let index = 0; index < 4; index += 1) await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

let mounted: { root: Root; container: HTMLElement } | null = null;

/** Renders `node` into a fresh container; unmounts the previous one. */
export async function render(node: ReactNode): Promise<HTMLElement> {
  unmount();
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => root.render(node));
  mounted = { root, container };
  await settle();
  return container;
}

export function unmount(): void {
  if (!mounted) return;
  const { root, container } = mounted;
  act(() => root.unmount());
  container.remove();
  mounted = null;
}

/** Presses `key` on `target` (bubbling, as a user would). */
export async function press(target: Element, key: string, init: KeyboardEventInit = {}): Promise<void> {
  await act(async () => {
    target.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
  });
  await settle();
}

/** Types `value` into an input (replacing its text), firing React's onChange. */
export async function type(input: HTMLInputElement, value: string): Promise<void> {
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")?.set;
    setter?.call(input, value);
    input.setSelectionRange(value.length, value.length);
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  await settle();
}

export async function mouseDown(target: Element): Promise<void> {
  await act(async () => {
    target.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
  await settle();
}

export async function click(target: Element): Promise<void> {
  await act(async () => {
    (target as HTMLElement).click();
  });
  await settle();
}

export async function doubleClick(target: Element): Promise<void> {
  await act(async () => {
    target.dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
  });
  await settle();
}
