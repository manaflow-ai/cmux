// The composer's placed attachments (composer/inlineAttachments.tsx) with a field whose value the
// consumer holds, as the New Tab page holds its own (#26567's review at 91b9614b):
// 1. a draft read before its attachments came keeps their tokens as text: once they come, each is
//    its attachment in the text;
// 2. attachments added while nothing is placed in the text (the strip view, shell mode) go into it
//    when placing starts;
// 3. a sent attachment is gone for good: an undo of the send's clear brings back no node of it.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, useRef, useState } from "react";
import type { Root } from "react-dom/client";
import { inlineToken, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
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

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
async function until(ready: () => boolean) {
  for (let turn = 0; turn < 200 && !ready(); turn++) await settle();
}

const FILE: ComposerAttachment = {
  id: "kept-later",
  kind: "link",
  name: "notes.txt",
  mimeType: "text/plain",
  size: 5,
  path: "/tmp/notes.txt",
};

type Controls = {
  setAttachments(next: ComposerAttachment[]): void;
  setPlacing(on: boolean): void;
  setText(next: string): void;
  sent(ids: string[]): void;
};

/// A field and the hook, as the New Tab page wires them: the consumer holds the value and the
/// attachments, and draws the hook's chips.
async function render(initial: { text: string; attachments?: ComposerAttachment[]; placing?: boolean }) {
  const { createRoot } = await import("react-dom/client");
  const { MarkdownField } = await import("../src/agent-session/acpmux/MarkdownField");
  const { useInlineAttachments } = await import("../src/agent-session/acpmux/composer/inlineAttachments");
  const field = createRef<MarkdownFieldHandle>();
  const controls = createRef<Controls>() as { current: Controls | null };
  function Harness() {
    const [text, setText] = useState(initial.text);
    const [attachments, setAttachmentsState] = useState<ComposerAttachment[]>(initial.attachments ?? []);
    const [placing, setPlacing] = useState(initial.placing ?? true);
    const attachmentsRef = useRef(attachments);
    attachmentsRef.current = attachments;
    const inline = useInlineAttachments({
      field,
      text,
      attachments,
      attachmentsRef,
      setAttachments: (update) => setAttachmentsState((current) => update(current)),
      pending: [],
      cancel: () => {},
      retry: () => {},
      expand: () => {},
      placing: () => placing,
    });
    controls.current = {
      setAttachments: (next) => setAttachmentsState(next),
      setPlacing,
      setText,
      sent: (ids) => inline.sent(ids),
    };
    return (
      <>
        <MarkdownField
          ref={field}
          value={text}
          onChange={(value) => {
            inline.edited(value);
            setText(value);
          }}
          onInlineViews={inline.onInlineViews}
          isInlineAttachment={inline.known}
        />
        {inline.chips}
      </>
    );
  }
  root = createRoot(host);
  await act(async () => root!.render(<Harness />));
  await until(() => !!field.current?.element() && !!host.querySelector(".acpmux-md"));
  for (let turn = 0; turn < 5; turn++) await settle();
  return { field, controls: controls.current! };
}

const nodes = () =>
  [...host.querySelectorAll("[data-inline-attachment]")].map((node) => node.getAttribute("data-inline-attachment"));
const text = () => host.querySelector(".acpmux-md")?.textContent ?? "";

test("a draft read before its attachment came places it once it comes", async () => {
  const { controls } = await render({ text: `read ${inlineToken(FILE.id)} please` });
  await act(async () => controls.setAttachments([FILE]));
  await until(() => nodes().includes(FILE.id));
  expect(nodes()).toEqual([FILE.id]);
  expect(text()).not.toContain(FILE.id);
  await until(() => !!host.querySelector(".acpmux-md-inline-chip"));
  expect(host.querySelector(".acpmux-md-inline-chip")?.textContent).toContain("notes.txt");
});

test("attachments added while nothing is placed go into the text when placing starts", async () => {
  const { controls } = await render({ text: "look", attachments: [FILE], placing: false });
  expect(nodes()).toEqual([]);
  await act(async () => controls.setPlacing(true));
  await until(() => nodes().includes(FILE.id));
  expect(nodes()).toEqual([FILE.id]);
});

test("an undo of a send's clear brings back no node of what was sent", async () => {
  const { field, controls } = await render({ text: `see ${inlineToken(FILE.id)}`, attachments: [FILE] });
  await until(() => nodes().includes(FILE.id));
  // The send: the attachments went, the prompt clears.
  await act(async () => {
    controls.sent([FILE.id]);
    controls.setAttachments([]);
    controls.setText("");
  });
  await settle();
  expect(nodes()).toEqual([]);
  await act(async () => field.current!.undo());
  await settle();
  await settle();
  expect(nodes()).toEqual([]);
  expect(text()).toContain("see");
});
