// Keyboard Shortcuts keeps the search field as the primary keyboard surface: Up and Down move
// through the filtered rows, Return starts recording for the selected editable row, and Escape
// clears the query without moving focus away from the search field. A row's keys are the control
// that records new ones, and Remove on an action's only key keeps the action listed with no keys.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
let saved: Array<readonly [string, boolean, unknown]> = [];
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  // The recorder popover (Base UI) measures, observes and schedules frames: the DOM globals it reads.
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  const replacements: Record<string, unknown> = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    DOMRect: window.DOMRect,
    MutationObserver: window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);
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

test("a click on a row's keys records new ones, and Remove keeps the action listed with no keys", async () => {
  const { createRoot } = await import("react-dom/client");
  const { KeybindingsPage } = await import("../src/pages/keybindings/KeybindingsPage");
  const { MockKeybindingsProvider } = await import("../src/pages/keybindings/mockProvider");
  const { KeybindingsStore } = await import("../src/pages/keybindings/store");
  const { KeybindingOps } = await import("../src/pages/keybindings/types");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/keybindings/generated/strings.json")).default;
  const strings = createStrings(table);
  act(() => root?.unmount());
  const provider = new MockKeybindingsProvider();
  const store = new KeybindingsStore(provider, { newKey: () => "key" });
  root = createRoot(host);
  act(() => root!.render(<KeybindingsPage store={store} strings={strings} />));
  await act(async () => store.reload());

  const row = (title: string) =>
    [...host.querySelectorAll<HTMLElement>(".keys-row:not(.removed)")].find(
      (candidate) => candidate.querySelector(".keys-command-title")?.textContent === title,
    );
  const click = async (element: Element | null | undefined) => {
    expect(element).toBeTruthy();
    const MouseEvent = host.ownerDocument.defaultView!.MouseEvent;
    await act(async () => {
      element!.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      await Promise.resolve();
    });
  };
  const record = async (stroke: string) => {
    await act(async () => {
      provider.press(stroke);
      provider.finish();
      await Promise.resolve();
    });
    await act(async () => store.reload());
  };
  const lastSet = () => provider.calls.filter(({ op }) => op === KeybindingOps.set).at(-1)?.params;

  const doc = host.ownerDocument;
  // The keys are the control: no pencil button, and a click records the row's new keys in the
  // recorder popover, focus staying where it was.
  expect(host.querySelector(".keys-change")).toBeNull();
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  expect(provider.recording).toBe(true);
  expect(row("Go to File")?.classList.contains("recording")).toBe(true);
  const recorder = () => doc.querySelector<HTMLElement>(".keys-recorder");
  const recorderKeys = () => recorder()?.querySelector<HTMLElement>(".keys-recorder-keys");
  const close = () => recorder()?.querySelector<HTMLButtonElement>(".keys-recorder-button");
  const writes = () =>
    provider.calls.filter(({ op }) => op === KeybindingOps.set || op === KeybindingOps.remove).length;
  // Before a key comes, the recorder shows the row's own keys and how to delete them.
  expect(recorderKeys()?.textContent).toBe("⌘P");
  expect(recorder()?.textContent).toContain("⌫");
  expect(close()?.textContent).toContain("esc");

  // Keys another action has: the recorder names it before anything is saved.
  await act(async () => {
    provider.press("cmd+shift+p");
    await Promise.resolve();
  });
  expect(recorder()?.querySelectorAll(".keys-recorder-cap").length).toBe(3);
  expect(recorder()?.querySelector(".keys-recorder-conflict")?.textContent).toContain("Open Command Palette");

  // A click on the keys starts over; Close (as Return) saves the keys recorded.
  await click(recorderKeys());
  expect(provider.recording).toBe(true);
  expect(recorderKeys()?.textContent).toBe("⌘P");
  await act(async () => {
    provider.press("cmd+shift+p");
    await Promise.resolve();
  });
  await click(close());
  await act(async () => store.reload());
  expect(provider.recording).toBe(false);
  expect(recorder()).toBeNull();
  expect(lastSet()).toEqual({
    command: "palette.files",
    key: "cmd+shift+p",
    when: null,
    replaces: { key: "cmd+p", when: null },
    idempotency_key: "key",
  });

  // Return in the app's recorder saves too.
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  await record("cmd+j");
  expect(lastSet()).toMatchObject({ command: "palette.files", key: "cmd+j", replaces: { key: "cmd+shift+p" } });

  // With no new keys, Close and a bare Return only close.
  const before = writes();
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  await click(close());
  expect(provider.recording).toBe(false);
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  await act(async () => {
    provider.press("return");
    await Promise.resolve();
  });
  expect(provider.recording).toBe(false);
  expect(recorder()).toBeNull();
  expect(writes()).toBe(before);

  // A bare Delete first removes the row's keys: the action stays, with none.
  await click(row("New Tab")?.querySelector(".keys-key-button"));
  await act(async () => {
    provider.press("delete");
    await Promise.resolve();
  });
  await act(async () => store.reload());
  const removed = provider.calls.filter(({ op }) => op === KeybindingOps.remove).map(({ params }) => params);
  expect(removed).toContainEqual({ command: "tab.new", key: "cmd+t", when: null, idempotency_key: "key" });
  expect(row("New Tab")?.querySelector(".keys-key-button")?.textContent).toBe(strings.t("keybindings.page.notSet"));

  // Remove says what it does, and on the action's only key the action stays, with no keys.
  const remove = row("Open Command Palette")?.querySelector(".keys-remove");
  expect(remove?.getAttribute("title")).toBe(strings.t("keybindings.page.remove"));
  await click(remove);
  await act(async () => store.reload());
  const unset = row("Open Command Palette");
  expect(unset?.querySelector(".keys-key-button")?.textContent).toBe(strings.t("keybindings.page.notSet"));
  expect(unset?.querySelector(".keys-remove")).toBeNull();
  expect(unset?.querySelector(".keys-reset")).toBeTruthy();

  // A click on "Not Set" binds the action again: a new entry, nothing to replace.
  await click(unset?.querySelector(".keys-key-button"));
  await record("cmd+shift+o");
  expect(lastSet()).toEqual({ command: "palette.open", key: "cmd+shift+o", when: null, idempotency_key: "key" });
  const palette = [...host.querySelectorAll<HTMLElement>(".keys-row")].filter(
    (candidate) => candidate.querySelector(".keys-command-title")?.textContent === "Open Command Palette",
  );
  expect(palette.map((candidate) => candidate.querySelector(".keys-col-key")?.textContent)).toEqual(["⇧⌘O"]);
});
