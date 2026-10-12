// l10n-allow-file: test fixture prompts and dictated words, not shipped UI.
// The New Tab composer's dictation (Leo ask, 10-12): the agent composer's mic sits beside Send on
// the New Tab page too, wired to the same dictation, so dictated words land in the New Tab field.
// Right-click on the mic offers Hide dictation button: the persisted `agentPane.showDictation`
// setting (the host writes it with `pane.showDictation` and pushes it back as the `composer`
// event), which hides the mic in every composer until Settings shows it again.
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
  const call = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    return null;
  };
  function Page() {
    const field = useRef(null);
    const dictation = useDictation(field, call);
    return (
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you/src/app"
        dictationField={field}
        accessory={
          <DictationMic dictation={dictation} onShowDictation={(show) => void call("pane.showDictation", { show })} />
        }
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
  expect(mic()!.nextElementSibling?.classList.contains("nt-enter")).toBe(true);
  await act(async () => mic()!.click());
  expect(calls.map(([method]) => method)).toContain("dictation.toggle");
  const { deliverDictation } = await import("../src/agent-session/acpmux/dictation");
  await act(async () => deliverDictation({ state: "starting", text: "", level: 0, cancelled: false }));
  await act(async () => deliverDictation({ state: "listening", text: "fix the upload", level: 0.4, cancelled: false }));
  await act(async () => deliverDictation({ state: "idle", text: "fix the upload test", level: 0, cancelled: false }));
  expect(host.querySelector<HTMLInputElement>(".nt-field")!.value).toBe("fix the upload test");
});

test("right-click Hide dictation button hides the mic in every composer until Settings shows it", async () => {
  const calls: [string, unknown][] = [];
  await renderNewTab(calls);
  await act(async () =>
    mic()!.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 40 })),
  );
  const hide = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent === "Hide dictation button",
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
