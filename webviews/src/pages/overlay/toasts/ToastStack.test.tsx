// The toast stack draws what the app sends and sends the person's clicks back (ToastStack.tsx).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ToastStack } from "./ToastStack";
import type { ToastRect, ToastState } from "./types";

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
  "MouseEvent",
  "KeyboardEvent",
  "PointerEvent",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

function render(node: React.ReactNode): Document {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  const win = dom.window;
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    MouseEvent: win.MouseEvent,
    KeyboardEvent: win.KeyboardEvent,
    PointerEvent: win.MouseEvent,
    getComputedStyle: win.getComputedStyle,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const words = {
  t: (key: string) => `<${key}>`,
  format: (key: string, ...args: string[]) => `<${key}:${args.join(",")}>`,
};
const toast = (serial: number, more: Partial<ToastState> = {}): ToastState => ({
  serial,
  id: `t${serial}`,
  message: `message ${serial}`,
  closable: true,
  showsDetails: false,
  showsUndoKey: false,
  ...more,
});
const details = { title: "Details", isUndo: false, revealsDetails: true };
const undo = { title: "Undo", isUndo: true, revealsDetails: false };

function stack(toasts: ToastState[], log: string[] = [], layouts: ToastRect[][] = []) {
  return (
    <ToastStack
      toasts={toasts}
      floor={16}
      words={words}
      onAction={(serial) => log.push(`action ${serial}`)}
      onClose={(serial) => log.push(`close ${serial}`)}
      onHover={(serial, hovered) => log.push(`hover ${serial} ${hovered}`)}
      onLayout={(rects) => layouts.push(rects)}
    />
  );
}

test("the toasts draw oldest first, newest at the bottom, and say where they are", () => {
  const layouts: ToastRect[][] = [];
  const doc = render(stack([toast(1), toast(2), toast(3)], [], layouts));
  const drawn = [...doc.querySelectorAll<HTMLElement>(".cmux-toast")].map((element) => element.dataset.toastSerial);
  expect(drawn).toEqual(["1", "2", "3"]);
  expect(layouts.at(-1)?.map((rect) => rect.serial)).toEqual([1, 2, 3]);
  expect(doc.querySelector<HTMLElement>(".cmux-toasts")?.style.bottom).toBe("16px");
});

test("the action and close go back to the app with the toast's serial", () => {
  const log: string[] = [];
  const doc = render(stack([toast(7, { action: undo, showsUndoKey: true })], log));
  act(() => doc.querySelector<HTMLButtonElement>(".cmux-toast-action")!.click());
  act(() => doc.querySelector<HTMLButtonElement>(".cmux-toast-close")!.click());
  expect(log).toEqual(["action 7", "close 7"]);
  // Only the Undo Cmd-Z runs says the key.
  expect(doc.querySelector(".cmux-toast-action")?.getAttribute("aria-keyshortcuts")).toBe("Meta+Z");
  expect(doc.querySelector(".cmux-toast-close")?.getAttribute("aria-label")).toBe("<overlay.toasts.dismiss>");
});

test("Details off keeps the reason in the tooltip; on, it shows in plain words with the code under it", () => {
  const detail = "cannot copy: fs.no_space: no space left";
  const closed = render(stack([toast(1, { action: details, detail })]));
  expect(closed.querySelector(".cmux-toast-detail")).toBeNull();
  expect(closed.querySelector(".cmux-toast-message")?.getAttribute("title")).toBe(detail);
  expect(closed.querySelector(".cmux-toast-action")?.textContent).toBe("Details");
  act(() => root?.render(stack([toast(1, { action: details, detail, showsDetails: true })])));
  const open = closed;
  expect(open.querySelector(".cmux-toast-detail-text")?.textContent).toBe("<overlay.toasts.detail.noSpace>");
  expect(open.querySelector(".cmux-toast-detail-code")?.textContent).toBe(
    "<overlay.toasts.detail.errorCode:fs.no_space>",
  );
  expect(open.querySelector(".cmux-toast-action")?.textContent).toBe("<overlay.toasts.hideDetails>");
  expect(open.querySelector(".cmux-toast-action")?.getAttribute("aria-expanded")).toBe("true");
});

test("a toast that ends leaves the stack at once when motion is off", () => {
  const doc = render(stack([toast(1), toast(2)]));
  act(() => root?.render(stack([toast(2)])));
  expect([...doc.querySelectorAll<HTMLElement>(".cmux-toast")].map((element) => element.dataset.toastSerial)).toEqual([
    "2",
  ]);
});
