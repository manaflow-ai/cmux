// The prompt puts back the selection it had when the web view takes the keyboard back (#22798: WebKit
// moves a contenteditable's caret to its start on that focus). That kept selection belongs to the
// chat it was made in. It was keyed to the draft's text, so when the pane switched to another chat
// whose draft is the same text, the first chat's selection came back in the second chat. The field
// now keys it to its `selectionKey` (the composer passes the chat's session id).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import type { MarkdownFieldHandle } from "../src/agent-session/acpmux/MarkdownField";
import { promptField, proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

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

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const DRAFT = "fix the flaky retry test";
const handle = createRef<MarkdownFieldHandle>();

/// The field as the composer renders it for the chat `session`, holding `DRAFT`.
async function render(session: string) {
  const { createRoot } = await import("react-dom/client");
  const { MarkdownField } = await import("../src/agent-session/acpmux/MarkdownField");
  root ??= createRoot(host);
  // The composer holds the field's handle; the handle exists only for a field given a ref.
  await act(async () =>
    root!.render(<MarkdownField ref={handle} value={DRAFT} onChange={() => {}} selectionKey={session} />),
  );
  // The editor is made asynchronously: wait until its handle drives a view (a selection reads back).
  for (let turn = 0; turn < 200; turn++) {
    const field = document.querySelector(".acpmux-md-field .acpmux-md");
    if (field?.textContent === DRAFT) return;
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

test("the same chat gets its selection back when the keyboard returns", async () => {
  await render("chat-a");
  const field = promptField(document);
  await act(async () => {
    field.handle.focus();
    field.handle.writeText(DRAFT, 8, 13);
  });
  expect(selection()).toEqual({ selectionStart: 8, selectionEnd: 13 });
  await awayAndBack(async () => {
    // Away, the browser moves the caret (WebKit puts it at the start); the same draft reloads.
    await act(async () => promptField(document).handle.reset(DRAFT));
  });
  expect(selection()).toEqual({ selectionStart: 8, selectionEnd: 13 });
});

test("another chat with the same draft does not get the first chat's selection", async () => {
  await render("chat-a");
  const field = promptField(document);
  await act(async () => {
    field.handle.focus();
    field.handle.writeText(DRAFT, 8, 13);
  });
  expect(selection()).toEqual({ selectionStart: 8, selectionEnd: 13 });
  let switched = { selectionStart: -1, selectionEnd: -1 };
  await awayAndBack(async () => {
    // Away, the pane switches to chat B, whose saved draft is the same text.
    await render("chat-b");
    await act(async () => promptField(document).handle.reset(DRAFT));
    switched = selection();
  });
  expect(switched).not.toEqual({ selectionStart: 8, selectionEnd: 13 });
  // Chat B keeps its own caret; chat A's selection stays with chat A.
  expect(selection()).toEqual(switched);
});
