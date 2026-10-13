// l10n-allow-file: test fixture labels, not shipped UI.
// Optional chrome hides the macOS way (Leo, follow-up to #19756): right-click the thing itself for
// "Hide Dictation Button" (icon and label), and right-click the same area (the composer's button
// row, where it was) for "Show Dictation Button". No trip to Settings. The choice is the persisted
// `agentPane.showDictation` setting: the page asks the host to write it, and the host pushes it back
// on every launch, so a hidden mic stays hidden after a relaunch.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import React, { act, useRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    virtualConsole: new VirtualConsole(),
  });
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
    Element: window.Element,
    Node: window.Node,
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    // The project chooser's popup animates in.
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  // The settings store outlives this file under `bun test`: leave every control shown.
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  settings.setComposerSettings({ showDictation: true, showContextUsage: true });
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
/// What the page asked the host to write: `pane.showDictation` and its `show`.
const writes: [string, unknown][] = [];

/// The New Tab page as the pane draws it, with the page's mic before Send; `persisted` is the value
/// the host pushes as the page loads (the setting as cmux.json holds it).
async function renderNewTab(persisted: { showDictation: boolean }) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { useDictation } = await import("../src/agent-session/acpmux/dictation");
  const { DictationMic } = await import("../src/agent-session/acpmux/DictationMic");
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  const call = async (method: string, params?: Record<string, unknown>) => {
    if (method.startsWith("pane.")) writes.push([method, params]);
    return null;
  };
  // The host the page writes through, as App registers it.
  (
    settings as { registerComposerHost?: (write: (method: string, show: boolean) => void) => void }
  ).registerComposerHost?.((method, show) => void call(method, { show }));
  settings.setComposerSettings({ showContextUsage: true, ...persisted });
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
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<Page />));
}

const mic = () => host.querySelector<HTMLButtonElement>(".nt-pickers .acpmux-mic");
const row = () => host.querySelector<HTMLElement>(".nt-pickers")!;
const rightClick = (element: Element) =>
  act(async () =>
    element.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 40 })),
  );
const menuItems = () => [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')];
const item = (label: string) => menuItems().find((entry) => entry.textContent === label);

test("right-click the mic hides it; right-click its row shows it again", async () => {
  writes.length = 0;
  await renderNewTab({ showDictation: true });
  await rightClick(mic()!);
  const hide = item("Hide Dictation Button");
  expect(hide).toBeDefined();
  // Like macOS's Hide items: the menu row carries the thing's icon.
  expect(hide!.querySelector("svg")).not.toBeNull();
  // Only the mic's own menu opens, not the row's as well.
  expect(menuItems().length).toBe(1);
  await act(async () => hide!.click());
  expect(mic()).toBeNull();
  expect(writes).toContainEqual(["pane.showDictation", { show: false }]);

  // Where it was: the composer's button row (here, the project chooser beside it).
  await rightClick(row().querySelector("button") ?? row());
  const show = item("Show Dictation Button");
  expect(show).toBeDefined();
  await act(async () => show!.click());
  expect(mic()).not.toBeNull();
  expect(writes).toContainEqual(["pane.showDictation", { show: true }]);
});

test("a hidden mic stays hidden after a relaunch, and its row still shows it", async () => {
  writes.length = 0;
  // Relaunch: a new page, and the host pushes the setting cmux.json holds.
  await renderNewTab({ showDictation: false });
  expect(mic()).toBeNull();
  await rightClick(row());
  const show = item("Show Dictation Button");
  expect(show).toBeDefined();
  await act(async () => show!.click());
  expect(mic()).not.toBeNull();
  expect(writes).toContainEqual(["pane.showDictation", { show: true }]);
});

test("with nothing hidden, the row keeps no menu of its own", async () => {
  await renderNewTab({ showDictation: true });
  await rightClick(row());
  expect(menuItems()).toEqual([]);
});

// Review (#19783): a popup the row opens (the project chooser) draws outside the row but its events
// pass through it; a right-click in its search field keeps the field's own menu (Cut, Copy, Paste).
test("a right-click in a popup the row opened keeps its own menu", async () => {
  await renderNewTab({ showDictation: false });
  // The card's folder menu (its location row, below the bar) opens a popup outside the bar.
  await act(async () =>
    document.querySelector<HTMLButtonElement>('.acpmux-composer-context button[aria-label="Folder"]')!.click(),
  );
  const menu = document.querySelector<HTMLElement>(".acpmux-location-menu");
  expect(menu).not.toBeNull();
  expect(row().contains(menu)).toBe(false);
  await rightClick(menu!);
  expect(item("Show Dictation Button")).toBeUndefined();
});

// Review (#19783): the New Tab page draws no context ring, so its row offers no Show Context Usage.
test("the New Tab row offers Show only for what it draws", async () => {
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  await renderNewTab({ showDictation: false });
  await act(async () => settings.setComposerSettings({ showContextUsage: false }));
  await rightClick(row());
  expect(menuItems().map((entry) => entry.textContent)).toEqual(["Show Dictation Button"]);
});
