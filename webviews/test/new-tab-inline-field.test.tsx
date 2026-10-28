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

async function press(target: HTMLElement, key: string) {
  const event = new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
  await act(async () => target.dispatchEvent(event));
  await settle();
}

test("a file pasted on the field draws in the field with its retry and remove controls, not in the strip", async () => {
  const field = await render([]);
  const editor = await type(field, "read ");
  // Bun's File: jsdom's has no arrayBuffer(). The New Tab page reads a pasted file itself and takes
  // no non-image one (it goes when the chat starts, #22231), so this one ends as a failed chip: the
  // state whose controls (Retry, ×) the page must still draw.
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
  // In the field, with its own Retry and ×; the strip below the field leaves a placed file out.
  expect(chip!.querySelector(".acpmux-md-inline-retry")).not.toBeNull();
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
  const editor = await type(field, `!${command}`);
  await press(editor, "Enter");
  expect(calls).toContainEqual(["shell", command]);
});
