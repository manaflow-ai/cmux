// l10n-allow-file: test fixture prompts, not shipped UI.
// A prompt the reader sent by hand (jumpUp.ts `ownPrompt`), which is never unseen (jumpControl.ts
// `countsUnseen`): never another agent's message, a task's result, the Chief's message to a subagent,
// or another person's prompt in a shared chat.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "./model";
import { ownPrompt } from "./jumpUp";

const row = (id: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: Number(id.replace(/\D/g, "")) || 0,
  kind: "user",
  text: id,
  ...extra,
});
const reply = (id: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "agent", text: "ok" });

test("a prompt the reader typed is theirs; the ones they did not type are not", () => {
  expect(ownPrompt(row("typed-1"))).toBe(true);
  expect(ownPrompt(reply("reply-1"))).toBe(false);
  expect(ownPrompt(row("task-result-3", { untyped: true }))).toBe(false);
  expect(ownPrompt(row("agent-message-4", { incoming: { kind: "message" } as AcpmuxRow["incoming"] }))).toBe(false);
  expect(ownPrompt(row("chief-5", { from: "chief" }))).toBe(false);
});

test("in a shared chat, yours is the one with your author: none for the owner, your id for a guest", () => {
  const guest = { id: "guest-1", name: "Sam" };
  const other = { id: "guest-2", name: "Kim" };
  expect(ownPrompt(row("owner-1"))).toBe(true);
  expect(ownPrompt(row("guest-2", { author: guest }))).toBe(false);
  expect(ownPrompt(row("guest-2", { author: guest }), "guest-1")).toBe(true);
  expect(ownPrompt(row("other-3", { author: other }), "guest-1")).toBe(false);
  expect(ownPrompt(row("owner-1"), "guest-3")).toBe(false);
});
