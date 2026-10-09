import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../omnibar";
import {
  defaultHarness,
  initialSelection,
  orderedAgents,
  recentChatCards,
  screenRows,
  shellEntry,
  stepSelection,
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
const types = (rows: ScreenRow[]) => rows.map((row) => row.type);

test("an empty field shows no dropdown: the chat cards are the page", () => {
  expect(screenRows("", { omnibar })).toEqual([]);
  expect(screenRows("   ", { omnibar })).toEqual([]);
});

// cx-e2aa (Lawrence 2026-10-09): the rows under the field are only for addresses and other tabs,
// and show only when they make sense (an address, or a match to open). A prompt shows nothing:
// Enter sends it to the agent picked at the top of the page.
test("a prompt shows no rows: the agent is picked at the top, not in a list", () => {
  expect(screenRows("fix the build", { omnibar })).toEqual([]);
  expect(screenRows("hello", { omnibar: EMPTY_OMNIBAR })).toEqual([]);
});

test("an address opens first, its matches follow, the web search is last", () => {
  const rows = screenRows("localhost:3000", { omnibar });
  expect(rows[0]).toEqual({ type: "open", url: "http://localhost:3000", text: "localhost:3000" });
  expect(types(rows)).toEqual(["open", "search"]);
  expect(types(screenRows("github.com/manaflow-ai", { omnibar }))).toEqual(["open", "history", "search"]);
});

test("text that matches an open tab or a visited page lists them, then the web search", () => {
  expect(types(screenRows("vite", { omnibar }))).toEqual(["tab", "search"]);
  expect(types(screenRows("github", { omnibar }))).toEqual(["history", "search"]);
});

test("workspaces, chats, folders and commands are never rows: only addresses and tabs", () => {
  const context: OmnibarContext = {
    ...EMPTY_OMNIBAR,
    workspaces: [{ id: "w1", name: "Docs", detail: "~/src/docs" }],
    sessions: [{ sessionId: "s1", title: "Docs chat" }],
    folders: ["/src/docs"],
    commands: ["docs build"],
  };
  expect(screenRows("docs", { omnibar: context })).toEqual([]);
});

test("Enter takes an address's open row at once; a prompt's rows wait for Down or Ctrl-N", () => {
  expect(initialSelection("localhost:3000")).toBe(0);
  expect(initialSelection("vite")).toBe(-1);
  expect(initialSelection("")).toBe(-1);
});

test("a local file opens without a web search row", () => {
  expect(types(screenRows("/tmp/report.txt", { omnibar }))).toEqual(["open"]);
});

test("a typed ! command never shows rows: the tab already became a terminal", () => {
  expect(screenRows("!ls", { omnibar })).toEqual([]);
});

test("Down and Ctrl-N step from no selection to the first row; Up and Ctrl-P to the last", () => {
  expect(stepSelection(-1, 1, 3)).toBe(0);
  expect(stepSelection(-1, -1, 3)).toBe(2);
  expect(stepSelection(2, 1, 3)).toBe(0);
  expect(stepSelection(0, -1, 3)).toBe(2);
  expect(stepSelection(-1, 1, 0)).toBe(-1);
});

test("the agent Enter asks is the remembered one, else the first installed", () => {
  expect(defaultHarness(agents, "codex")).toBe("codex");
  expect(defaultHarness(agents)).toBe("claude");
  expect(defaultHarness([], undefined)).toBeUndefined();
});

test("every installed harness stays available in the Ask list", () => {
  const many = Array.from({ length: 9 }, (_, i) => ({ id: `a${i}`, name: `A${i}` }));
  expect(orderedAgents(many).length).toBe(9);
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
