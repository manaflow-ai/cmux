import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AddProjectPanel } from "./AddProjectPanel";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
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
    "MouseEvent",
    "getComputedStyle",
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
    MouseEvent: dom.window.MouseEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame,
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

test("keeps the native chooser panel open when browse rejects", async () => {
  const container = installDom();
  let attempts = 0;
  const close = () => {};
  await act(async () => {
    root = createRoot(container);
    root.render(
      <AddProjectPanel
        host={{}}
        onBrowse={() => {
          attempts += 1;
          return Promise.reject(new Error("Folder access was denied."));
        }}
        onPick={() => {}}
        onClose={close}
      />,
    );
  });

  const choose = async (label: string) => {
    const item = [...container.querySelectorAll("li")].find((candidate) => candidate.textContent?.includes(label));
    expect(item).toBeTruthy();
    await act(async () => item!.dispatchEvent(new MouseEvent("click", { bubbles: true, button: 0 })));
  };
  await choose("This Mac");
  await choose("Local folder");
  await act(async () => Promise.resolve());

  expect(container.querySelector('[data-add-project-step="source"]')).toBeTruthy();
  expect(container.textContent).toContain("Folder access was denied.");
  expect([...container.querySelectorAll("button")].some((button) => button.textContent === "Retry")).toBe(true);
  expect(attempts).toBe(1);
  const retry = [...container.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent === "Retry",
  );
  expect(retry).toBeTruthy();
  await act(async () => retry!.click());
  await act(async () => Promise.resolve());
  expect(attempts).toBe(2);
});

test("closes Add Project when the native chooser is cancelled", async () => {
  const container = installDom();
  let closed = 0;
  await act(async () => {
    root = createRoot(container);
    root.render(
      <AddProjectPanel
        host={{}}
        onBrowse={async () => undefined}
        onPick={() => {}}
        onClose={() => {
          closed += 1;
        }}
      />,
    );
  });
  const choose = async (label: string) => {
    const item = [...container.querySelectorAll("li")].find((candidate) => candidate.textContent?.includes(label));
    expect(item).toBeTruthy();
    await act(async () => item!.dispatchEvent(new MouseEvent("click", { bubbles: true, button: 0 })));
  };
  await choose("This Mac");
  await choose("Local folder");
  expect(closed).toBe(1);
});
