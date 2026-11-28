// The c-75d9afaef8 follow-up (Leo, 2026-11-22: "when im pasting attachments or whatever, there's a breif
// moment where i see the caret at the beginning of the composer after the preview for the attachment
// has already shown up, and then it doesn't follow as fast, it follows with a delay. we can't have
// that."): under load, a pasted screenshot's chip took up to 705 ms to settle in WebKit. Its upload
// re-rendered the box once a percent, and the box gave the memoized field six new handlers each time,
// so the editor rendered again and wrote every one of its attributes again: a stream of mutations
// that kept WebKit laying out frames while the chip waited to paint.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, useState } from "react";
import type { Root } from "react-dom/client";
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

const SHOT: PendingAttachment = { id: "pasted-shot", name: "Screenshot.png", image: true, progress: 0 };

test("an upload's progress leaves the prompt's editor alone: no render, no attribute written", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ComposerBox } = await import("../src/agent-session/acpmux/ComposerBox");
  const box = createRef<ComposerBoxHandle>();
  const field = createRef<MarkdownFieldHandle>();
  let tick: ((progress: number) => void) | undefined;
  let paste: (() => void) | undefined;
  function Host() {
    const [pending, setPending] = useState<PendingAttachment[]>([]);
    const [value, setValue] = useState("");
    // The intake's progress (attachmentIntakeModel.ts): one new chip list a percent.
    tick = (progress) => setPending((chips) => chips.map((chip) => ({ ...chip, progress })));
    paste = () => {
      setPending([SHOT]);
      box.current?.place([SHOT], "paste");
    };
    return (
      <ComposerBox
        handle={box}
        fieldRef={(handle) => {
          field.current = handle;
        }}
        // A host as Composer.tsx is: a new field object and new callbacks on every render.
        field={{
          value,
          onChange: (next) => setValue(next),
          onKeyDown: () => {},
          onBeforeInput: () => false,
          attributes: { role: "combobox", "aria-label": "Prompt", "aria-expanded": "false" },
        }}
        attachments={[]}
        pending={pending}
        setAttachments={() => {}}
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
  await settle();
  const editor = host.querySelector<HTMLElement>("[contenteditable]")!;
  expect(editor.getAttribute("aria-label")).toBe("Prompt");
  const written: string[] = [];
  const watch = new dom.window.MutationObserver((records) => {
    for (const record of records) written.push(record.attributeName ?? "");
  });
  watch.observe(editor, { attributes: true });
  for (let percent = 1; percent <= 100; percent++) await act(async () => tick!(percent / 100));
  await settle();
  for (const record of watch.takeRecords()) written.push(record.attributeName ?? "");
  watch.disconnect();
  // A big screenshot's upload ticks a hundred times while WebKit draws its chip; each write of the
  // same aria value was a mutation it laid the frame out again for.
  expect(written).toEqual([]);
  expect(field.current?.inlineIds()).toEqual([SHOT.id]);
});
