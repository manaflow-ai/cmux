// A draft value written from outside the field (synced in on open or a switch, a failed prompt put back,
// a command) must leave the caret where the person left it, focused or away. Leo: "did we fix the cursor
// going to the front/general composer fixes yet!?"
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import type { MarkdownFieldHandle } from "../src/agent-session/acpmux/MarkdownField";
import { promptField, proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getSelection",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const DRAFT = "fix the flaky retry test";
const handle = createRef<MarkdownFieldHandle>();

/// The field as the composer renders it for the chat `session`, holding `DRAFT`.
async function render(session: string, value = DRAFT) {
  const { createRoot } = await import("react-dom/client");
  const { MarkdownField } = await import("../src/agent-session/acpmux/MarkdownField");
  root ??= createRoot(host);
  // The composer holds the field's handle; the handle exists only for a field given a ref.
  await act(async () =>
    root!.render(<MarkdownField ref={handle} value={value} onChange={() => {}} selectionKey={session} />),
  );
  // The editor is made asynchronously: wait until its handle drives a view (a selection reads back).
  for (let turn = 0; turn < 200; turn++) {
    const field = document.querySelector(".acpmux-md-field .acpmux-md");
    if (field?.textContent?.startsWith(value.slice(0, 5))) return;
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  }
  throw new Error("the field's editor never came up");
}

const selection = () => {
  const { selectionStart, selectionEnd } = promptField(document).handle.text();
  return { selectionStart, selectionEnd };
};

/// The web view gives the keyboard away while the prompt has focus, then (after `between`) takes it
/// back: a focus no click placed, which puts the kept selection back.
async function awayAndBack(between: () => Promise<void>) {
  const editable = promptField(document).element;
  await act(async () => {
    editable.dispatchEvent(new window.FocusEvent("blur"));
  });
  await between();
  await act(async () => {
    editable.dispatchEvent(new window.FocusEvent("focus"));
  });
}

async function caretAt(at: number) {
  await render("chat-a");
  const field = promptField(document);
  await act(async () => {
    field.handle.focus();
    field.handle.writeText(DRAFT, at, at);
  });
}

test("a value from outside after the caret leaves the caret where the person left it", async () => {
  await caretAt(8);
  await render("chat-a", DRAFT + " now");
  expect(promptField(document).value).toBe(DRAFT + " now");
  expect(selection()).toEqual({ selectionStart: 8, selectionEnd: 8 });
});

test("a value from outside before the caret moves the caret with the text", async () => {
  await caretAt(8);
  await render("chat-a", "please " + DRAFT);
  expect(selection()).toEqual({ selectionStart: 15, selectionEnd: 15 });
});

test("a new paragraph from outside keeps the caret in the first one", async () => {
  await caretAt(8);
  await render("chat-a", DRAFT + "\n\nsecond paragraph");
  expect(selection()).toEqual({ selectionStart: 8, selectionEnd: 8 });
});

test("a draft that changed while the field was away gets the caret back where it was", async () => {
  await caretAt(8);
  await awayAndBack(async () => {
    await render("chat-a", DRAFT + " now");
  });
  expect(promptField(document).value).toBe(DRAFT + " now");
  expect(selection()).toEqual({ selectionStart: 8, selectionEnd: 8 });
});

test("an unchanged draft still gets the caret back after away and back", async () => {
  await caretAt(8);
  await awayAndBack(async () => {});
  expect(selection()).toEqual({ selectionStart: 8, selectionEnd: 8 });
});
