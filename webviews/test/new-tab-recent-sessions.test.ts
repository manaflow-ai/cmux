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
