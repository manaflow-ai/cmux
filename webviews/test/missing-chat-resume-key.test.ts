// Resume from Transcript opens the exact chat (Lawrence 2026-10-21, "make it one step"): the pane
// keeps each shown session's chat-index key with the app, by the harness family acpmux reports.
import { expect, test } from "bun:test";
import { chatIndexKey } from "../src/agent-session/acpmux/resumeKey";

test("a Claude or Codex session's chat-index key is its index harness and harness session id", () => {
  expect(chatIndexKey("claude", "01a1201b-d407-7930-aa65-657343ecf196")).toBe(
    "claude-code:01a1201b-d407-7930-aa65-657343ecf196",
  );
  expect(chatIndexKey("codex", "019a-1")).toBe("codex:019a-1");
  expect(chatIndexKey("cursor", "c1")).toBe("cursor-agent:c1");
});

test("a harness the index does not read, or no id, has no key", () => {
  expect(chatIndexKey("unii", "x")).toBeUndefined();
  expect(chatIndexKey("claude", "")).toBeUndefined();
  expect(chatIndexKey(undefined, "x")).toBeUndefined();
  expect(chatIndexKey("claude", "../x/y")).toBeUndefined();
});
