// Leo, 2026-11-07: "I paste it and it pasted above the original picture, which would, like, extend the
// composer, even though there's, you know, why would you extend upwards if you still have space, right?"
//
// In the inline view a pasted or dropped attachment goes in the text at the caret. The composer box
// drew the strip above the text from its host's value: an attachment whose node the host's value did
// not show yet was the strip's, and for a frame the paste stood above the text, growing the composer
// upward, before it jumped into its place. The box now knows the chip is the text's from the moment
// it is placed, whatever the host's value says.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, useState } from "react";
import type { Root } from "react-dom/client";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { ComposerBoxHandle } from "../src/agent-session/acpmux/ComposerBox";
import type { PendingAttachment } from "../src/agent-session/acpmux/composer/attachmentIntakeModel";
import type { MarkdownFieldHandle } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
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
  "MouseEvent",
  "Event",
  "localStorage",
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
    MouseEvent: window.MouseEvent,
    Event: window.Event,
    localStorage: window.localStorage,
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

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
async function until(ready: () => boolean) {
  for (let turn = 0; turn < 200 && !ready(); turn++) await settle();
}

const PASTED: PendingAttachment = { id: "pasted-shot", name: "Screenshot.png", image: true };

test("a pasted attachment the host's value does not show yet is never drawn in the strip above the text", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ComposerBox } = await import("../src/agent-session/acpmux/ComposerBox");
  const box = createRef<ComposerBoxHandle>();
  const field = createRef<MarkdownFieldHandle>();
  let paste: (() => void) | undefined;
  let setValue: ((next: string) => void) | undefined;
  function Host() {
    const [attachments, setAttachments] = useState<ComposerAttachment[]>([]);
    const [pending, setPending] = useState<PendingAttachment[]>([]);
    const [value, setValueState] = useState("");
    setValue = setValueState;
    // The intake's paste (attachmentIntakeModel.ts): the chip is made and placed in the same step.
    paste = () => {
      setPending([PASTED]);
      box.current?.place([PASTED], "paste");
    };
    return (
      <ComposerBox
        handle={box}
        fieldRef={(handle) => {
          field.current = handle;
        }}
        // A host whose value has not caught up with the edit yet: the node is in the text, its token
        // not yet in `value`.
        field={{ value, onChange: () => {} }}
        attachments={attachments}
        pending={pending}
        setAttachments={(update) => setAttachments(update)}
        onRemoveAttachment={() => {}}
        onCancelAttachment={() => {}}
        fieldMenu={[]}
        chromeItems={[]}
      />
    );
  }
  root = createRoot(host);
  await act(async () => root!.render(<Host />));
  await until(() => !!field.current?.element() && !!host.querySelector(".acpmux-md"));
  await act(async () => paste!());
  // The node is in the text...
  expect(field.current?.inlineIds()).toEqual([PASTED.id]);
  // ...and the strip above it draws nothing.
  expect(host.querySelector(".acpmux-attachments")).toBeNull();
  // A value from outside that takes the node away (a command's clear) gives the still-loading chip
  // back to the strip: it is never hidden from both.
  await act(async () => setValue!("cleared by a command"));
  await until(() => field.current?.inlineIds()?.length === 0 && !!host.querySelector(".acpmux-attachments"));
  expect(field.current?.inlineIds()).toEqual([]);
  expect(host.querySelector(".acpmux-attachments")).not.toBeNull();
});
