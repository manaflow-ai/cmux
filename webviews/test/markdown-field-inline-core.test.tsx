import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { inlineToken } from "../src/agent-session/acpmux/attachments";
import type { MarkdownFieldHandle, MarkdownFieldProps } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

const scope = globalThis as Record<string, unknown>;
const globals = [
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
const saved = globals.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
const handle = createRef<MarkdownFieldHandle>();
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
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

async function render(value: string, props: Partial<MarkdownFieldProps> = {}) {
  const { createRoot } = await import("react-dom/client");
  const { MarkdownField } = await import("../src/agent-session/acpmux/MarkdownField");
  root ??= createRoot(host);
  await act(async () => root!.render(<MarkdownField ref={handle} value={value} onChange={() => {}} {...props} />));
  for (let turn = 0; turn < 200; turn++) {
    if (document.querySelector(".acpmux-md-field .acpmux-md") && handle.current) break;
    await settle();
  }
  await settle();
  return document.querySelector<HTMLElement>(".acpmux-md-field .acpmux-md")!;
}

test("strip fields keep attachment tokens as text", async () => {
  const draft = `before ${inlineToken("one")} after`;
  const editor = await render(draft);
  expect(editor.querySelector("[data-inline-attachment]")).toBeNull();
  expect(handle.current!.value()).toBe(draft);
  expect(handle.current!.insertInline(["one"])).toBe(false);
});

test("inline fields render known tokens and expose atom editing", async () => {
  const changes: string[] = [];
  const views: string[][] = [];
  const draft = `before ${inlineToken("one")} after`;
  const editor = await render(draft, {
    inlineAttachments: true,
    isInlineAttachment: (id) => id === "one",
    onInlineViews: (next) => views.push([...next.keys()]),
    onChange: (value) => changes.push(value),
  });
  expect(editor.querySelector("[data-inline-attachment=one]")).toBeTruthy();
  expect(editor.textContent).toBe("before  after");
  expect(views.at(-1)).toEqual(["one"]);
  expect(handle.current!.inlineIds()).toEqual(["one"]);
  handle.current!.setCaret(7);
  expect(handle.current!.insertInline(["two"])).toBe(true);
  expect(handle.current!.inlineIds()).toEqual(["two", "one"]);
  expect(handle.current!.value()).toContain(inlineToken("two"));
  expect(changes.at(-1)).toContain(inlineToken("two"));
});

test("Removing an inline atom keeps the remaining draft order", async () => {
  const changes: string[] = [];
  const draft = `a ${inlineToken("one")} b ${inlineToken("two")} c`;
  const editor = await render(draft, {
    inlineAttachments: true,
    isInlineAttachment: () => true,
    onInlineViews: () => {},
    onChange: (value) => changes.push(value),
  });
  expect(handle.current!.inlineIds()).toEqual(["one", "two"]);
  expect(editor.querySelector("[data-inline-attachment=one]")?.getAttribute("draggable")).toBe("true");
  handle.current!.removeInline("one");
  expect(handle.current!.inlineIds()).toEqual(["two"]);
  expect(handle.current!.value()).not.toContain(inlineToken("one"));
  expect(changes.at(-1)).not.toContain(inlineToken("one"));
});

test("inline atoms are copied with fresh ids and can be undone", async () => {
  const draft = `before ${inlineToken("one")} after`;
  await render(draft, {
    inlineAttachments: true,
    isInlineAttachment: () => true,
    onInlineViews: () => {},
  });
  handle.current!.setCaret(3);
  const beforeCopy = handle.current!.inlineIds();
  handle.current!.pasteText(inlineToken("one"));
  const afterCopy = handle.current!.inlineIds();
  expect(afterCopy).toHaveLength(beforeCopy.length + 1);
  expect(afterCopy.filter((id) => id === "one")).toHaveLength(1);
  expect(afterCopy.some((id) => id.startsWith("one~copy-"))).toBe(true);
  handle.current!.undo();
  expect(handle.current!.inlineIds()).toEqual(beforeCopy);
});

test("toggling inline mode only places known tokens and restores strip tokens", async () => {
  const draft = `before ${inlineToken("one")} and ${inlineToken("unknown")} after`;
  const editor = await render(draft, { inlineAttachments: false });
  expect(editor.querySelector("[data-inline-attachment]")).toBeNull();
  await render(draft, {
    inlineAttachments: true,
    isInlineAttachment: (id) => id === "one",
    onInlineViews: () => {},
  });
  expect(handle.current!.inlineIds()).toEqual(["one"]);
  expect(editor.querySelector("[data-inline-attachment=one]")).toBeTruthy();
  expect(handle.current!.value()).toContain(inlineToken("unknown"));
  await render(draft, { inlineAttachments: false });
  expect(handle.current!.inlineIds()).toEqual([]);
  expect(editor.querySelector("[data-inline-attachment]")).toBeNull();
  expect(handle.current!.value()).toContain(inlineToken("one"));
});

test("Backspace and Delete treat an inline atom like a character", async () => {
  const draft = `a ${inlineToken("one")} b`;
  const editor = await render(draft, {
    inlineAttachments: true,
    isInlineAttachment: () => true,
    onInlineViews: () => {},
  });
  handle.current!.setCaret(3);
  handle.current!.focus();
  editor.dispatchEvent(new KeyboardEvent("keydown", { key: "Backspace", bubbles: true, cancelable: true }));
  await settle();
  expect(handle.current!.inlineIds()).toEqual([]);
  expect(handle.current!.value()).not.toContain(inlineToken("one"));

  const second = `a ${inlineToken("two")} b`;
  await render(second, {
    inlineAttachments: true,
    isInlineAttachment: () => true,
    onInlineViews: () => {},
  });
  handle.current!.setCaret(2);
  handle.current!.focus();
  editor.dispatchEvent(new KeyboardEvent("keydown", { key: "Delete", bubbles: true, cancelable: true }));
  await settle();
  expect(handle.current!.inlineIds()).toEqual([]);
});
