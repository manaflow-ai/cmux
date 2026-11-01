// l10n-allow-file: test fixture subagent names and prompts, not shipped UI.
import { expect, test } from "bun:test";
import { translate } from "../i18n";
import { canRestart, restartOwner, restartPrompt, restartReaches } from "./restart";

const ended = { state: "cancelled", parent: null, name: "Reviewer", prompt: "Review src/app.ts" } as const;

test("Restart is offered for a stopped, failed or lost subagent of the chat's own, with its prompt", () => {
  expect(canRestart(ended)).toBe(true);
  expect(canRestart({ ...ended, state: "failed" })).toBe(true);
  expect(canRestart({ ...ended, state: "disconnected" })).toBe(true);
  expect(canRestart({ ...ended, state: "completed" })).toBe(false);
  expect(canRestart({ ...ended, state: "running" })).toBe(false);
  expect(canRestart({ ...ended, parent: "a" })).toBe(false);
  expect(canRestart({ ...ended, prompt: undefined })).toBe(false);
});

test("the prompt asks the agent to run it again with its kind and prompt, as given", () => {
  expect(restartPrompt({ ...ended, kind: "Explore" }, translate)).toBe(
    'Run the Explore subagent "Reviewer" again with the same prompt:\n\nReview src/app.ts',
  );
  expect(restartPrompt({ ...ended, prompt: "Use {name} literally" }, translate)).toBe(
    'Run the subagent "Reviewer" again with the same prompt:\n\nUse {name} literally',
  );
  expect(restartPrompt({ ...ended, state: "completed" }, translate)).toBeUndefined();
});

test("Restart is offered only where the composer would send: connected, not View Only, not read-only, sendable", () => {
  const chat = { connected: true, sessionId: "s1", watching: false, readOnly: false, canSend: true };
  expect(restartOwner(chat)).toBe("s1");
  expect(restartOwner({ ...chat, connected: false })).toBeUndefined();
  expect(restartOwner({ ...chat, sessionId: undefined })).toBeUndefined();
  expect(restartOwner({ ...chat, watching: true })).toBeUndefined();
  expect(restartOwner({ ...chat, readOnly: true })).toBeUndefined();
  // A remote Codex or opencode chat, whose composer cannot send.
  expect(restartOwner({ ...chat, canSend: false })).toBeUndefined();
});

test("a Restart reaches only the chat its row was drawn for, never the next chat during a switch's hold", () => {
  expect(restartReaches("s1", "s1", "s1")).toBe(true);
  // The pane moved on: a row left over from the chat before.
  expect(restartReaches("s1", "s2", "s2")).toBe(false);
  // The hold: the pane still draws s1 while the client, which chat.send writes to, names s2.
  expect(restartReaches("s1", "s1", "s2")).toBe(false);
  expect(restartReaches("s1", "s1", undefined)).toBe(false);
});
