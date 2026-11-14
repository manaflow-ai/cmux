// The New Tab field is the chat composer's Markdown field with its inline attachments (#26567).
// Two things the review of that change found:
// - A file pasted on the field went into the text as an attachment node and out of the strip, but
//   the page never drew the field's attachments: in the default inline view the file, its × and its
//   retry were gone. They draw in the field at their place, as Messages shows them.
// - The field's value is Markdown, which escapes typed punctuation (`https\:`, `\*`, `\[`). The page
//   opened, searched and ran that escaped text; an address or a shell command must go as typed.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { setComposerSettings } from "../src/agent-session/acpmux/composerSettings";
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
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const { window } = dom;
  // jsdom has no layout; ProseMirror reads these when a multi-line paste scrolls its caret.
  const box = () => new window.DOMRect(0, 0, 1, 1);
  Object.assign(window.Range.prototype, {
    getBoundingClientRect: box,
    getClientRects: () => Object.assign([box()], { item: () => box() }),
  });
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
  setComposerSettings({ attachmentView: "inline" });
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const noop = () => {};
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
async function until(ready: () => boolean) {
  for (let turn = 0; turn < 200 && !ready(); turn++) await settle();
}

async function render(calls: unknown[][]) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { omnibarContext } = await import("../src/agent-session/acpmux/omnibar");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        omnibar={omnibarContext(EMPTY_OMNIBAR)}
        lastAgent="claude"
        onAsk={(...args) => calls.push(["ask", ...args])}
        onOpen={(url) => calls.push(["open", url])}
        onSearch={(text) => calls.push(["search", text])}
        onShell={(command) => calls.push(["shell", command])}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  await until(() => !!field.acpmuxMarkdownField && !!field.querySelector("[contenteditable]"));
  return field;
}

async function type(field: MarkdownFieldElement, text: string) {
  const handle = field.acpmuxMarkdownField!;
  await act(async () => {
    handle.focus();
    handle.type(text);
  });
  await settle();
  return field.querySelector<HTMLElement>("[contenteditable]")!;
}

async function press(target: HTMLElement, key: string, init: KeyboardEventInit = {}) {
  const event = new dom.window.KeyboardEvent("keydown", {
    key,
    bubbles: true,
    cancelable: true,
    ...init,
  });
  await act(async () => target.dispatchEvent(event));
  await settle();
}

/// 600 lines (3,600 words): over the 3,500-word chip limit.
const LONG_LOG = Array.from({ length: 600 }, (_, index) => `line ${index + 1} of the build log`).join("\n");

async function pasteText(editor: HTMLElement, text: string) {
  const paste = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", {
    value: {
      files: [],
      types: ["text/plain"],
      getData: (type: string) => (type === "text/plain" ? text : ""),
    },
  });
  await act(async () => editor.dispatchEvent(paste));
  await settle();
}

function pastedChipCount() {
  return host.querySelectorAll('.acpmux-attachment-pasted, .acpmux-md-inline-chip[data-kind="file"]').length;
}

test("a file pasted on the field draws in the field with its remove control, not in the strip", async () => {
  const field = await render([]);
  const editor = await type(field, "read ");
  // Bun's File: jsdom's has no arrayBuffer(). The New Tab page reads a pasted file itself and takes
  // no non-image one (it goes when the chat starts, #22231), so this one ends as a failed chip: the
  // state whose × the page must still draw.
  const file = new File(["notes for the agent"], "notes.txt", { type: "text/plain" });
  const paste = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", {
    value: { files: [file], types: ["Files"], getData: () => "" },
  });
  await act(async () => editor.dispatchEvent(paste));
  const failed = '.nt-input .acpmux-md-inline-chip[data-state="failed"]';
  await until(() => !!host.querySelector(failed));
  const chip = host.querySelector<HTMLElement>(failed);
  expect(chip).not.toBeNull();
  expect(chip!.getAttribute("title")).toContain("notes.txt");
  // In the field, with its own ×; the strip below the field leaves a placed file out. A file the
  // page refused fails the same way again, so it shows no Retry (#37877).
  expect(chip!.querySelector(".acpmux-md-inline-retry")).toBeNull();
  const remove = chip!.querySelector<HTMLButtonElement>(".acpmux-md-inline-remove");
  expect(remove).not.toBeNull();
  expect(host.querySelectorAll(".nt-box .acpmux-attachment").length).toBe(0);
  await act(async () => remove!.click());
  await until(() => !host.querySelector(".nt-input .acpmux-md-inline-chip"));
  expect(host.querySelector(".nt-input .acpmux-md-inline-chip")).toBeNull();
  expect(host.querySelectorAll(".nt-box .acpmux-attachment").length).toBe(0);
});

test("an address with punctuation opens exactly as typed", async () => {
  const calls: unknown[][] = [];
  const field = await render(calls);
  const url = "https://example.com/a_b*c*/[x]?q=1&r=`y`#frag";
  const editor = await type(field, url);
  await press(editor, "Enter");
  expect(calls).toContainEqual(["open", url]);
});

test("a shell command with punctuation runs exactly as typed", async () => {
  const calls: unknown[][] = [];
  const field = await render(calls);
  const command = "ls *.txt && echo [done] _x_ `date` # \\n";
  const editor = await type(field, "!");
  // Commands are literal input, not a Markdown value loaded by handle.type(). The browser
  // regression in new-tab-typing also exercises the actual CommonMark input-rule path.
  for (const character of command) await act(async () => field.acpmuxMarkdownField!.insertTyped(character));
  await press(editor, "Enter");
  expect(calls).toContainEqual(["shell", command]);
});

test("a long text paste is one attachment chip in New Tab", async () => {
  const calls: unknown[][] = [];
  const field = await render(calls);
  const editor = await type(field, "before ");
  await pasteText(editor, LONG_LOG);
  expect(pastedChipCount()).toBe(1);
  expect(editor.textContent).toContain("before");
  expect(editor.textContent).not.toContain("line 600 of the build log");
});

test("pasting the same long block again opens its chip once instead of duplicating it", async () => {
  const calls: unknown[][] = [];
  const field = await render(calls);
  const editor = await type(field, "before ");
  await pasteText(editor, LONG_LOG);
  await pasteText(editor, LONG_LOG);
  expect(pastedChipCount()).toBe(0);
  expect(editor.textContent).toContain("before");
  expect(editor.textContent).toContain("line 1 of the build log");
  expect(editor.textContent).toContain("line 600 of the build log");
  await press(editor, "Enter");
  expect(calls).toContainEqual(["ask", "claude", `before ${LONG_LOG}`, undefined, "claude-opus-5-5"]);
});

test("Paste as Plain Text keeps a long New Tab paste as text", async () => {
  const calls: unknown[][] = [];
  const field = await render(calls);
  const editor = await type(field, "before ");
  await press(editor, "V", { metaKey: true, shiftKey: true });
  await pasteText(editor, LONG_LOG);
  expect(pastedChipCount()).toBe(0);
  expect(editor.textContent).toContain("line 600 of the build log");
});

test("a long paste in shell mode remains raw command text", async () => {
  const calls: unknown[][] = [];
  const field = await render(calls);
  const editor = await type(field, "!");
  await pasteText(editor, LONG_LOG);
  expect(pastedChipCount()).toBe(0);
  expect(editor.textContent).toContain("line 600 of the build log");
  await press(editor, "Enter");
  expect(calls).toContainEqual(["shell", LONG_LOG]);
});

test("a pasted chip in the strip expands back into the prompt when opened", async () => {
  setComposerSettings({ attachmentView: "strip" });
  const calls: unknown[][] = [];
  const field = await render(calls);
  const editor = await type(field, "before ");
  await pasteText(editor, LONG_LOG);
  const open = host.querySelector<HTMLButtonElement>(".acpmux-attachment-pasted-open");
  expect(open).not.toBeNull();
  // A click opens its whole text (composer/PastedTextChip.tsx); Edit in Prompt there puts it back.
  await act(async () => open!.click());
  await settle();
  const edit = [...host.ownerDocument.querySelectorAll<HTMLButtonElement>('[role="dialog"] button')].find(
    (button) => button.textContent === "Edit in Prompt",
  );
  expect(edit).toBeDefined();
  await act(async () => edit!.click());
  await settle();
  expect(host.querySelector(".acpmux-attachment-pasted")).toBeNull();
  expect(editor.textContent).toContain("before");
  expect(editor.textContent).toContain("line 600 of the build log");
});

// Review of #37674 (F1): only a paste takes the selection's place (inlineAttachments.tsx `place`). The
// New Tab page told the field every attachment was a paste, so a file dropped while the prompt was
// selected deleted it.
test("a file dropped on New Tab while its prompt is selected keeps the prompt", async () => {
  const field = await render([]);
  await type(field, "keep every word of this");
  await act(async () => field.acpmuxMarkdownField!.selectAll());
  const file = new File(["notes for the agent"], "notes.txt", { type: "text/plain" });
  const drop = new dom.window.Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(drop, "dataTransfer", {
    value: { files: [file], types: ["Files"], items: [], getData: () => "" },
  });
  await act(async () => dom.window.document.dispatchEvent(drop));
  await until(() => !!host.querySelector(".nt-input .acpmux-md-inline-chip"));
  expect(field.acpmuxMarkdownField!.value()).toContain("keep every word of this");
});
