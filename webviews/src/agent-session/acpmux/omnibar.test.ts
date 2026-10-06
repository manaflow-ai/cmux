import { expect, test } from "bun:test";
import {
  defaultRow,
  matchScore,
  MAX_NEW_TAB_ENTRIES,
  MAX_ROWS,
  omnibarContext,
  omnibarRows,
  type OmnibarContext,
} from "./omnibar";

const context: OmnibarContext = {
  tabs: [
    { id: "t1", kind: "terminal", title: "web-app", detail: "~/code/web-app", workspace: "web-app" },
    { id: "t2", kind: "browser", title: "Getting Started | Vite", detail: "vite.dev/guide" },
  ],
  workspaces: [{ id: "w1", name: "billing-service" }],
  sessions: [{ sessionId: "s1", title: "Fix the checkout upload", harness: "claude" }],
  folders: ["/Users/me/code/web-app", "/Users/me/code/billing-service"],
  commands: ["git status -sb", "bun run dev"],
  history: [{ url: "https://vite.dev/config/", title: "Configuring Vite" }],
};

test("a match at the start beats one at a word start, which beats one inside a word", () => {
  expect(matchScore("vi", "Vite")).toBe(3);
  expect(matchScore("vi", "Getting Started | Vite")).toBe(2);
  expect(matchScore("it", "Vite")).toBe(1);
  expect(matchScore("zz", "Vite")).toBe(0);
  expect(matchScore("", "Vite")).toBe(0);
});

test("the empty bar lists open tabs and workspaces first, then recent things", () => {
  const rows = omnibarRows("", "browser", context);
  expect(rows.map((row) => row.type)).toEqual([
    "tab",
    "tab",
    "workspace",
    "session",
    "folder",
    "folder",
    "command",
    "command",
    "history",
  ]);
  expect(rows[0]).toMatchObject({ type: "tab", detail: "web-app · ~/code/web-app" });
  expect(defaultRow(rows, "browser", "")).toBe(-1);
});

test("the web bridge validates and caps each NewTab source", () => {
  const value = omnibarContext({
    tabs: Array.from({ length: MAX_NEW_TAB_ENTRIES + 2 }, (_, index) => ({
      id: `tab-${index}`,
      kind: "terminal",
      title: `tab ${index}`,
    })),
    workspaces: Array.from({ length: MAX_NEW_TAB_ENTRIES + 2 }, (_, index) => ({
      id: `workspace-${index}`,
      name: `workspace ${index}`,
    })),
    folders: Array.from({ length: MAX_NEW_TAB_ENTRIES + 2 }, (_, index) => `/src/${index}`),
    commands: Array.from({ length: MAX_NEW_TAB_ENTRIES + 2 }, (_, index) => `cmd-${index}`),
    history: Array.from({ length: MAX_NEW_TAB_ENTRIES + 2 }, (_, index) => ({ url: `https://example.com/${index}` })),
  });
  expect(value?.tabs).toHaveLength(MAX_NEW_TAB_ENTRIES);
  expect(value?.workspaces).toHaveLength(MAX_NEW_TAB_ENTRIES);
  expect(value?.folders).toHaveLength(MAX_NEW_TAB_ENTRIES);
  expect(value?.commands).toHaveLength(MAX_NEW_TAB_ENTRIES);
  expect(value?.history).toHaveLength(MAX_NEW_TAB_ENTRIES);
});

test("typed text: its own row first, matches from every source, and Ask last", () => {
  const rows = omnibarRows("vite", "browser", context);
  expect(rows[0]).toEqual({ type: "open", text: "vite" });
  expect(rows.at(-1)).toEqual({ type: "ask", text: "vite" });
  // The open Vite tab outranks the history entry for the same site.
  expect(rows.slice(1, -1).map((row) => row.type)).toEqual(["tab", "history"]);
  expect(defaultRow(rows, "browser", "vite")).toBe(0);

  const terminal = omnibarRows("git", "terminal", context);
  expect(terminal[0]).toEqual({ type: "run", text: "git" });
  expect(terminal[1]).toEqual({ type: "command", command: "git status -sb" });

  // Agent text has no first row of its own; Enter takes the last one.
  const agent = omnibarRows("checkout", "agent", context);
  expect(agent.map((row) => row.type)).toEqual(["session", "ask"]);
  expect(defaultRow(agent, "agent", "checkout")).toBe(1);
});

test("typed rows are capped and Ask is never cut", () => {
  const many: OmnibarContext = {
    ...context,
    history: Array.from({ length: 30 }, (_, index) => ({ url: `https://example.com/a${index}`, title: `a ${index}` })),
  };
  const rows = omnibarRows("a", "browser", many);
  expect(rows.length).toBe(MAX_ROWS);
  expect(rows.at(-1)?.type).toBe("ask");
});

// The original bar (NEW-TAB-PAGE-RESTORED): suggestions come from tabs, workspaces, sessions,
// folders, commands and history; a host's files or app actions are not rows.
test("host files and app actions are not suggested", () => {
  const parsed = omnibarContext({
    files: [{ path: "/src/app/README.md", title: "README" }],
    actions: [{ id: "settings", title: "Settings", keywords: ["preferences"] }],
  }) as Record<string, unknown> | undefined;
  expect(parsed?.files).toBeUndefined();
  expect(parsed?.actions).toBeUndefined();
  const withActions = {
    ...context,
    files: [{ path: "/src/app/README.md", title: "Project guide" }],
    actions: [{ id: "settings", title: "Settings", keywords: ["preferences"] }],
  } as OmnibarContext;
  expect(omnibarRows("README", "agent", withActions)).toEqual([{ type: "ask", text: "README" }]);
  expect(omnibarRows("preferences", "agent", withActions)).toEqual([{ type: "ask", text: "preferences" }]);
});
