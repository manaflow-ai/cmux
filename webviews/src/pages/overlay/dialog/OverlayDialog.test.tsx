// The overlay page's dialog: presses and edits go to the host with every value, Return and Escape
// press the spec's default and cancel buttons, and a safe-default dialog draws its destructive
// choices as a quiet row with its check boxes last.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { OverlayDialog } from "./OverlayDialog";
import type { DialogState, DialogValue } from "./types";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "KeyboardEvent",
  "ResizeObserver",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installDom() {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const w = dom.window as unknown as Record<string, unknown>;
  for (const key of GLOBALS) saved.set(key, scope[key]);
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
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  });
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

const quit: DialogState = {
  id: 7,
  title: "Quit cmux?",
  lines: ["2 terminals are running."],
  fields: [
    { kind: "check", id: "dontAsk", title: "Don't ask again" },
    { kind: "text", id: "note", label: "Note", secure: false },
  ],
  buttons: [
    { id: "end", title: "End Everything", role: "destructive" },
    { id: "cancel", title: "Cancel", role: "cancel" },
    { id: "keep", title: "Keep Sessions", role: "default" },
  ],
  keys: { return: "keep", escape: "cancel", command: {} },
  layout: "safeDefault",
  values: { dontAsk: false, note: "" },
  focus: null,
};

async function render(dialog: DialogState) {
  installDom();
  const presses: { button: string; values: Record<string, DialogValue> }[] = [];
  const edits: Record<string, DialogValue>[] = [];
  const layouts: unknown[] = [];
  root = createRoot(dom!.window.document.getElementById("root")!);
  await act(async () => {
    root!.render(
      <OverlayDialog
        dialog={dialog}
        onPress={(button, values) => presses.push({ button, values })}
        onEdit={(values) => edits.push(values)}
        onLayout={(card) => layouts.push(card)}
      />,
    );
  });
  // The dialog portals into the body.
  return { host: dom!.window.document.body, presses, edits, layouts };
}

function key(target: Element, init: KeyboardEventInit) {
  act(() => {
    target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, ...init }));
  });
}

test("a click presses its button with every value", async () => {
  const { host, presses } = await render(quit);
  act(() => (host.querySelector('[data-button="keep"]') as HTMLButtonElement).click());
  expect(presses).toEqual([{ button: "keep", values: { dontAsk: false, note: "" } }]);
});

test("Return presses the default and Escape the cancel button, from inside a field", async () => {
  const { host, presses } = await render(quit);
  const field = host.querySelector('[data-field="note"]')!;
  key(field, { key: "Enter" });
  key(field, { key: "Escape" });
  expect(presses.map((press) => press.button)).toEqual(["keep", "cancel"]);
});

test("the first text field takes the keyboard, never a button", async () => {
  const { host } = await render(quit);
  // The dialog moves the focus in after it opens, a few frames on.
  const field = host.querySelector('[data-field="note"]');
  for (let frame = 0; frame < 30 && dom!.window.document.activeElement !== field; frame++) {
    await act(async () => {
      await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
    });
  }
  expect(dom!.window.document.activeElement).toBe(host.querySelector('[data-field="note"]'));
});

test("a safe-default dialog draws its destructive choice quiet, under the main row, and its check box last", async () => {
  const { host } = await render(quit);
  const card = host.querySelector(".overlay-dialog")!;
  const main = [...card.querySelectorAll(".overlay-dialog-buttons button")].map((node) =>
    node.getAttribute("data-button"),
  );
  const quiet = [...card.querySelectorAll(".overlay-dialog-quiet button")].map((node) =>
    node.getAttribute("data-button"),
  );
  expect(main).toEqual(["cancel", "keep"]);
  expect(quiet).toEqual(["end"]);
  expect(card.lastElementChild?.querySelector('[data-field="dontAsk"]')).not.toBeNull();
  expect(card.querySelector(".overlay-dialog-keyhint")).toBeNull();
});

test("an edit sends every value, and the press after it carries the edit", async () => {
  const { host, presses, edits } = await render(quit);
  act(() => (host.querySelector('[data-field="dontAsk"]') as HTMLInputElement).click());
  expect(edits.at(-1)).toEqual({ dontAsk: true, note: "" });
  act(() => (host.querySelector('[data-button="keep"]') as HTMLButtonElement).click());
  expect(presses.at(-1)?.values).toEqual({ dontAsk: true, note: "" });
});

test("a standard dialog shows each button's key and tells the host its card", async () => {
  const { host, layouts } = await render({
    ...quit,
    layout: "standard",
    buttons: [
      { id: "cancel", title: "Cancel", role: "cancel", hint: "⎋", hintLabel: "Escape" },
      { id: "keep", title: "Keep", role: "default", hint: "↩", hintLabel: "Return" },
    ],
  });
  const hints = [...host.querySelectorAll(".overlay-dialog-keyhint")].map((node) => node.textContent);
  expect(hints).toEqual(["⎋", "↩"]);
  expect(host.querySelector('[data-button="keep"]')?.getAttribute("aria-keyshortcuts")).toBe("Return");
  expect(layouts.length).toBeGreaterThan(0);
});
