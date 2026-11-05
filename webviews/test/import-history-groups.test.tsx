// Bring your history: the first view is two toggles, Chats and Memories, with every source one
// level deeper behind its group's Sources disclosure, in alphabetical order. The whole list sits in
// one scroll region above the footer, and the Import button's keycap is its own element.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/import-history/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(() => {
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { ImportHistory, groupOf } = await import("../src/pages/import-history/ImportHistory");
const { ImportHistoryStore, initialRows } = await import("../src/pages/import-history/model");
const { MockImportHistoryProvider } = await import("../src/pages/import-history/mockProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/import-history/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;

async function mount() {
  const store = new ImportHistoryStore(new MockImportHistoryProvider());
  const strings = createStrings(table, ["en"]);
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => root!.render(<ImportHistory store={store} strings={strings} />));
  await act(async () => store.start());
  return { store };
}

const groups = () => [...host.querySelectorAll<HTMLElement>(".history-group")];
const titleOf = (group: HTMLElement) => group.querySelector(".history-group-title")?.textContent;
const sourceTitles = (group: HTMLElement) =>
  [...group.querySelectorAll(".history-source-text label")].map((label) => label.textContent);
const click = async (element: Element | null | undefined) => {
  await act(async () => (element as HTMLElement).click());
};

test("the first view is two groups, Chats then Memories, with no source rows showing", async () => {
  await mount();
  expect(groups().map(titleOf)).toEqual(["Chats", "Memories"]);
  expect(host.querySelectorAll(".history-source")).toHaveLength(0);
  expect(host.textContent).not.toContain("Found on this Mac");
  // Every detected source is on: each group's switch is checked and its summary names them.
  for (const group of groups())
    expect(group.querySelector('[role="switch"]')?.getAttribute("aria-checked")).toBe("true");
  expect(groups()[0]!.querySelector(".history-group-summary")?.textContent).toBe(
    "ChatGPT export (.zip), Claude Code, Claude export (.zip), Codex chats",
  );
});

test("every source is in exactly one group, and none is dropped", () => {
  const ids = initialRows().map((row) => row.id);
  const chats = initialRows()
    .filter((row) => groupOf(row) === "chats")
    .map((row) => row.id);
  const memories = initialRows()
    .filter((row) => groupOf(row) === "memories")
    .map((row) => row.id);
  expect([...chats, ...memories].sort()).toEqual([...ids].sort());
  expect(chats).toEqual(["claude-code", "codex-sessions", "chatgpt", "claude"]);
  expect(memories).toEqual(["codex", "claude-memory", "grok-bot", "muse", "dots", "instinct"]);
});

test("Sources opens the group's sources in alphabetical order, each with its path", async () => {
  await mount();
  const [chats, memories] = groups();
  await click(chats!.querySelector(".history-disclosure"));
  expect(sourceTitles(chats!)).toEqual(["ChatGPT export (.zip)", "Claude Code", "Claude export (.zip)", "Codex chats"]);
  expect(chats!.querySelector(".history-disclosure")?.getAttribute("aria-expanded")).toBe("true");
  await click(memories!.querySelector(".history-disclosure"));
  expect(sourceTitles(memories!)).toEqual(["ChatGPT Dots", "Claude memory", "Codex", "Grok Bot", "Instinct", "Muse"]);
});

test("the group switch turns every available source in it off and on", async () => {
  const { store } = await mount();
  const chats = groups()[0]!;
  await click(chats.querySelector('[role="switch"]'));
  const chatRows = store.getSnapshot().rows.filter((row) => groupOf(row) === "chats");
  expect(chatRows.every((row) => !row.selected)).toBe(true);
  expect(chats.querySelector(".history-group-summary")?.textContent).toBe("Not included");
  // Memories is untouched.
  expect(store.getSnapshot().rows.find((row) => row.id === "claude-memory")?.selected).toBe(true);
  await click(chats.querySelector('[role="switch"]'));
  expect(
    store
      .getSnapshot()
      .rows.filter((row) => groupOf(row) === "chats")
      .every((row) => row.selected),
  ).toBe(true);
});

test("the list is in one scroll region above the footer, and the keycap is its own element", async () => {
  await mount();
  const form = host.querySelector("form.import-history")!;
  expect([...form.children].map((child) => child.className)).toEqual(["history-scroll", "history-footer"]);
  expect(host.querySelector(".history-scroll header h1")?.textContent).toBe("Bring your history");
  expect(host.querySelector(".history-scroll .history-safety")).not.toBeNull();
  const importButton = host.querySelector<HTMLButtonElement>(".history-footer button[type=submit]")!;
  expect(importButton.querySelector(".ui-keyhint")?.textContent).toBe("↩");
});

test("a partly selected group shows its switch off, and turning it on selects every source", async () => {
  const { store } = await mount();
  store.select("claude-code", false);
  await act(async () => {});
  const chats = groups()[0]!;
  const toggle = () => chats.querySelector('[role="switch"]');
  expect(toggle()?.getAttribute("aria-checked")).toBe("false");
  expect(chats.querySelector(".history-group-summary")?.textContent).toBe(
    "ChatGPT export (.zip), Claude export (.zip), Codex chats",
  );
  await click(toggle());
  expect(
    store
      .getSnapshot()
      .rows.filter((row) => groupOf(row) === "chats")
      .every((row) => row.selected),
  ).toBe(true);
  expect(toggle()?.getAttribute("aria-checked")).toBe("true");
});
