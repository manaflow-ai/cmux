import { expect, test } from "bun:test";
import { composerPlusContextEntries, insertContextSession, recentComposerSessions } from "./composerPlusContext";

test("recent context rows are stable, exclude current chat and retain lanes", () => {
  const rows = recentComposerSessions(
    [
      { sessionId: "current", title: "Current", updatedAt: 100 },
      { sessionId: "old", title: "Old", updatedAt: 10, archived: true },
      { sessionId: "lane", displayTitle: "Lint\nchecks", activityAt: 30, spawnedBy: "parent", harness: "codex" },
      { sessionId: "new", title: "Newest", activityAt: 40, host: "gcp-1" },
    ],
    "current",
  );
  expect(rows.map((row) => [row.id, row.name])).toEqual([
    ["session:new", "Newest"],
    ["session:lane", "Lint checks"],
  ]);
  expect(rows[1]?.description).toBe("Insert this chat as context");
});

test("context entries reject malformed or cross-section selections and dedupe ids", () => {
  const rows = composerPlusContextEntries([
    {
      id: "s",
      section: "sessions",
      name: "Chat",
      description: "Recent",
      icon: "agent.chat",
      selection: { kind: "session", sessionId: "s-1" },
    },
    {
      id: "s",
      section: "sessions",
      name: "duplicate",
      description: "ignored",
      icon: "agent.chat",
      selection: { kind: "session", sessionId: "s-2" },
    },
    {
      id: "wrong",
      section: "tabs",
      name: "wrong",
      description: "wrong",
      icon: "browser",
      selection: { kind: "session", sessionId: "s-3" },
    },
    {
      id: "tab",
      section: "tabs",
      name: "Browser",
      description: "Chosen tab",
      icon: "browser",
      selection: { kind: "tab", tabId: "tab-7", source: "browser" },
    },
  ]);
  expect(rows.map((row) => row.id)).toEqual(["context:s", "context:tab"]);
  expect(rows[1]?.action).toEqual({ kind: "context", itemId: "tab" });
});

test("session context inserts at the caret without dropping either draft side", () => {
  const result = insertContextSession("before after", 7, "A chat", "sess-1");
  expect(result.text).toBe('before cmux session "A chat" (sess-1) after');
  expect(result.caret).toBe('before cmux session "A chat" (sess-1) '.length);
});
