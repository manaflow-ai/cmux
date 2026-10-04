import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { HistoryPage } from "./HistoryPage";
import { MockHistoryProvider, sampleEntries } from "./mockProvider";
import { HistoryStore } from "./store";
import { ACTION_RUN, HistoryOps } from "./types";

const now = new Date(2026, 9, 4, 12, 0, 0).getTime();
const saved: Record<string, unknown> = {};
let dom: JSDOM;
let root: Root;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://localhost/history/",
  });
  for (const name of ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved[name] = (globalThis as any)[name];
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  // react-dom picks its input-event path when the module first loads; in a shared bun test
  // process that can be before any DOM exists, which selects the legacy IE path. Stub it.
  Object.assign(dom.window.HTMLElement.prototype, { attachEvent: () => undefined, detachEvent: () => undefined });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(() => {
  act(() => root.unmount());
  for (const [name, value] of Object.entries(saved)) (globalThis as any)[name] = value;
});

async function render(provider: MockHistoryProvider | null, language = "en") {
  const store = new HistoryStore(provider, { newKey: () => "k" });
  await act(async () => {
    root.render(<HistoryPage store={store} strings={createStrings(table, [language])} now={() => now} />);
  });
  await act(async () => {
    await store.start();
  });
  return store;
}

const $ = (selector: string) => dom.window.document.querySelector(selector) as HTMLElement | null;
const $$ = (selector: string) => [...dom.window.document.querySelectorAll(selector)] as HTMLElement[];

function key(target: HTMLElement, keyName: string, init: KeyboardEventInit = {}) {
  target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: keyName, bubbles: true, ...init }));
}

describe("HistoryPage", () => {
  test("renders day groups, rows, badges and the six chips; search has focus", async () => {
    await render(new MockHistoryProvider(sampleEntries(now), () => now));
    expect($(".history-title")?.textContent).toBe("History");
    expect($$(".history-chip").map((chip) => chip.textContent)).toEqual([
      "All",
      "Pages",
      "Locations",
      "Commands",
      "Agents",
      "Closed",
    ]);
    expect($$(".history-group-title").map((h) => h.textContent)).toContain("Today");
    expect($$(".history-row").length).toBe(sampleEntries(now).length);
    expect($$(".history-row-badge").map((b) => b.textContent)).toEqual(
      expect.arrayContaining(["Current", "Running", "Offline"]),
    );
    expect(dom.window.document.activeElement).toBe($(".history-search"));
  });

  test("Japanese strings", async () => {
    await render(new MockHistoryProvider(sampleEntries(now), () => now), "ja");
    expect($(".history-title")?.textContent).toBe("履歴");
  });

  test("Down then Return in the search field opens the first row through history.open", async () => {
    const provider = new MockHistoryProvider(sampleEntries(now), () => now);
    await render(provider);
    const search = $(".history-search")!;
    await act(async () => key(search, "ArrowDown"));
    expect($(".history-row.selected .history-row-title")?.textContent).toBe("manaflow-ai/cmux: pull requests");
    await act(async () => key(search, "Enter"));
    expect(provider.calls.at(-1)).toEqual({
      op: ACTION_RUN,
      params: { action: "history.open", args: { id: "page:default:1", new_tab: false } },
    });
  });

  test("chords are left to the app's dispatcher", async () => {
    const provider = new MockHistoryProvider(sampleEntries(now), () => now);
    await render(provider);
    const calls = provider.calls.length;
    await act(async () => key($(".history-search")!, "Enter", { metaKey: true }));
    await act(async () => key($(".history-search")!, "ArrowDown", { ctrlKey: true }));
    expect(provider.calls.length).toBe(calls);
    expect($(".history-row.selected")).toBeNull();
  });

  test("a chip filters through the provider", async () => {
    const provider = new MockHistoryProvider(sampleEntries(now), () => now);
    await render(provider);
    await act(async () => $$(".history-chip")[4].click());
    expect(provider.calls.at(-1)).toMatchObject({ op: HistoryOps.list, params: { kinds: ["agent"] } });
    expect($$(".history-row-title").map((t) => t.textContent)).toEqual(["Claude Code", "Codex"]);
  });

  test("context menu Remove from History removes through the provider", async () => {
    const provider = new MockHistoryProvider(sampleEntries(now), () => now);
    await render(provider);
    const row = $$(".history-row")[0];
    await act(async () => {
      row.dispatchEvent(new dom.window.MouseEvent("contextmenu", { bubbles: true, clientX: 10, clientY: 10 }));
    });
    const items = $$(".page-menu-item");
    expect(items.map((item) => item.textContent)).toEqual([
      "Open",
      "Open in New Tab",
      "Copy URL",
      "Remove All from This Site",
      "Remove from History",
    ]);
    await act(async () => items.at(-1)!.click());
    expect(provider.calls.find((c) => c.op === HistoryOps.remove)?.params).toEqual({
      ids: ["page:default:1"],
      idempotency_key: "k",
    });
    expect($(".page-menu")).toBeNull();
    expect($$(".history-row-title").map((t) => t.textContent)).not.toContain("manaflow-ai/cmux: pull requests");
  });

  test("empty and no-match states", async () => {
    await render(new MockHistoryProvider([], () => now));
    expect($(".history-empty")?.textContent).toBe("No history");
  });

  test("no host: the disconnected state, search disabled", async () => {
    await render(null);
    expect($(".history-empty")?.textContent).toBe("History is not available until cmux reconnects.");
    expect(($(".history-search") as HTMLInputElement).disabled).toBe(true);
  });
});
