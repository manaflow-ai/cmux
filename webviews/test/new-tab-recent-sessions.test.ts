import { expect, test } from "bun:test";
import { recentSessions } from "../src/agent-session/acpmux/NewTabPage";
import { recentChatCards } from "../src/agent-session/acpmux/newtab/screenModel";
import { normalizedSessionEntry, type AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

const entry = (id: string, updatedAt: number): AcpmuxSessionEntry => ({
  sessionId: id,
  displayTitle: id,
  updatedAt,
});

test("recent sessions preserve normalized snapshot entry identity", () => {
  const first = entry("first", 2);
  const second = entry("second", 1);
  const recent = recentSessions([first, second]);
  expect(recent[0]).toBe(first);
  expect(recent[1]).toBe(second);
});

test("raw session summaries still normalize", () => {
  const raw = { sessionId: "raw", name: "raw-name", harness: "codex" };
  expect(normalizedSessionEntry(raw).displayTitle).toBe("raw-name");
});

test("folded recent sessions reuse urgency order while keeping the count cut", () => {
  const sessions = [
    { ...entry("parent", 1), spawnedBy: undefined },
    { ...entry("child", 4), spawnedBy: "parent" },
    { ...entry("waiting", 2), state: "input" as const },
  ];
  expect(recentSessions(sessions, 2, true).map((session) => session.sessionId)).toEqual(["waiting", "parent"]);
});

test("a device chat child is rendered once when its parent key names both card ids", () => {
  const cards = recentChatCards(
    [],
    0,
    undefined,
    [
      { key: "codex:parent", harness: "codex", title: "Parent", updatedAt: 2 },
      { key: "codex:child", harness: "codex", title: "Child", updatedAt: 1, parent: "codex:parent" },
    ],
    1,
    true,
  );
  expect(cards[0]?.children?.map((child) => child.chatKey)).toEqual(["codex:child"]);
});

// Leo 2026-10-18: picking a model on a New Tab starts its chat's session at once (deferred), and
// the New Tab's Chats list gained an empty "New chat" row on top, pushing every chat down. A chat
// nothing was sent in yet (acpmux: no last prompt, no turn) is not a recent chat.
test("a chat nothing was sent in yet stays off the recent chats", () => {
  const sent = { sessionId: "sent", name: "Fix the build", lastPrompt: "fix the build", turnCount: 1, updatedAt: 1 };
  const running = { sessionId: "running", name: "first turn", lastPrompt: "hello", turnCount: 0, updatedAt: 2 };
  const unsent = { sessionId: "unsent", lastPrompt: null, turnCount: 0, updatedAt: 3 };
  expect(recentSessions([sent, running, unsent]).map((session) => session.sessionId)).toEqual(["running", "sent"]);
  expect(recentChatCards([sent, running, unsent], 0).map((card) => card.sessionId)).toEqual(["running", "sent"]);
});
