import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SavedEnvironmentPanel } from "./SavedEnvironmentPanel";

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

test("keeps a saved environment usable when folder browse rejects", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <SavedEnvironmentPanel
        initial={{ kind: "local", folder: "/Users/you/src/cmux" }}
        folders={[{ id: "/Users/you/src/cmux", label: "cmux" }]}
        onBrowse={() => Promise.reject(new Error("Folder access was denied."))}
        machines={[]}
        machineFolders={() => []}
        onSave={async () => undefined}
        onClose={() => {}}
      />,
    );
  });

  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-location-button")!.click());
  await act(async () => container.querySelector<HTMLElement>("[data-choose]")!.click());
  await act(async () => Promise.resolve());

  expect(container.querySelector('[role="alert"]')?.textContent).toContain("Folder access was denied.");
  expect([...container.querySelectorAll("button")].some((button) => button.textContent === "Retry")).toBe(true);
  expect(container.querySelector(".acpmux-env-panel")).toBeTruthy();
});
