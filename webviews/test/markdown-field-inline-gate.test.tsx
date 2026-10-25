// An attachment placed in the prompt's text is an editor node (composer/inlineNode.ts), and only a
// field made with a place to draw it (`onInlineViews`, the composer's) has that node. Any other
// field keeps its text as written: U+FFFC, a word, U+FFFC stays text, and nothing can be placed.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import type { MarkdownFieldHandle } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

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

const DRAFT = "see \uFFFCword\uFFFC here";
const handle = createRef<MarkdownFieldHandle>();
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

async function render(onInlineViews?: (views: ReadonlyMap<string, HTMLElement>) => void) {
  const { createRoot } = await import("react-dom/client");
  const { MarkdownField } = await import("../src/agent-session/acpmux/MarkdownField");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(<MarkdownField ref={handle} value={DRAFT} onChange={() => {}} onInlineViews={onInlineViews} />),
  );
  for (let turn = 0; turn < 200; turn++) {
    if (document.querySelector(".acpmux-md-field .acpmux-md")?.textContent && handle.current?.element()) break;
    await settle();
  }
  // The draft's tokens become nodes a microtask after the view is up (inlinePlugin).
  for (let turn = 0; turn < 5; turn++) await settle();
  return document.querySelector<HTMLElement>(".acpmux-md-field .acpmux-md")!;
}

test("a field with no attachment consumer keeps U+FFFC, a word, U+FFFC as its text", async () => {
  const editor = await render();
  expect(editor.textContent).toBe(DRAFT);
  expect(editor.querySelector("[data-inline-attachment]")).toBeNull();
  expect(handle.current!.text().value).toBe(DRAFT);
  expect(handle.current!.insertInline(["chip"])).toBe(false);
  expect(handle.current!.text().value).toBe(DRAFT);
});

test("the composer's field places the attachment the token names and draws it where asked", async () => {
  const told: string[][] = [];
  const editor = await render((views) => told.push([...views.keys()]));
  expect(editor.querySelector("[data-inline-attachment]")?.getAttribute("data-inline-attachment")).toBe("word");
  expect(editor.textContent).toBe("see  here");
  expect(told.at(-1)).toEqual(["word"]);
});
