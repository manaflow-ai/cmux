// l10n-allow-file: the mounted folder ask uses the pane's string table.
// A New Tab can stay mounted while its selected folder waits for confirmation. The confirmation
// must remain mounted through a failed Use attempt so the person can retry or cancel the prompt.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NewTabFolderAsk } from "./NewTabFolderAsk";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
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
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

test("keeps Use and Cancel mounted after a failed home-folder confirmation", () => {
  const ask = { cwd: "/Users/you", reason: "home" as const };
  const use = () => {};
  const cancel = () => {};
  act(() => root!.render(<NewTabFolderAsk ask={ask} onUse={use} onCancel={cancel} />));
  expect(container.querySelector(".acpmux-newtab-folder-ask")).toBeTruthy();
  expect(container.querySelectorAll(".acpmux-folder-choice-button")).toHaveLength(2);

  act(() => root!.render(<NewTabFolderAsk ask={ask} error="Folder is unavailable" onUse={use} onCancel={cancel} />));
  expect(container.textContent).toContain("Folder is unavailable");
  expect(container.querySelectorAll(".acpmux-folder-choice-button")).toHaveLength(2);
});

test("disables Use while home-folder confirmation is in flight", () => {
  const ask = { cwd: "/Users/you", reason: "home" as const };
  const use = () => {};
  const cancel = () => {};
  act(() => root!.render(<NewTabFolderAsk ask={ask} confirming onUse={use} onCancel={cancel} />));
  const buttons = container.querySelectorAll<HTMLButtonElement>(".acpmux-folder-choice-button");
  expect(buttons).toHaveLength(2);
  expect(buttons[0]?.disabled).toBe(true);
  expect(buttons[1]?.disabled).toBe(false);
});
