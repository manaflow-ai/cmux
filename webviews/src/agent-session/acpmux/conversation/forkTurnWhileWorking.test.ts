// l10n-allow-file: test fixtures.
// The Fork under a finished turn's footer and a prompt must not wait for later turns to end: with a
// later turn running (an agent's message, a background finish, the person's next prompt) it used to
// vanish from every earlier turn, then come back when the chat went idle.
import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "../model";
import { canForkTurn, messageMenuTarget } from "./messageMenu";

const rows = [
  { id: "u1", kind: "user", text: "first", at: 1 },
  { id: "a1", kind: "assistant", text: "answer one", at: 2 },
  { id: "summary-t1", kind: "turnSummary", seq: 7, at: 3 },
  { id: "u2", kind: "user", text: "second", at: 4 },
  { id: "a2", kind: "assistant", text: "working on it", at: 5, streaming: true },
];
const snapshot = (family: string, isWorking: boolean) =>
  ({
    canFork: true,
    isWorking,
    link: "connected",
    emitReason: "connected",
    connection: "connected",
    summary: { family },
    rows,
  }) as unknown as AcpmuxSnapshot;

test("a Claude or Codex chat forks a finished turn while a later turn runs", () => {
  for (const family of ["claude", "codex"]) {
    expect(canForkTurn(snapshot(family, true))).toBe(true);
    expect(canForkTurn(snapshot(family, false))).toBe(true);
    expect(messageMenuTarget(snapshot(family, true), "a1")?.forkSeq).toBe(7);
    expect(messageMenuTarget(snapshot(family, true), "u1")?.forkSeq).toBe(7);
  }
});

test("another agent forks only at an idle chat's end", () => {
  expect(canForkTurn(snapshot("gemini", true))).toBe(false);
  expect(canForkTurn(snapshot("gemini", false))).toBe(true);
});

test("an unserved or disconnected chat forks nothing", () => {
  expect(canForkTurn({ ...snapshot("claude", true), canFork: false } as AcpmuxSnapshot)).toBe(false);
  expect(
    canForkTurn({
      ...snapshot("claude", true),
      link: "disconnected",
      emitReason: "disconnected",
      connection: "disconnected",
    } as AcpmuxSnapshot),
  ).toBe(false);
});

test("the running turn shows no Fork, and Fork Conversation (forkRefusal, forkToTarget) is unchanged", async () => {
  const { promptTurns } = await import("./editPrompt");
  const { forkRefusal, forkToTarget } = await import("./messageMenu");
  expect([...promptTurns(rows as never)]).toEqual([["u1", 7]]);
  expect(messageMenuTarget(snapshot("claude", true), "a2")?.forkSeq).toBeUndefined();
  expect(messageMenuTarget(snapshot("claude", true), "u2")?.forkSeq).toBeUndefined();
  expect(forkRefusal(snapshot("claude", true))).toBeUndefined();
  expect(forkToTarget(snapshot("claude", true))).toEqual({ live: true });
  expect(forkToTarget(snapshot("claude", false))).toEqual({ throughSeq: 7 });
});
