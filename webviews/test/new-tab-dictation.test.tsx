// l10n-allow-file: test fixture prompts and dictated words, not shipped UI.
// The New Tab composer's dictation (Leo ask, 10-12): the agent composer's mic sits beside Send on
// the New Tab page too, wired to the same dictation, so dictated words land in the New Tab field.
// Right-click on the mic offers Hide Dictation Button: the persisted `agentPane.showDictation`
// setting (the host writes it with `pane.showDictation` and pushes it back as the `composer`
// event), which hides the mic in every composer until the button row's Show, or Settings, shows it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import React, { act, useRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "MouseEvent",
  "KeyboardEvent",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "MutationObserver",
  "getSelection",
  "InputEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
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
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
    // The suggestions' Popover (Base UI and Floating UI) reads these (Node comes with proseMirrorGlobals).
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    // The New Tab field is the composer's Markdown field (ProseMirror).
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

/// The New Tab field (the composer's Markdown field), its handle and its editable element.
const field = () => host.querySelector<MarkdownFieldElement>(".nt-field")!;
const handle = () => field().acpmuxMarkdownField!;
const editor = () => field().querySelector<HTMLElement>("[contenteditable]")!;
/// The field's text as the person sees it.
const fieldText = () => handle().plainText();
/// The editor mounts a moment after the field; dictation writes into it once it is made.
async function fieldReady() {
  for (
    let turn = 0;
    turn < 200 && !(field()?.acpmuxMarkdownField && field().querySelector("[contenteditable]"));
    turn++
  )
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(editor()).not.toBeNull();
}
/// The words the empty field shows (its placeholder).
const placeholderText = () => field().querySelector(".acpmux-md-placeholder")!.textContent;

/// The New Tab page as the pane draws it: the page's dictation, aimed at the New Tab field, and
/// its mic before Send. `calls` records what the page asked the host.
async function renderNewTab(
  calls: [string, unknown][],
  onAsk: (harness: string, text: string, cwd?: string, model?: string) => void = noop,
) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { useDictation, isWaitingForWords } = await import("../src/agent-session/acpmux/dictation");
  const { DictationMic } = await import("../src/agent-session/acpmux/DictationMic");
  const { registerComposerHost } = await import("../src/agent-session/acpmux/composerSettings");
  const call = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    return null;
  };
  registerComposerHost((method, show) => void call(method, { show }));
  function Page() {
    const field = useRef(null);
    const dictation = useDictation(field, call);
    return (
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you/src/app"
        dictationField={field}
        dictating={isWaitingForWords(dictation.state)}
        accessory={<DictationMic dictation={dictation} />}
        onAsk={onAsk}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />
    );
  }
  root?.unmount();
  root = createRoot(host);
  await act(async () => root!.render(<Page />));
  await fieldReady();
}

test("auto-send routes finalized dictation through the normal New Tab prompt action", async () => {
  const calls: [string, unknown][] = [];
  const asks: Array<[string, string, string | undefined, string | undefined]> = [];
  const { configureDictation, deliverDictation } = await import("../src/agent-session/acpmux/dictation");
  configureDictation({ dictation: { autoSend: true } });
  try {
    await renderNewTab(calls, (harness, text, cwd, model) => asks.push([harness, text, cwd, model]));
    await act(async () => deliverDictation({ state: "starting", text: "", level: 0, cancelled: false }));
    await act(async () =>
      deliverDictation({ state: "listening", text: "open the voice settings", level: 0.4, cancelled: false }),
    );
    await act(async () =>
      deliverDictation({ state: "idle", text: "open the voice settings", level: 0, cancelled: false }),
    );
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(asks).toHaveLength(1);
    expect(asks[0]?.[0]).toBe("claude");
    expect(asks[0]?.[1]).toBe("open the voice settings");
  } finally {
    configureDictation(undefined);
  }
});

const mic = () => host.querySelector<HTMLButtonElement>(".nt-pickers .acpmux-mic");

test("the New Tab composer has the mic beside Send, and dictated words land in its field", async () => {
  const calls: [string, unknown][] = [];
  await renderNewTab(calls);
  expect(mic()).not.toBeNull();
  expect(mic()!.closest(".acpmux-mic-menu")!.nextElementSibling?.classList.contains("nt-send")).toBe(true);
  await act(async () => mic()!.click());
  expect(calls.map(([method]) => method)).toContain("dictation.toggle");
  const { deliverDictation } = await import("../src/agent-session/acpmux/dictation");
  await act(async () => deliverDictation({ state: "starting", text: "", level: 0, cancelled: false }));
  await act(async () => deliverDictation({ state: "listening", text: "fix the upload", level: 0.4, cancelled: false }));
  await act(async () => deliverDictation({ state: "idle", text: "fix the upload test", level: 0, cancelled: false }));
  expect(fieldText()).toBe("fix the upload test");
});

test("right-click Hide Dictation Button hides the mic in every composer until Settings shows it", async () => {
  const calls: [string, unknown][] = [];
  await renderNewTab(calls);
  await act(async () =>
    mic()!.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 40 })),
  );
  const hide = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent === "Hide Dictation Button",
  );
  expect(hide).toBeDefined();
  await act(async () => hide!.click());
  expect(mic()).toBeNull();
  expect(calls).toContainEqual(["pane.showDictation", { show: false }]);
  // Settings turns it back on: the host pushes the setting to every page.
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  await act(async () => setComposerSettings({ showContextUsage: true, showDictation: true }));
  expect(mic()).not.toBeNull();
});

test("updates that arrive before a render still land once each (review: the field reads back what was written)", async () => {
  await renderNewTab([]);
  const { deliverDictation } = await import("../src/agent-session/acpmux/dictation");
  await act(async () => {
    deliverDictation({ state: "starting", text: "", level: 0, cancelled: false });
    deliverDictation({ state: "listening", text: "fix the", level: 0.4, cancelled: false });
    deliverDictation({ state: "listening", text: "fix the upload", level: 0.4, cancelled: false });
    deliverDictation({ state: "idle", text: "fix the upload test", level: 0, cancelled: false });
  });
  expect(fieldText()).toBe("fix the upload test");
});

test("a session whose New Tab field goes away ends, and never writes into the chat composer", async () => {
  const calls: [string, unknown][] = [];
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { useDictation, deliverDictation } = await import("../src/agent-session/acpmux/dictation");
  type Field = import("../src/agent-session/acpmux/dictation").DictationField;
  const call = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    return null;
  };
  let leave = noop;
  /// The pane's routing: the New Tab field while it shows, else the chat composer (a plain field).
  function Pane() {
    const [newTab, setNewTab] = React.useState(true);
    leave = () => setNewTab(false);
    const newTabField = useRef<Field | null>(null);
    const chat = useRef<HTMLTextAreaElement>(null);
    const target = useRef({
      get current(): Field | null {
        const element = chat.current;
        return (
          newTabField.current ??
          (element && {
            focus: () => element.focus(),
            focused: () => document.activeElement === element,
            element: () => element,
            text: () => ({
              value: element.value,
              selectionStart: element.value.length,
              selectionEnd: element.value.length,
            }),
            writeText: (value: string) => void (element.value = value),
          })
        );
      },
    }).current;
    useDictation(target, call);
    return newTab ? (
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you/src/app"
        dictationField={newTabField}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />
    ) : (
      <textarea className="chat" aria-label="Chat" ref={chat} defaultValue="" />
    );
  }
  root?.unmount();
  root = createRoot(host);
  await act(async () => root!.render(<Pane />));
  await fieldReady();
  await act(async () => deliverDictation({ state: "starting", text: "", level: 0, cancelled: false }));
  await act(async () => deliverDictation({ state: "listening", text: "fix the", level: 0.4, cancelled: false }));
  expect(fieldText()).toBe("fix the");
  await act(async () => leave());
  await act(async () => deliverDictation({ state: "listening", text: "fix the upload", level: 0.4, cancelled: false }));
  await act(async () => deliverDictation({ state: "idle", text: "fix the upload test", level: 0, cancelled: false }));
  expect(host.querySelector<HTMLTextAreaElement>(".chat")!.value).toBe("");
  expect(calls.map(([method]) => method)).toContain("dictation.cancel");
});

// The listening look (Leo's Claude Code reference, 10-20): while a session waits for words the
// field says "Listening…"; the words then stream in live, update by update; a waveform, a finish
// key (Return glyph) and the lit mic sit beside Send until the session ends.
const finishKey = () => host.querySelector<HTMLButtonElement>(".nt-pickers .acpmux-dictation-finish");
const wave = () => host.querySelector(".nt-pickers .acpmux-dictation-wave");

test("while listening the field says Listening… until words come, then they stream in live", async () => {
  await renderNewTab([]);
  const { deliverDictation } = await import("../src/agent-session/acpmux/dictation");
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const listening = translate("dictation.listening" as Parameters<typeof translate>[0]);
  const idlePlaceholder = placeholderText();
  expect(idlePlaceholder).not.toBe(listening);
  await act(async () => deliverDictation({ state: "starting", text: "", level: 0, cancelled: false }));
  expect(placeholderText()).toBe(listening);
  expect(editor().hasAttribute("data-dictation-listening")).toBe(true);
  await act(async () => deliverDictation({ state: "listening", text: "", level: 0.2, cancelled: false }));
  expect(placeholderText()).toBe(listening);
  // Each partial lands as it arrives, before the session ends.
  await act(async () => deliverDictation({ state: "listening", text: "fix the", level: 0.5, cancelled: false }));
  expect(fieldText()).toBe("fix the");
  await act(async () => deliverDictation({ state: "listening", text: "fix the upload", level: 0.5, cancelled: false }));
  expect(fieldText()).toBe("fix the upload");
  await act(async () => deliverDictation({ state: "idle", text: "fix the upload", level: 0, cancelled: false }));
  expect(placeholderText()).toBe(idlePlaceholder);
  expect(editor().hasAttribute("data-dictation-listening")).toBe(false);
});

test("while listening the mic is lit and pressed, beside a waveform and a finish key; idle shows the mic alone", async () => {
  await renderNewTab([]);
  const { deliverDictation } = await import("../src/agent-session/acpmux/dictation");
  expect(wave()).toBeNull();
  expect(finishKey()).toBeNull();
  await act(async () => deliverDictation({ state: "listening", text: "", level: 0.6, cancelled: false }));
  expect(mic()!.getAttribute("aria-pressed")).toBe("true");
  expect(mic()!.getAttribute("data-state")).toBe("listening");
  // The mic keeps its glyph (lit by CSS); the level shows in the waveform, not inside the mic.
  expect(mic()!.querySelector("svg")).not.toBeNull();
  expect(mic()!.querySelector(".acpmux-mic-meter")).toBeNull();
  expect(wave()).not.toBeNull();
  expect(wave()!.getAttribute("aria-hidden")).toBe("true");
  const bars = wave()!.querySelectorAll<HTMLElement>("[data-bar]");
  const dots = wave()!.querySelectorAll<HTMLElement>("[data-dot]");
  expect(bars.length).toBeGreaterThan(4);
  expect(dots.length).toBeGreaterThan(0);
  // The newest level lifts the newest (rightmost) bar; the oldest still rests as a dot.
  expect(Number(bars[bars.length - 1]!.style.getPropertyValue("--level"))).toBeGreaterThan(0);
  expect(Number(bars[0]!.style.getPropertyValue("--level"))).toBe(0);
  expect(finishKey()).not.toBeNull();
  expect(finishKey()!.getAttribute("aria-label")).toBeTruthy();
  // Order in the row: waveform, finish key, mic, then Send.
  const order = [
    ...host.querySelectorAll(
      ".nt-pickers .acpmux-dictation-wave, .nt-pickers .acpmux-dictation-finish, .nt-pickers .acpmux-mic",
    ),
  ];
  expect(order.map((node) => node.classList[0])).toEqual([
    "acpmux-dictation-wave",
    "acpmux-dictation-finish",
    "acpmux-mic",
  ]);
  await act(async () => deliverDictation({ state: "idle", text: "", level: 0, cancelled: false }));
  expect(wave()).toBeNull();
  expect(finishKey()).toBeNull();
  expect(mic()!.getAttribute("aria-pressed")).toBe("false");
});

test("the finish key ends the session and keeps its words (stop, never cancel)", async () => {
  const calls: [string, unknown][] = [];
  await renderNewTab(calls);
  const { deliverDictation } = await import("../src/agent-session/acpmux/dictation");
  await act(async () => deliverDictation({ state: "starting", text: "", level: 0, cancelled: false }));
  await act(async () =>
    deliverDictation({ state: "listening", text: "rename the helper", level: 0.4, cancelled: false }),
  );
  calls.length = 0;
  // Pressed from the keyboard: the finish key has focus, not the field.
  finishKey()!.focus();
  expect(document.activeElement).toBe(finishKey());
  await act(async () => finishKey()!.click());
  expect(calls.map(([method]) => method)).toEqual(["dictation.stop"]);
  // The keyboard goes back to the field the words are in, not to the page.
  expect(document.activeElement).toBe(editor());
  await act(async () =>
    deliverDictation({ state: "finalizing", text: "rename the helper", level: 0, cancelled: false }),
  );
  await act(async () => deliverDictation({ state: "idle", text: "rename the helper", level: 0, cancelled: false }));
  expect(fieldText()).toBe("rename the helper");
});
