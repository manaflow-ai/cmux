import { expect, test } from "bun:test";
import { recentSessions } from "../src/agent-session/acpmux/NewTabPage";
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
