// Bring your history: one row per tool, in alphabetical order (Leo, 2026-11-05: "why is it split
// up? ... this doesn't even seem alphabetical ... why isn't it just import memories and chats?").
// A tool's row imports its chats and its memories together; its Sources disclosure goes one level
// deeper, where Chats and Memories are listed apart, each source with its path, to pick separately.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
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

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const view = (await import("../src/pages/import-history/ImportHistory")) as Record<string, unknown>;
const { ImportHistory } = await import("../src/pages/import-history/ImportHistory");
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

const tools = () => [...host.querySelectorAll<HTMLElement>(".history-tool")];
const tool = (name: string) => tools().find((row) => nameOf(row) === name)!;
const nameOf = (row: HTMLElement) => row.querySelector(".history-tool-title")?.textContent;
const summaryOf = (row: HTMLElement) => row.querySelector(".history-tool-summary")?.textContent;
const toolBox = (row: HTMLElement) => row.querySelector<HTMLInputElement>(".history-tool-line input[type=checkbox]")!;
const click = async (element: Element | null | undefined) => {
  await act(async () => (element as HTMLElement).click());
};
const selected = (store: InstanceType<typeof ImportHistoryStore>, id: string) =>
  store.getSnapshot().rows.find((row) => row.id === id)?.selected;

test("the first view is one row per tool, in alphabetical order, with no source rows", async () => {
  await mount();
  expect(tools().map(nameOf)).toEqual(["ChatGPT", "Claude", "Codex", "Grok", "Instinct", "Muse"]);
  expect(host.querySelectorAll(".history-source")).toHaveLength(0);
  expect(host.querySelector(".history-group")).toBeNull();
  expect(host.textContent).not.toContain("Found on this Mac");
});

test("a detected tool is checked and brings both its chats and its memories", async () => {
  const { store } = await mount();
  for (const name of ["Claude", "Codex"]) {
    expect(toolBox(tool(name)).checked).toBe(true);
    expect(summaryOf(tool(name))).toBe("Chats and memories");
  }
  for (const id of ["claude-code", "claude", "claude-memory", "codex", "codex-sessions"])
    expect(selected(store, id)).toBe(true);
  // A tool with nothing on this Mac is unchecked and can't be checked until it has a source.
  expect(toolBox(tool("Grok")).checked).toBe(false);
  expect(toolBox(tool("Grok")).disabled).toBe(true);
  expect(summaryOf(tool("Grok"))).toBe("None found yet");
});

test("every source belongs to exactly one tool, and none is dropped", () => {
  const toolOf = view.toolOf as (row: { id: string; title?: string }) => string;
  expect(typeof toolOf).toBe("function");
  const byTool: Record<string, string[]> = {};
  for (const row of initialRows()) (byTool[toolOf(row)] ??= []).push(row.id);
  expect(byTool).toEqual({
    claude: ["claude-code", "claude-memory", "claude"],
    codex: ["codex", "codex-sessions"],
    chatgpt: ["chatgpt", "dots"],
    grok: ["grok-bot"],
    muse: ["muse"],
    instinct: ["instinct"],
  });
});

test("Sources opens the tool's Chats and Memories apart, each source with its path", async () => {
  await mount();
  const claude = tool("Claude");
  await click(claude.querySelector(".history-disclosure"));
  expect(claude.querySelector(".history-disclosure")?.getAttribute("aria-expanded")).toBe("true");
  const kinds = [...claude.querySelectorAll<HTMLElement>(".history-kind")];
  expect(kinds.map((kind) => kind.querySelector(".history-kind-title")?.textContent)).toEqual(["Chats", "Memories"]);
  const titles = (kind: HTMLElement) =>
    [...kind.querySelectorAll(".history-source-text label")].map((label) => label.textContent);
  expect(titles(kinds[0]!)).toEqual(["Claude Code", "Claude export (.zip)"]);
  expect(titles(kinds[1]!)).toEqual(["Claude memory"]);
  // The mock reports a path only for the archives; real detection gives every source one.
  expect(kinds[0]!.querySelector(".history-file")?.textContent).toBe("/Users/example/Desktop/claude-export.zip");
  // Only this tool opened.
  expect(tool("Codex").querySelectorAll(".history-source")).toHaveLength(0);
});

test("unchecking a tool's memories keeps its chats, and the tool reads as partly checked", async () => {
  const { store } = await mount();
  const claude = tool("Claude");
  await click(claude.querySelector(".history-disclosure"));
  await click(claude.querySelector("#history-select-claude-memory"));
  expect(selected(store, "claude-memory")).toBe(false);
  expect(selected(store, "claude-code")).toBe(true);
  expect(toolBox(claude).checked).toBe(false);
  expect(toolBox(claude).indeterminate).toBe(true);
  expect(summaryOf(claude)).toBe("Chats");
  // Checking the tool again brings everything it has back.
  await click(toolBox(claude));
  expect(selected(store, "claude-memory")).toBe(true);
  expect(toolBox(claude).indeterminate).toBe(false);
});

test("a tool's checkbox turns its sources off and on without touching another tool", async () => {
  const { store } = await mount();
  await click(toolBox(tool("Codex")));
  expect(selected(store, "codex")).toBe(false);
  expect(selected(store, "codex-sessions")).toBe(false);
  expect(summaryOf(tool("Codex"))).toBe("Not included");
  expect(selected(store, "claude-code")).toBe(true);
  await click(toolBox(tool("Codex")));
  expect(selected(store, "codex")).toBe(true);
  expect(selected(store, "codex-sessions")).toBe(true);
});

test("Find exports stays on the page, and the footer has the keycap as its own element", async () => {
  await mount();
  expect(host.querySelector(".history-scroll .history-find")).not.toBeNull();
  const form = host.querySelector("form.import-history")!;
  expect([...form.children].map((child) => child.className)).toEqual(["history-scroll", "history-footer"]);
  const importButton = host.querySelector<HTMLButtonElement>(".history-footer button[type=submit]")!;
  expect(importButton.querySelector(".ui-keyhint")?.textContent).toBe("↩");
});
