import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../omnibar";
import {
  MAX_AGENT_ROWS,
  nextMode,
  orderedAgents,
  recentChatCards,
  screenRows,
  terminalConversion,
  type ScreenRow,
} from "./screenModel";

const agents = [
  { id: "claude", name: "Claude Code" },
  { id: "codex", name: "Codex" },
  { id: "opencode", name: "OpenCode" },
];
const omnibar: OmnibarContext = {
  ...EMPTY_OMNIBAR,
  tabs: [{ id: "t1", kind: "browser", title: "Vite guide", detail: "vite.dev/guide" }],
  history: [{ url: "https://github.com/manaflow-ai/cmux", title: "cmux" }],
};
const types = (rows: ScreenRow[]) => rows.map((row) => (row.type === "agent" ? `agent:${row.harness}` : row.type));

test("an empty field shows no dropdown: the chat cards are the page", () => {
  expect(screenRows("", "ask", { agents, omnibar })).toEqual([]);
  expect(screenRows("   ", "search", { agents, omnibar })).toEqual([]);
});

test("Ask mode lists every installed agent first, then the web search", () => {
  const rows = screenRows("fix the build", "ask", { agents, omnibar });
  expect(types(rows)).toEqual(["agent:claude", "agent:codex", "agent:opencode", "search"]);
  expect(rows[0]).toEqual({ type: "agent", harness: "claude", name: "Claude Code", text: "fix the build" });
  expect(rows[3]).toEqual({ type: "search", text: "fix the build" });
});

test("Search mode puts the web search first and the agents after it", () => {
  expect(types(screenRows("fix the build", "search", { agents, omnibar }))).toEqual([
    "search",
    "agent:claude",
    "agent:codex",
    "agent:opencode",
  ]);
});

test("the remembered agent leads the agent rows", () => {
  const rows = screenRows("fix it", "ask", { agents, omnibar, lastAgent: "codex" });
  expect(types(rows).slice(0, 3)).toEqual(["agent:codex", "agent:claude", "agent:opencode"]);
});

test("an address opens first in either mode, with search and the agents after it", () => {
  for (const mode of ["ask", "search"] as const) {
    const rows = screenRows("localhost:3000", mode, { agents, omnibar });
    expect(rows[0]).toEqual({ type: "open", url: "http://localhost:3000", text: "localhost:3000" });
    expect(types(rows)).toContain("search");
  }
});

test("matching open tabs and history follow the typed rows", () => {
  const rows = screenRows("vite", "ask", { agents, omnibar });
  expect(types(rows)).toEqual(["agent:claude", "agent:codex", "agent:opencode", "search", "tab"]);
  expect(types(screenRows("github", "search", { agents, omnibar }))).toEqual([
    "search",
    "agent:claude",
    "agent:codex",
    "agent:opencode",
    "history",
  ]);
});

test("a typed ! command never shows rows: the tab already became a terminal", () => {
  expect(screenRows("!ls", "ask", { agents, omnibar })).toEqual([]);
});

test("without installed agents Ask still offers the search", () => {
  expect(types(screenRows("hello", "ask", { agents: [], omnibar }))).toEqual(["search"]);
});

test("agent rows are capped and keep the catalog order", () => {
  const many = Array.from({ length: 9 }, (_, i) => ({ id: `a${i}`, name: `A${i}` }));
  expect(orderedAgents(many).length).toBe(MAX_AGENT_ROWS);
  expect(orderedAgents(many, "a7")[0]!.id).toBe("a7");
  expect(orderedAgents(many, "missing")[0]!.id).toBe("a0");
});

test("Tab and Shift-Tab switch Search and Ask", () => {
  expect(nextMode("search")).toBe("ask");
  expect(nextMode("ask")).toBe("search");
});

test("! typed into an empty or wholly selected field converts at once, keeping the rest", () => {
  expect(terminalConversion("", "!", false)).toEqual({ command: "" });
  expect(terminalConversion("", "!git status", false)).toEqual({ command: "git status" });
  expect(terminalConversion("github.com", "!", true)).toEqual({ command: "" });
  expect(terminalConversion("why", "why!", false)).toBeUndefined();
  expect(terminalConversion("", "a", false)).toBeUndefined();
  expect(terminalConversion("x", "!x", false)).toBeUndefined();
});

test("chat cards: the three newest, waiting chats first, a dropped chat as an error card", () => {
  const now = 1_000_000_000;
  const sessions = [
    { sessionId: "a", title: "Old", updatedAt: now - 3 * 3600_000, preview: "done" },
    { sessionId: "b", title: "Newest", updatedAt: now - 60_000, preview: "ok" },
    { sessionId: "c", title: "Dropped", updatedAt: now - 7200_000, status: "disconnected" },
    { sessionId: "d", title: "Waiting", updatedAt: now - 9 * 3600_000, pendingPermissions: 1 },
  ];
  const cards = recentChatCards(sessions, now);
  expect(cards.map((card) => card.sessionId)).toEqual(["d", "b", "c"]);
  expect(cards[1]).toMatchObject({ title: "Newest", age: "1m", message: "ok", state: "idle" });
  expect(cards[2]).toMatchObject({ title: "Dropped", state: "error" });
  expect(cards[0]).toMatchObject({ state: "input" });
});

test("two installed harnesses with one name are told apart by their id", () => {
  const twins = [
    { id: "claude", name: "Claude Code" },
    { id: "claude-sr", name: "Claude Code" },
    { id: "codex", name: "Codex" },
  ];
  const names = screenRows("fix it", "ask", { agents: twins, omnibar }).flatMap((row) =>
    row.type === "agent" ? [row.name] : [],
  );
  expect(names).toEqual(["Claude Code (claude)", "Claude Code (claude-sr)", "Codex"]);
});
