import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { DeleteChatDialog } from "./DeleteChatDialog";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "KeyboardEvent",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

async function renderOpen(onConfirm: () => void) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: w.requestAnimationFrame,
    cancelAnimationFrame: w.cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => {
    root!.render(
      <DeleteChatDialog
        open
        onOpenChange={() => undefined}
        onDismiss={() => undefined}
        onConfirm={onConfirm}
        title="Delete"
        body="Delete this chat?"
        closeLabel="Close"
      />,
    );
  });
  // The dialog moves focus after it mounts: wait for focus to land in it, a frame at a time.
  for (let frame = 0; frame < 30 && !document.activeElement?.closest(".acpmux-delete-dialog"); frame++)
    await act(async () => {
      await new Promise((resolve) => requestAnimationFrame(() => resolve(undefined)));
    });
}

test("the Delete confirmation opens on its Delete button, so Return deletes", async () => {
  let confirmed = 0;
  await renderOpen(() => confirmed++);
  const focused = document.activeElement as HTMLElement | null;
  expect(focused?.classList.contains("acpmux-delete-dialog-confirm")).toBe(true);
  // Return on the focused Delete button presses it (a native button's Enter is its click).
  await act(async () => focused?.click());
  expect(confirmed).toBe(1);
});
