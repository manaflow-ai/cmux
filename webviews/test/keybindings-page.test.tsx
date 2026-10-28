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
  expect(close()?.textContent).toContain("Esc");
  expect(recorder()?.querySelector(".keys-recorder-command")?.textContent).toBe("Go to File");

  // Each modifier shows the moment it goes down, before a key makes the stroke.
  const caps = () => [...(recorderKeys()?.querySelectorAll(".keys-recorder-cap") ?? [])].map((cap) => cap.textContent);
  await act(async () => {
    provider.hold("⌘");
    await Promise.resolve();
  });
  expect(caps()).toEqual(["⌘"]);
  expect(recorderKeys()?.querySelector(".keys-recorder-stroke.held")).toBeTruthy();
  await act(async () => {
    provider.hold("⇧⌘");
    await Promise.resolve();
  });
  expect(caps()).toEqual(["⇧", "⌘"]);

  // Free keys: a release saves them, with no question and no warning.
  await act(async () => {
    provider.press("cmd+shift+o");
    await Promise.resolve();
  });
  expect(caps()).toEqual(["⇧", "⌘", "O"]);
  expect(recorderKeys()?.querySelector(".keys-recorder-stroke.held")).toBeNull();
  const conflict = () => recorder()?.querySelector(".keys-recorder-conflict")?.textContent;
  await act(async () => {
    provider.release();
    await Promise.resolve();
  });
  await act(async () => store.reload());
  expect(conflict()).toBeUndefined();
  // Saved: the row shows the new keys too (it shows only keys the app holds).
  expect(row("Go to File")?.querySelector(".keys-key-button")?.textContent).toBe("⇧⌘O");
  expect(lastSet()).toEqual({
    command: "palette.files",
    key: "cmd+shift+o",
    when: null,
    replaces: { key: "cmd+p", when: null },
    idempotency_key: "key",
  });

  // A click on the keys starts over (the saved keys show); Close (as Return) saves the keys recorded.
  await click(recorderKeys());
  expect(provider.recording).toBe(true);
  expect(recorderKeys()?.textContent).toBe("⇧⌘O");
  await act(async () => {
    provider.press("cmd+u");
    await Promise.resolve();
  });
  await click(close());
  await act(async () => store.reload());
  expect(provider.recording).toBe(false);
  expect(recorder()).toBeNull();
  expect(lastSet()).toMatchObject({ command: "palette.files", key: "cmd+u", replaces: { key: "cmd+shift+o" } });

  // Return in the app's recorder saves too.
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  await record("cmd+j");
  expect(lastSet()).toMatchObject({ command: "palette.files", key: "cmd+j", replaces: { key: "cmd+u" } });

  // Every key up saves at once, the recorder stays open and its light confirms; the next key
  // starts a new shortcut that replaces it; a chord is typed with a modifier held between its
  // strokes; Escape then only closes.
  const releaseKeys = async () => {
    await act(async () => {
      provider.release();
      await Promise.resolve();
    });
    await act(async () => store.reload());
  };
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  await act(async () => {
    provider.press("cmd+k");
    await Promise.resolve();
  });
  expect(doc.querySelector(".keys-recorder-light")).toBeNull();
  // The app's order: the last modifier goes up as the release (a held "⌘" came just before it).
  await act(async () => {
    provider.hold("⌘");
    await Promise.resolve();
  });
  // A real keyboard can send one more modifier change, nothing held, right after the release
  // (while the app is asked about conflicts): the keys stay and the save goes on.
  await act(async () => {
    provider.release();
    provider.hold("");
    await Promise.resolve();
  });
  await act(async () => store.reload());
  expect(recorderKeys()?.textContent).toBe("⌘K");
  expect(lastSet()).toMatchObject({ command: "palette.files", key: "cmd+k", replaces: { key: "cmd+j" } });
  expect(recorderKeys()?.querySelector(".keys-recorder-stroke.held")).toBeNull();
  expect(provider.recording).toBe(true);
  expect(doc.querySelector(".keys-recorder-light")).toBeTruthy();
  expect(row("Go to File")?.classList.contains("recording")).toBe(true);
  await act(async () => {
    provider.press("cmd+s");
    await Promise.resolve();
  });
  await releaseKeys();
  expect(lastSet()).toMatchObject({ command: "palette.files", key: "cmd+s", replaces: { key: "cmd+k" } });
  await act(async () => {
    provider.press("cmd+k");
    provider.press("cmd+u");
    await Promise.resolve();
  });
  await releaseKeys();
  expect(lastSet()).toMatchObject({ command: "palette.files", key: "cmd+k cmd+u", replaces: { key: "cmd+s" } });
  expect(row("Go to File")?.querySelector(".keys-key-button")?.textContent).toBe("⌘K⌘U");
  const saved = writes();
  await act(async () => {
    provider.cancel();
    await Promise.resolve();
  });
  expect(recorder()).toBeNull();
  expect(writes()).toBe(saved);
  expect(row("Go to File")?.querySelector(".keys-key-button")?.textContent).toBe("⌘K⌘U");

  // A press anywhere else closes the recorder and saves keys not saved yet.
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  await act(async () => {
    provider.press("cmd+j");
    await Promise.resolve();
  });
  const MouseEvent = doc.defaultView!.MouseEvent;
  await act(async () => {
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
      doc.querySelector(".keys-title")!.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true }));
    }
    await Promise.resolve();
  });
  await act(async () => store.reload());
  expect(recorder()).toBeNull();
  expect(lastSet()).toMatchObject({ command: "palette.files", key: "cmd+j" });

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

  // Delete after a save is a new first key, never one more stroke: it removes the saved keys.
  await click(row("Close Tab")?.querySelector(".keys-key-button"));
  await act(async () => {
    provider.press("cmd+shift+w");
    await Promise.resolve();
  });
  await releaseKeys();
  await act(async () => {
    provider.press("delete");
    await Promise.resolve();
  });
  await act(async () => store.reload());
  const removals = provider.calls.filter(({ op }) => op === KeybindingOps.remove).map(({ params }) => params);
  expect(removals).toContainEqual({ command: "tab.close", key: "cmd+shift+w", when: null, idempotency_key: "key" });
  expect(recorder()).toBeNull();

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

test("keys another action has: the recorder says who has them and offers Overwrite or a new shortcut", async () => {
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

  const doc = host.ownerDocument;
  const row = (title: string) =>
    [...host.querySelectorAll<HTMLElement>(".keys-row:not(.removed)")].find(
      (candidate) => candidate.querySelector(".keys-command-title")?.textContent === title,
    );
  const click = async (element: Element | null | undefined) => {
    expect(element).toBeTruthy();
    const MouseEvent = doc.defaultView!.MouseEvent;
    await act(async () => {
      element!.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      await Promise.resolve();
    });
  };
  const settle = async () => {
    for (let i = 0; i < 4; i++) await act(async () => Promise.resolve());
    await act(async () => store.reload());
  };
  const keys = async (...pressed: string[]) => {
    await act(async () => {
      for (const stroke of pressed) provider.press(stroke);
      provider.release();
      await Promise.resolve();
    });
    await settle();
  };
  const recorder = () => doc.querySelector<HTMLElement>(".keys-recorder");
  const choices = () => recorder()?.querySelector<HTMLElement>(".keys-recorder-choices");
  const sets = () => provider.calls.filter(({ op }) => op === KeybindingOps.set);

  // Show History's ⇧⌘P runs in the browser only, and there it takes the palette's ⇧⌘P: a conflict.
  expect(row("Open Command Palette")?.querySelector(".keys-conflict")).toBeTruthy();
  expect(row("Show History")?.querySelector(".keys-conflict")).toBeTruthy();

  // Keys that would take the palette's and History's: nothing is saved; the recorder says
  // "Already used by" them, its keys red under a red light, "Overwrite it or record a new shortcut".
  const title = () => recorder()?.querySelector(".keys-recorder-refusal")?.textContent;
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  await keys("cmd+shift+p");
  expect(sets()).toHaveLength(0);
  expect(choices()).toBeTruthy();
  // Not saved: the row keeps the keys it has.
  expect(row("Go to File")?.querySelector(".keys-key-button")?.textContent).toBe("⌘P");
  expect(title()).toContain("Open Command Palette");
  expect(title()).toContain("Show History");
  expect(recorder()?.querySelector(".keys-recorder-owner")).toBeTruthy();
  expect(recorder()?.querySelector(".keys-recorder-keys.refused")).toBeTruthy();
  expect(recorder()?.querySelector(".keys-recorder-light.danger")).toBeTruthy();
  expect(recorder()?.textContent).toContain(strings.t("keybindings.page.recorder.overwriteOrRecord"));

  // A modifier going down drops the question and shows live; the same keys again get the same
  // answer at the release, and no save light plays.
  await act(async () => {
    provider.hold("⇧⌘");
    await Promise.resolve();
  });
  expect(choices()).toBeFalsy();
  expect(recorder()?.querySelector(".keys-recorder-keys")?.textContent).toContain("⌘");
  await keys("cmd+shift+p");
  expect(choices()).toBeTruthy();
  expect(recorder()?.querySelector(".keys-recorder-light:not(.danger):not(.off)")).toBeNull();
  expect(sets()).toHaveLength(0);

  // A new shortcut instead drops the question and saves.
  await keys("cmd+shift+u");
  expect(choices()).toBeFalsy();
  expect(title()).toBeUndefined();
  expect(sets().at(-1)?.params).toMatchObject({ command: "palette.files", key: "cmd+shift+u" });

  // Escape closes: nothing saved.
  await keys("cmd+shift+p");
  expect(choices()).toBeTruthy();
  const asked = sets().length;
  await act(async () => {
    provider.cancel();
    await Promise.resolve();
  });
  await settle();
  expect(recorder()).toBeNull();
  expect(sets()).toHaveLength(asked);
  expect(row("Open Command Palette")?.querySelector(".keys-key-button")?.textContent).toBe("⇧⌘P");

  // Keys the app refuses (an action that always runs holds them): "Already used by" it, the
  // app's reason under it, no Overwrite; nothing is saved and the page's notice stays empty; the
  // next shortcut clears it.
  // Quit holds ⌘Q in the table too: the refusal wins over the question, so no Overwrite.
  provider.refused.set("cmd+q", "Quit");
  provider.layers.base.push({ command: "app.quit", key: "cmd+q", when: null, source: "default" });
  await act(async () => store.reload());
  const before = sets().length;
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  await keys("cmd+q");
  expect(title()).toBe(strings.format("keybindings.page.recorder.alreadyUsedBy", "Quit"));
  expect(recorder()?.textContent).toContain("which always runs");
  expect(choices()).toBeFalsy();
  expect(recorder()?.querySelector(".keys-recorder-keys.refused")).toBeTruthy();
  expect(doc.querySelector(".keys-notice")).toBeNull();
  expect(sets()).toHaveLength(before);
  expect(provider.recording).toBe(true);
  await keys("cmd+shift+y");
  expect(title()).toBeUndefined();
  expect(sets().at(-1)?.params).toMatchObject({ command: "palette.files", key: "cmd+shift+y" });
  await act(async () => {
    provider.cancel();
    await Promise.resolve();
  });

  // Return overwrites: Close Tab's ⌘W is taken from it first, then New Tab saves it.
  await click(row("New Tab")?.querySelector(".keys-key-button"));
  await keys("cmd+w");
  expect(choices()).toBeTruthy();
  expect(title()).toContain("Close Tab");
  const setsBefore = sets().length;
  // Return's own release comes while the remove is still running (a slow keybindings.json write):
  // no second save of the same keys, and no question again.
  let openGate = () => {};
  provider.removeGate = new Promise<void>((resolve) => (openGate = resolve));
  await act(async () => {
    provider.press("return");
    provider.release();
    await Promise.resolve();
  });
  await settle();
  provider.removeGate = undefined;
  await act(async () => {
    openGate();
    await Promise.resolve();
  });
  await settle();
  // One save of the keys refused in Close Tab's place, then Overwrite's own once they are free.
  expect(sets().length).toBe(setsBefore + 2);
  expect(choices()).toBeFalsy();
  const ops = provider.calls.map(({ op }) => op);
  const removedAt = ops.lastIndexOf(KeybindingOps.remove);
  expect(removedAt).toBeGreaterThan(-1);
  expect(provider.calls[removedAt]?.params).toEqual({
    command: "tab.close",
    key: "cmd+w",
    when: null,
    idempotency_key: "key",
  });
  expect(ops.lastIndexOf(KeybindingOps.set)).toBeGreaterThan(removedAt);
  expect(sets().at(-1)?.params).toMatchObject({ command: "tab.new", key: "cmd+w", replaces: { key: "cmd+t" } });
  expect(doc.querySelector(".keys-notice")).toBeNull();
  expect(row("Close Tab")?.querySelector(".keys-key-button")?.textContent).toBe(strings.t("keybindings.page.notSet"));
  expect(provider.recording).toBe(true);
  expect(choices()).toBeFalsy();

  // The fourth stroke ends the recording (the app's limit): the chord saves and the recorder closes.
  await act(async () => {
    provider.cancel();
    await Promise.resolve();
  });
  await click(row("Show History")?.querySelector(".keys-key-button"));
  await act(async () => {
    for (const stroke of ["cmd+k", "cmd+1", "cmd+2", "cmd+3"]) provider.press(stroke);
    await Promise.resolve();
  });
  await settle();
  expect(sets().at(-1)?.params).toMatchObject({ command: "history.open", key: "cmd+k cmd+1 cmd+2 cmd+3" });
  expect(recorder()).toBeNull();

  // Search by keys: the field empties and says it records, and how to stop; every key up ends
  // that shortcut, the search records on, and the next shortcut replaces it; Esc stops.
  const field = () => doc.querySelector<HTMLInputElement>(".keys-search");
  await act(async () => store.setText("tab"));
  await click(doc.querySelector(".keys-record"));
  expect(provider.recording).toBe(true);
  expect(field()?.value).toBe("");
  expect(field()?.placeholder).toBe(strings.t("keybindings.page.recordingPlaceholder"));
  expect(field()?.getAttribute("aria-label")).toBe(strings.t("keybindings.page.recordingKeys"));
  const badge = () => doc.querySelector<HTMLElement>(".keys-search-badge");
  expect(badge()?.textContent).toBe(strings.t("keybindings.page.recordingKeys"));
  expect(badge()?.title).toBe(strings.t("keybindings.page.recordingExit"));
  await keys("cmd+shift+p");
  expect(provider.recording).toBe(true);
  expect(doc.querySelector(".keys-record.on")).toBeTruthy();
  expect(field()?.value).toBe("cmd+shift+p");
  expect(row("Open Command Palette")).toBeTruthy();
  expect(row("Go to File")).toBeFalsy();
  await keys("cmd+shift+y");
  expect(provider.recording).toBe(true);
  expect(field()?.value).toBe("cmd+shift+y");
  expect(row("Go to File")).toBeTruthy();
  expect(row("Open Command Palette")).toBeFalsy();
  // The field takes no text while it records, but its clear button clears the recorded keys
  // (an input event with no text); the search records on.
  expect(field()?.readOnly).toBe(false);
  await act(async () => {
    const input = field()!;
    Object.getOwnPropertyDescriptor(doc.defaultView!.HTMLInputElement.prototype, "value")!.set!.call(input, "");
    input.dispatchEvent(new doc.defaultView!.Event("input", { bubbles: true }));
    await Promise.resolve();
  });
  expect(field()?.value).toBe("");
  expect(provider.recording).toBe(true);
  expect(row("Open Command Palette")).toBeTruthy();
  await keys("cmd+shift+y");
  expect(field()?.value).toBe("cmd+shift+y");
  // A bare Return stops it too, the keys staying the filter.
  await act(async () => {
    provider.press("return");
    await Promise.resolve();
  });
  await settle();
  expect(provider.recording).toBe(false);
  expect(doc.querySelector(".keys-record.on")).toBeNull();
  expect(field()?.value).toBe("cmd+shift+y");
  expect(field()?.placeholder).toBe(strings.t("keybindings.page.search"));
  expect(badge()).toBeNull();
  await act(async () => store.setText(""));
  await settle();

  // Refused keys were never saved: Close closes the recorder, and the row keeps its keys.
  const close = () => recorder()?.querySelector(".keys-recorder-actions .keys-recorder-button");
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  await keys("cmd+q");
  expect(title()).toContain("Quit");
  await click(close());
  await settle();
  expect(recorder()).toBeNull();
  expect(row("Go to File")?.querySelector(".keys-key-button")?.textContent).toBe("⇧⌘Y");

  // Overwrite of keys the app then refuses to save for this action (only keybindings.json could
  // hold them) takes nothing from the other actions: the recorder says why.
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  await keys("cmd+shift+p");
  expect(choices()).toBeTruthy();
  provider.unsupported = true;
  const removes = provider.calls.filter(({ op }) => op === KeybindingOps.remove).length;
  await act(async () => {
    provider.press("return");
    await Promise.resolve();
  });
  await settle();
  provider.unsupported = false;
  expect(provider.calls.filter(({ op }) => op === KeybindingOps.remove)).toHaveLength(removes);
  expect(row("Open Command Palette")?.querySelector(".keys-key-button")?.textContent).toBe("⇧⌘P");
  expect(title()).toContain("not supported");
  await act(async () => {
    provider.cancel();
    await Promise.resolve();
  });
  await settle();

  // Return right after the release, while the keys' check is still on the way: they save, then
  // the recorder closes.
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  await act(async () => {
    provider.press("cmd+shift+o");
    provider.release();
    provider.press("return");
    await Promise.resolve();
  });
  await settle();
  expect(sets().at(-1)?.params).toMatchObject({ command: "palette.files", key: "cmd+shift+o" });
  expect(recorder()).toBeNull();

  // Close right after the release, while those keys' check is still on the way: one save, then
  // the recorder closes.
  await click(row("Go to File")?.querySelector(".keys-key-button"));
  const savesBefore = sets().length;
  await act(async () => {
    provider.press("cmd+shift+e");
    provider.release();
    store.closeRecording();
    await Promise.resolve();
  });
  await settle();
  expect(sets()).toHaveLength(savesBefore + 1);
  expect(sets().at(-1)?.params).toMatchObject({ command: "palette.files", key: "cmd+shift+e" });
  expect(recorder()).toBeNull();

  // Keys of an action that runs in more places than the new ones (Find runs in a terminal, Next
  // Tab everywhere): the hint says Find takes them where it runs and Next Tab keeps them
  // everywhere else; Overwrite saves and removes nothing.
  await click(row("Find")?.querySelector(".keys-key-button"));
  await keys("ctrl+tab");
  expect(choices()).toBeTruthy();
  expect(title()).toContain("Next Tab");
  expect(recorder()?.textContent).toContain("Find takes it where it runs. Next Tab keeps it everywhere else.");
  const removesBefore = provider.calls.filter(({ op }) => op === KeybindingOps.remove).length;
  await act(async () => {
    provider.press("return");
    await Promise.resolve();
  });
  await settle();
  expect(provider.calls.filter(({ op }) => op === KeybindingOps.remove)).toHaveLength(removesBefore);
  expect(sets().at(-1)?.params).toMatchObject({ command: "find.open", key: "ctrl+tab" });
  expect(row("Next Tab")?.querySelector(".keys-key-button")?.textContent).toBe("⌃⇥");
});
