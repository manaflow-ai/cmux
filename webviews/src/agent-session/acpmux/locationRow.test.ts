import { expect, test } from "bun:test";
import { chatHasFirstSend } from "./locationRow";

const empty = { sessionId: "s1", summary: undefined, rows: [], queue: [], isWorking: false, canLoadOlder: false };

test("a relaunch's drawn tail of agent replies, before any summary, is a chat with a first send", () => {
  // The ring then has its place from the first frame instead of coming in with the summary (ask-66b7d014c3).
  const rows = [{ id: "r1", version: 1, at: 1, kind: "assistant", text: "Done." }];
  expect(chatHasFirstSend({ ...empty, rows })).toBe(true);
});

test("a new chat, and one whose only send failed, have no first send", () => {
  expect(chatHasFirstSend(empty)).toBe(false);
  const rows = [{ id: "u1", version: 1, at: 1, kind: "user", text: "Add retries", failed: true }];
  expect(chatHasFirstSend({ ...empty, rows } as Parameters<typeof chatHasFirstSend>[0])).toBe(false);
});
