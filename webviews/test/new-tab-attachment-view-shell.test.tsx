// Two things the review of the New Tab field's inline attachments (#26567) found:
// - A file dropped while the page is in shell mode went into the command as an attachment node:
//   the drop's placing read only the attachment view, never shell mode. Shell mode takes no
//   attachment in its text, as the chat composer's shell field does: the file waits in the strip for
//   the next prompt, and the command runs as typed.
// - In Settings' strip view the page still drew the field's inline chips, and the strip drew every
//   attachment too: a draft's attachments showed twice. The strip alone shows them, and its × takes
//   the attachment's node out of the text, so the inline view brings back none and the prompt sends none.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import {
  type ComposerAttachment,
  type DroppedKind,
  inlineTokenIds,
  type LinkItem,
} from "../src/agent-session/acpmux/attachments";
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
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "MutationObserver",
  "getSelection",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>").window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
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

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings({ attachmentView: "inline" });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
async function until(check: () => boolean) {
  for (let tries = 0; tries < 500 && !check(); tries += 1) await settle();
}

async function render(asked: unknown[][], shells: string[]) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const localPaths = async (_kind: DroppedKind, _files: File[]): Promise<LinkItem[]> => [
    { path: "/Users/you/Downloads/build.zip", folder: false },
  ];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you/src/app"
        localPaths={localPaths}
        onAsk={(...args) => asked.push(args)}
        onOpen={noop}
        onSearch={noop}
        onShell={(command) => shells.push(command)}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  await until(() => Boolean(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")));
  return field;
}

async function dropZip() {
  const file = new File([new Uint8Array([0x50, 0x4b, 0x03, 0xff])], "build.zip", { type: "application/zip" });
  const drop = new window.Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(drop, "dataTransfer", { value: { files: [file], types: ["Files"] } });
  await act(async () => {
    window.document.body.dispatchEvent(drop);
  });
}

const inlineChips = (field: HTMLElement) => field.querySelectorAll(".acpmux-md-inline-chip").length;
const stripChips = () => host.querySelectorAll(".acpmux-attachments .acpmux-attachment").length;

test("a file dropped in shell mode waits in the strip: the command holds no attachment and runs as typed", async () => {
  const asked: unknown[][] = [];
  const shells: string[] = [];
  const field = await render(asked, shells);
  const handle = field.acpmuxMarkdownField!;
  await act(async () => {
    handle.focus();
    handle.type("!ls -la");
  });
  await until(() => Boolean(host.querySelector(".nt-shell-glyph")));
  expect(host.querySelector(".nt-shell-glyph")).not.toBeNull();

  await dropZip();
  await until(() => stripChips() > 0 || inlineChips(field) > 0);
  // A few more turns: a placement lands after the drop's read.
  for (let turn = 0; turn < 20; turn++) await settle();

  // The command's text holds no attachment node, drawn or not.
  expect(inlineTokenIds(handle.value())).toEqual([]);
  expect(field.querySelector(".acpmux-md-inline")).toBeNull();
  expect(inlineChips(field)).toBe(0);
  // The file waits in the strip for the next prompt, as the chat composer keeps it in shell mode.
  expect(stripChips()).toBe(1);

  const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () =>
    editor.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
  );
  await settle();
  expect(shells).toEqual(["ls -la"]);
  expect(asked.length).toBe(0);
});

test("the both view shows a draft's attachment in the text and in the strip; the strip's × takes both", async () => {
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings({ attachmentView: "both" });
  try {
    const asked: unknown[][] = [];
    const shells: string[] = [];
    const field = await render(asked, shells);
    const handle = field.acpmuxMarkdownField!;
    await act(async () => handle.focus());
    await dropZip();
    await until(() => inlineChips(field) === 1);
    // Placed in the text, as the inline view places it, and listed in the strip too.
    await until(() => stripChips() === 1);
    expect(inlineChips(field)).toBe(1);
    expect(inlineTokenIds(handle.value()).length).toBe(1);

    const remove = host.querySelector<HTMLButtonElement>(".acpmux-attachments .acpmux-attachment-remove");
    expect(remove).not.toBeNull();
    await act(async () => remove!.click());
    await settle();
    expect(stripChips()).toBe(0);
    expect(inlineChips(field)).toBe(0);
    expect(inlineTokenIds(handle.value())).toEqual([]);
  } finally {
    // A failure here must not leave the next tests on the both view.
    setComposerSettings({ attachmentView: "inline" });
  }
});

test("the strip view shows a draft's attachments once, in the strip; its × takes the node out of the text", async () => {
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings({ attachmentView: "inline" });
  const asked: unknown[][] = [];
  const shells: string[] = [];
  const field = await render(asked, shells);
  const handle = field.acpmuxMarkdownField!;
  await act(async () => handle.focus());
  await dropZip();
  await until(() => inlineChips(field) === 1);
  await act(async () => {
    handle.focus();
    handle.setCaret(handle.plainText().length);
    handle.insertTyped("what is in this?");
  });
  // The inline view: the chip in the text, none in the strip.
  expect(inlineChips(field)).toBe(1);
  expect(stripChips()).toBe(0);

  await act(async () => setComposerSettings({ attachmentView: "strip" }));
  await settle();
  // The strip view: the strip alone shows it, once.
  expect(stripChips()).toBe(1);
  expect(inlineChips(field)).toBe(0);
  // Drawn once on the whole page: one strip chip, no chip in the text.
  expect(host.querySelectorAll(".acpmux-attachment, .acpmux-md-inline-chip").length).toBe(1);

  const remove = host.querySelector<HTMLButtonElement>(".acpmux-attachments .acpmux-attachment-remove");
  expect(remove).not.toBeNull();
  await act(async () => remove!.click());
  await settle();
  expect(stripChips()).toBe(0);
  // Its node left the text too.
  expect(inlineTokenIds(handle.value())).toEqual([]);

  // Back to the inline view: nothing comes back.
  await act(async () => setComposerSettings({ attachmentView: "inline" }));
  for (let turn = 0; turn < 10; turn++) await settle();
  expect(inlineChips(field)).toBe(0);
  expect(stripChips()).toBe(0);
  expect(inlineTokenIds(handle.value())).toEqual([]);

  const send = host.querySelector<HTMLButtonElement>('button[aria-label="Send"]');
  await act(async () => send!.click());
  await settle();
  expect(asked.length).toBe(1);
  expect(asked[0]![1]).toContain("what is in this?");
  expect(inlineTokenIds(String(asked[0]![1]))).toEqual([]);
  expect((asked[0]![5] as ComposerAttachment[] | undefined) ?? []).toEqual([]);
});
