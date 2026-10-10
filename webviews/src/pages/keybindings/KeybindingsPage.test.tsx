import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { KeybindingsPage } from "./KeybindingsPage";
import { MockKeybindingsProvider, sampleLayers } from "./mockProvider";
import { KeybindingsStore } from "./store";
import { KeybindingOps } from "./types";

const saved: Record<string, unknown> = {};
let dom: JSDOM;
let root: Root;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://localhost/keybindings/",
  });
  for (const name of ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved[name] = (globalThis as any)[name];
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  // react-dom picks its input-event path when the module first loads; stub the legacy IE path.
  Object.assign(dom.window.HTMLElement.prototype, { attachEvent: () => undefined, detachEvent: () => undefined });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(() => {
  act(() => root.unmount());
  for (const [name, value] of Object.entries(saved)) (globalThis as any)[name] = value;
});

async function render(
  provider: MockKeybindingsProvider | null = new MockKeybindingsProvider(sampleLayers()),
  language = "en",
) {
  const store = new KeybindingsStore(provider, { newKey: () => "k" });
  await act(async () => {
    root.render(<KeybindingsPage store={store} strings={createStrings(table, [language])} />);
  });
  await act(async () => {
    await store.start();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  return store;
}

const $ = (selector: string) => dom.window.document.querySelector(selector) as HTMLElement | null;
const $$ = (selector: string) => [...dom.window.document.querySelectorAll(selector)] as HTMLElement[];
const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));

function key(target: HTMLElement, keyName: string, init: KeyboardEventInit = {}) {
  target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: keyName, bubbles: true, ...init }));
}

function rowOf(title: string, keyText?: string): HTMLElement {
  const row = $$(".keys-row").find(
    (r) =>
      r.querySelector(".keys-command-title")?.textContent === title &&
      (!keyText || r.querySelector(".keys-caps")?.textContent === keyText),
  );
  if (!row) throw new Error(`no row ${title}`);
  return row;
}

describe("KeybindingsPage", () => {
  test("renders the table: headers, rows, keycaps, sources, conflict markers; search has focus", async () => {
    await render();
    expect($(".keys-title")?.textContent).toBe("Keyboard Shortcuts");
    expect($$(".keys-table th").map((th) => th.textContent)).toEqual([
      "Command",
      "Keybinding",
      "When",
      "Source",
      "Actions",
    ]);
    expect($$(".keys-row")).toHaveLength(16);
    const settings = rowOf("Open Keyboard Shortcuts");
    expect(settings.querySelector(".keys-command-id")?.textContent).toBe("keybindings.open");
    expect([...settings.querySelectorAll(".keys-cap")].map((cap) => cap.textContent)).toEqual(["⌘K", "⌘S"]);
    expect(rowOf("Show History", "⌘Y").querySelector(".keys-col-source")?.textContent).toBe("App");
    expect(rowOf("Show History", "⇧⌘P").querySelector(".keys-col-source")?.textContent).toBe("User");
    expect(rowOf("Split Down", "⇧⌘D").querySelector(".keys-col-source")?.textContent).toBe("Removed");
    expect($$(".keys-conflict").map((b) => b.getAttribute("aria-label"))).toEqual(["Conflicts: 1", "Conflicts: 1"]);
    // Reset only for commands with a user entry or a removed default.
    expect(rowOf("New Tab").querySelector(".keys-reset")).toBeNull();
    expect(rowOf("Split Down", "⇧⌘D").querySelector(".keys-reset")).not.toBeNull();
    expect(rowOf("Split Down", "⇧⌘D").querySelector(".keys-remove")).toBeNull();
    expect(dom.window.document.activeElement).toBe($(".keys-search"));
  });

  test("Japanese strings", async () => {
    await render(undefined, "ja");
    expect($(".keys-title")?.textContent).toBe("キーボードショートカット");
  });

  test("the conflict marker filters to entries on the same keys", async () => {
    await render();
    await act(async () => $$(".keys-conflict")[0].click());
    expect(($(".keys-search") as HTMLInputElement).value).toBe("cmd+shift+p");
    expect($$(".keys-row").map((r) => r.querySelector(".keys-command-title")?.textContent)).toEqual([
      "Open Command Palette",
      "Show History",
    ]);
    await act(async () => key($(".keys-search")!, "Escape"));
    expect($$(".keys-row")).toHaveLength(16);
  });

  test("show conflicts only", async () => {
    await render();
    const toggle = $(".keys-conflicts-only")!;
    await act(async () => toggle.click());
    expect(toggle.getAttribute("aria-pressed")).toBe("true");
    expect($$(".keys-row")).toHaveLength(2);
  });

  test("inline when edit: Return commits with replaces, Escape cancels", async () => {
    const provider = new MockKeybindingsProvider(sampleLayers());
    await render(provider);
    await act(async () => rowOf("New Tab").querySelector<HTMLElement>(".keys-when")!.click());
    let input = $(".keys-when-input") as HTMLInputElement;
    expect(dom.window.document.activeElement).toBe(input);
    await act(async () => key(input, "Escape"));
    expect($(".keys-when-input")).toBeNull();
    await act(async () => rowOf("New Tab").querySelector<HTMLElement>(".keys-when")!.click());
    input = $(".keys-when-input") as HTMLInputElement;
    input.value = "focus.terminal";
    await act(async () => key(input, "Enter"));
    await settle();
    expect(provider.calls.find((c) => c.op === KeybindingOps.set)?.params).toEqual({
      command: "tab.new",
      key: "cmd+t",
      when: "focus.terminal",
      replaces: { key: "cmd+t", when: null },
      idempotency_key: "k",
    });
    expect($(".keys-when-input")).toBeNull();
    const made = $$(".keys-row").find((r) => r.querySelector(".keys-when")?.textContent === "focus.terminal");
    expect(made?.querySelector(".keys-col-source")?.textContent).toBe("User");
  });

  test("record keys: the toggle starts recording and strokes fill the search", async () => {
    const provider = new MockKeybindingsProvider(sampleLayers());
    await render(provider);
    const record = $(".keys-record")!;
    await act(async () => record.click());
    expect(record.getAttribute("aria-pressed")).toBe("true");
    expect(provider.recording).toBe(true);
    await act(async () => provider.press("cmd+k"));
    expect(($(".keys-search") as HTMLInputElement).value).toBe("cmd+k");
    expect($$(".keys-row")).toHaveLength(2);
    await act(async () => provider.finish());
    expect(record.getAttribute("aria-pressed")).toBe("false");
  });

  test("change keybinding: the row records and the recorded keys replace the old ones", async () => {
    const provider = new MockKeybindingsProvider(sampleLayers());
    await render(provider);
    await act(async () => rowOf("New Tab").querySelector<HTMLElement>(".keys-change")!.click());
    expect(rowOf("New Tab").classList.contains("recording")).toBe(true);
    expect(rowOf("New Tab").querySelector(".keys-placeholder")?.textContent).toBe("Press keys…");
    await act(async () => provider.press("cmd+shift+t"));
    expect(rowOf("New Tab").querySelector(".keys-caps")?.textContent).toBe("⇧⌘T");
    await act(async () => provider.finish());
    await settle();
    expect(provider.calls.find((c) => c.op === KeybindingOps.set)?.params).toMatchObject({
      command: "tab.new",
      key: "cmd+shift+t",
      replaces: { key: "cmd+t", when: null },
    });
    expect(rowOf("New Tab", "⇧⌘T").classList.contains("selected")).toBe(true);
  });

  test("arrow keys move the selection and Return starts change keybinding", async () => {
    const provider = new MockKeybindingsProvider(sampleLayers());
    await render(provider);
    const grid = $(".keys-table")!;
    await act(async () => key(grid, "ArrowDown"));
    await act(async () => key(grid, "ArrowDown"));
    const selected = $$(".keys-row.selected");
    expect(selected).toHaveLength(1);
    expect(selected[0]).toBe($$(".keys-row")[1]);
    await act(async () => key(grid, "ArrowUp"));
    expect($$(".keys-row")[0].classList.contains("selected")).toBe(true);
    await act(async () => key(grid, "Enter"));
    expect(provider.recording).toBe(true);
    expect($$(".keys-row")[0].classList.contains("recording")).toBe(true);
  });

  test("an unsupported write shows the calm notice and keeps the row", async () => {
    const provider = new MockKeybindingsProvider(sampleLayers());
    provider.unsupported = true;
    await render(provider);
    await act(async () => rowOf("New Tab").querySelector<HTMLElement>(".keys-remove")!.click());
    await settle();
    expect($(".keys-notice")?.textContent).toContain("keybindings.json");
    expect(rowOf("New Tab")).not.toBeNull();
  });

  test("disconnected", async () => {
    await render(null);
    expect($(".keys-empty")?.textContent).toBe("Not connected to cmux.");
  });
});
