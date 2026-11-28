// Keyboard Shortcuts keeps the search field as the primary keyboard surface: Up and Down move
// through the filtered rows, Return starts recording for the selected editable row, and Escape
// clears the query without moving focus away from the search field.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
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

test("the shortcut search navigates rows and starts recording without losing focus", async () => {
  const { createRoot } = await import("react-dom/client");
  const { KeybindingsPage } = await import("../src/pages/keybindings/KeybindingsPage");
  const { MockKeybindingsProvider } = await import("../src/pages/keybindings/mockProvider");
  const { KeybindingsStore } = await import("../src/pages/keybindings/store");
  const { KeybindingOps } = await import("../src/pages/keybindings/types");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/keybindings/generated/strings.json")).default;
  const provider = new MockKeybindingsProvider(undefined, undefined, { captureDom: true });
  const store = new KeybindingsStore(provider);
  root = createRoot(host);
  act(() => root!.render(<KeybindingsPage store={store} strings={createStrings(table)} />));
  // The component starts the store from its first subscription. A second reload gives this test a
  // deterministic settled snapshot while the initial request is still generation-checked.
  await act(async () => store.reload());

  const search = host.querySelector<HTMLInputElement>(".keys-search")!;
  const selectedTitle = () => host.querySelector<HTMLElement>(".keys-row.selected .keys-command-title")?.textContent;
  const firstTitle = host.querySelector<HTMLElement>(".keys-row .keys-command-title")?.textContent;
  const secondTitle = host.querySelectorAll<HTMLElement>(".keys-row .keys-command-title")[1]?.textContent;
  const press = async (key: string, init: KeyboardEventInit & { keyCode?: number } = {}) => {
    const KeyboardEvent = host.ownerDocument.defaultView!.KeyboardEvent;
    let event!: globalThis.KeyboardEvent;
    await act(async () => {
      event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init });
      search.dispatchEvent(event);
      await Promise.resolve();
    });
    return event.defaultPrevented;
  };

  expect(host.ownerDocument.activeElement).toBe(search);
  await act(async () => store.setText("tab"));
  await act(async () => Promise.resolve());
  expect(search.value).toBe("tab");
  await press("Escape");
  expect(search.value).toBe("");
  expect(host.ownerDocument.activeElement).toBe(search);

  await press("ArrowDown");
  expect(selectedTitle()).toBe(firstTitle);
  expect(host.ownerDocument.activeElement).toBe(search);
  for (const composition of [{ isComposing: true }, { keyCode: 229 }]) {
    const selectedBeforeComposition = selectedTitle();
    expect(await press("ArrowDown", composition)).toBe(false);
    expect(selectedTitle()).toBe(selectedBeforeComposition);
    expect(await press("Enter", composition)).toBe(false);
    expect(provider.recording).toBe(false);
  }
  await press("ArrowDown");
  expect(selectedTitle()).toBe(secondTitle);
  await press("ArrowUp");
  expect(selectedTitle()).toBe(firstTitle);

  await press("Enter");
  expect(provider.calls.some(({ op }) => op === KeybindingOps.recordStart)).toBe(true);
  expect(provider.recording).toBe(true);
  expect(host.ownerDocument.activeElement).toBe(search);
});
