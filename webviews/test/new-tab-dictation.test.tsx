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
    // The suggestions' Popover (Base UI and Floating UI) reads these.
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
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

/// The New Tab page as the pane draws it: the page's dictation, aimed at the New Tab field, and
/// its mic before Send. `calls` records what the page asked the host.
async function renderNewTab(calls: [string, unknown][]) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { useDictation } = await import("../src/agent-session/acpmux/dictation");
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
        accessory={<DictationMic dictation={dictation} />}
        onAsk={noop}
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
}

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
  expect(host.querySelector<HTMLTextAreaElement>(".nt-field")!.value).toBe("fix the upload test");
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
  expect(host.querySelector<HTMLTextAreaElement>(".nt-field")!.value).toBe("fix the upload test");
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
  await act(async () => deliverDictation({ state: "starting", text: "", level: 0, cancelled: false }));
  await act(async () => deliverDictation({ state: "listening", text: "fix the", level: 0.4, cancelled: false }));
  expect(host.querySelector<HTMLTextAreaElement>(".nt-field")!.value).toBe("fix the");
  await act(async () => leave());
  await act(async () => deliverDictation({ state: "listening", text: "fix the upload", level: 0.4, cancelled: false }));
  await act(async () => deliverDictation({ state: "idle", text: "fix the upload test", level: 0, cancelled: false }));
  expect(host.querySelector<HTMLTextAreaElement>(".chat")!.value).toBe("");
  expect(calls.map(([method]) => method)).toContain("dictation.cancel");
});
