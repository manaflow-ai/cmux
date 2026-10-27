// Leo 2026-10-26: "and i cant delete quote block text thingy with backspace? only shift enter? strange..."
// Drive the shared composer editor's real keymap: Backspace lifts quotes without deleting text.
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
  window.scrollBy = () => {};
  const box = () => new window.DOMRect(0, 0, 100, 20);
  Object.assign(window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
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

const handle = createRef<MarkdownFieldHandle>();

async function render(markdown: string) {
  const { createRoot } = await import("react-dom/client");
  const { MarkdownField } = await import("../src/agent-session/acpmux/MarkdownField");
  root = createRoot(host);
  await act(async () => root!.render(<MarkdownField ref={handle} value={markdown} onChange={() => {}} />));
  for (let turn = 0; turn < 200; turn++) {
    if (host.querySelector("blockquote p")) return;
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  }
  throw new Error("the quote editor never came up");
}

async function backspaceAtQuoteStart() {
  const field = promptField(document);
  await act(async () => {
    field.handle.focus();
    const text = field.handle.text().value;
    const offset = text.indexOf(field.element.querySelector("blockquote p")!.textContent ?? "");
    field.handle.writeText(text, offset, offset);
  });
  await act(async () => {
    field.element.dispatchEvent(
      new window.KeyboardEvent("keydown", { key: "Backspace", code: "Backspace", bubbles: true, cancelable: true }),
    );
  });
  return field;
}

test("Backspace at the start of a quote turns it into a paragraph, retaining its text", async () => {
  await render("> Keep this quote text");
  const field = await backspaceAtQuoteStart();
  expect(field.element.querySelector("blockquote") === null).toBe(true);
  expect(field.element.firstElementChild?.tagName).toBe("P");
  expect(field.value).toBe("Keep this quote text");
});

test("Backspace in an empty quote removes the quote and leaves a usable paragraph", async () => {
  await render(">");
  const field = await backspaceAtQuoteStart();
  expect(field.element.querySelector("blockquote") === null).toBe(true);
  expect(field.element.firstElementChild?.tagName).toBe("P");
  expect(field.value).toBe("");
});

test("unwrapping a quote after another paragraph does not join or delete either paragraph", async () => {
  await render("Earlier paragraph\n\n> Keep this quote text");
  const field = await backspaceAtQuoteStart();
  expect(field.element.querySelector("blockquote") === null).toBe(true);
  expect([...field.element.children].map((node) => node.textContent)).toEqual([
    "Earlier paragraph",
    "Keep this quote text",
  ]);
  expect(field.value).toBe("Earlier paragraph\n\nKeep this quote text");
});
