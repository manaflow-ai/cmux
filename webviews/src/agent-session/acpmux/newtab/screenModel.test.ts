import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../omnibar";
import { MAX_AGENT_ROWS, orderedAgents, recentChatCards, screenRows, shellEntry, type ScreenRow } from "./screenModel";

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
  expect(screenRows("", { agents, omnibar })).toEqual([]);
  expect(screenRows("   ", { agents, omnibar })).toEqual([]);
});

test("plain text lists every installed agent first, then the web search as an explicit row", () => {
  const rows = screenRows("fix the build", { agents, omnibar });
  expect(types(rows)).toEqual(["agent:claude", "agent:codex", "agent:opencode", "search"]);
  expect(rows[0]).toEqual({ type: "agent", harness: "claude", name: "Claude Code", text: "fix the build" });
  expect(rows[3]).toEqual({ type: "search", text: "fix the build" });
});

test("the remembered agent leads the agent rows", () => {
  const rows = screenRows("fix it", { agents, omnibar, lastAgent: "codex" });
  expect(types(rows).slice(0, 3)).toEqual(["agent:codex", "agent:claude", "agent:opencode"]);
});

test("an address opens first, with search and the agents after it", () => {
  const rows = screenRows("localhost:3000", { agents, omnibar });
  expect(rows[0]).toEqual({ type: "open", url: "http://localhost:3000", text: "localhost:3000" });
  expect(types(rows)).toContain("search");
});

test("matching open tabs and history follow the typed rows", () => {
  const rows = screenRows("vite", { agents, omnibar });
  expect(types(rows)).toEqual(["agent:claude", "agent:codex", "agent:opencode", "search", "tab"]);
  expect(types(screenRows("github", { agents, omnibar }))).toEqual([
    "agent:claude",
    "agent:codex",
    "agent:opencode",
    "search",
    "history",
  ]);
});

test("a typed ! command never shows rows: the tab already became a terminal", () => {
  expect(screenRows("!ls", { agents, omnibar })).toEqual([]);
});

test("without installed agents Ask still offers the search", () => {
  expect(types(screenRows("hello", { agents: [], omnibar }))).toEqual(["search"]);
});

test("agent rows are capped and keep the catalog order", () => {
  const many = Array.from({ length: 9 }, (_, i) => ({ id: `a${i}`, name: `A${i}` }));
  expect(orderedAgents(many).length).toBe(MAX_AGENT_ROWS);
  expect(orderedAgents(many, "a7")[0]!.id).toBe("a7");
  expect(orderedAgents(many, "missing")[0]!.id).toBe("a0");
});

test("! typed into an empty or wholly selected field enters shell mode, keeping the rest", () => {
  expect(shellEntry("", "!", false)).toEqual({ command: "" });
  expect(shellEntry("", "!git status", false)).toEqual({ command: "git status" });
  expect(shellEntry("github.com", "!", true)).toEqual({ command: "" });
  expect(shellEntry("why", "why!", false)).toBeUndefined();
  expect(shellEntry("", "a", false)).toBeUndefined();
  expect(shellEntry("x", "!x", false)).toBeUndefined();
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
  const names = screenRows("fix it", { agents: twins, omnibar }).flatMap((row) =>
    row.type === "agent" ? [row.name] : [],
  );
  expect(names).toEqual(["Claude Code (claude)", "Claude Code (claude-sr)", "Codex"]);
});
