// An attachment placed in the prompt's text is an editor node (composer/inlineNode.ts), and only a
// field made with a place to draw it (`onInlineViews`, the composer's) has that node. Any other
// field keeps its text as written: U+FFFC, a word, U+FFFC stays text, and nothing can be placed.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { inlineToken, linkAttachment } from "../src/agent-session/acpmux/attachments";
import type { MarkdownFieldHandle, MarkdownFieldProps } from "../src/agent-session/acpmux/MarkdownField";
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

async function render(
  onInlineViews?: (views: ReadonlyMap<string, HTMLElement>) => void,
  props: Partial<MarkdownFieldProps> = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { MarkdownField } = await import("../src/agent-session/acpmux/MarkdownField");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <MarkdownField ref={handle} value={DRAFT} onChange={() => {}} onInlineViews={onInlineViews} {...props} />,
    ),
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

// Review (Codex): the draft's tokens became nodes in a dispatch made before the editor was there to
// write the document, so the field told the composer its prompt was empty and the draft was lost.
test("a draft read back keeps its words and its placed attachment", async () => {
  const changes: string[] = [];
  // The handle acts from `onReady` on, and the draft is the field's document then.
  const ready: string[] = [];
  const editor = await render(() => {}, {
    onChange: (markdown) => changes.push(markdown),
    onReady: () => ready.push(handle.current!.value()),
  });
  expect(editor.querySelector("[data-inline-attachment]")?.getAttribute("data-inline-attachment")).toBe("word");
  expect(ready).toHaveLength(1);
  for (const markdown of [...changes, ...ready, handle.current!.value()]) {
    expect(markdown).toContain("see ");
    expect(markdown).toContain(" here");
    expect(markdown).toContain(inlineToken("word"));
  }
});

test("a file link's id with a path in it comes back as the same attachment", async () => {
  const link = linkAttachment("/tmp/my file~1 100%.pdf", false);
  const draft = `see ${inlineToken(link.id)} here`;
  const told: string[][] = [];
  const changes: string[] = [];
  const editor = await render((views) => told.push([...views.keys()]), {
    value: draft,
    onChange: (markdown) => changes.push(markdown),
  });
  expect(editor.querySelector("[data-inline-attachment]")?.getAttribute("data-inline-attachment")).toBe(link.id);
  expect(told.at(-1)).toEqual([link.id]);
  expect(handle.current!.value()).toBe(draft);
  for (const markdown of changes) expect(markdown).toContain(inlineToken(link.id));
});

/// A paste of `data` into the editor, as the browser sends it.
function paste(editor: HTMLElement, data: Record<string, string>) {
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { getData: (type: string) => data[type] ?? "", types: Object.keys(data), files: [] },
  });
  act(() => {
    editor.dispatchEvent(event);
  });
}

// Review (Codex): a U+FFFC in a page's rich text is not an attachment: the paste is its plain text,
// through the surface's input seam like any other.
test("a rich paste with a U+FFFC in it pastes as plain text", async () => {
  const pasted: { text: string; paste: boolean }[] = [];
  const editor = await render(() => {}, {
    onBeforeInput: (text, state) => {
      pasted.push({ text, paste: state.paste });
      return true;
    },
  });
  paste(editor, { "text/plain": "bold \uFFFC here", "text/html": "<b>bold \uFFFC here</b>" });
  expect(pasted).toEqual([{ text: "bold \uFFFC here", paste: true }]);
  expect(editor.querySelector("b, strong")).toBeNull();
  expect(editor.querySelectorAll("[data-inline-attachment]").length).toBe(1);
});

test("a copy of a placed attachment pastes as a copy of it", async () => {
  const pasted: string[] = [];
  const editor = await render(() => {}, {
    onBeforeInput: (text) => {
      pasted.push(text);
      return true;
    },
  });
  paste(editor, { "text/html": '<span data-inline-attachment="word"></span>' });
  await settle();
  expect(pasted).toEqual([]);
  const ids = [...editor.querySelectorAll("[data-inline-attachment]")].map((node) =>
    node.getAttribute("data-inline-attachment"),
  );
  expect(ids).toHaveLength(2);
  expect(ids).toContain("word");
  expect(ids.find((id) => id !== "word")).toMatch(/^word~copy-[0-9a-f]{8}$/);
});

// Review (root): the editor read the draft's tokens with no ids, so the person's U+FFFC before a
// word took the attachment's opening mark: `before` became an attachment and `one` stayed text.
test("the person's U+FFFC just before a word and an attachment stays their text", async () => {
  const MARK = "\uFFFC";
  const draft = `x ${MARK}before${inlineToken("one")}after${MARK} y`;
  const told: string[][] = [];
  const changes: string[] = [];
  const editor = await render((views) => told.push([...views.keys()]), {
    value: draft,
    onChange: (markdown) => changes.push(markdown),
    isInlineAttachment: (id) => id === "one",
  });
  const ids = [...editor.querySelectorAll("[data-inline-attachment]")].map((node) =>
    node.getAttribute("data-inline-attachment"),
  );
  expect(ids).toEqual(["one"]);
  expect(told.at(-1)).toEqual(["one"]);
  expect(editor.textContent).toBe(`x ${MARK}beforeafter${MARK} y`);
  expect(handle.current!.value()).toBe(draft);
  for (const markdown of changes) expect(markdown).toBe(draft);
});
