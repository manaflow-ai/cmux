// Another agent's message waiting in the queue names its sender (direct.ts `queuedFrom`): from
// its provenance as its received line reads it, else acpmux's `fromAgent`. The person's own prompt
// names none, and acpmux's queue list (which names no sender) keeps the one the record gave.
import { expect, test } from "bun:test";
import { mergeQueue, queuedFrom } from "./direct";

test("a queued agent's message names its sender from its provenance, else from fromAgent", () => {
  const message = (provenance: Record<string, unknown>) => ({
    text: "Rebase first",
    client: "acpmux",
    promptId: "p1",
    _meta: { provenance },
  });
  expect(queuedFrom(message({ kind: "agent_message", from: "acp:s-deputy", fromName: "coord-deputy" }))).toBe(
    "coord-deputy",
  );
  expect(
    queuedFrom(
      message({ kind: "session_message", from: "acp:s-lane", fromName: "claude-sr2/lane", fromShortName: "lane" }),
    ),
  ).toBe("lane");
  expect(queuedFrom({ text: "Rebase first", client: "acpmux", fromAgent: " claude-sr2 " })).toBe("claude-sr2");
  // `acpmux send` from a shell names its sender in brackets.
  expect(queuedFrom({ text: "[coord-deputy] Merged #1", client: "acpmux-cli#42" })).toBe("coord-deputy");
});

test("the person's queued prompt names no sender", () => {
  expect(queuedFrom({ text: "Also update the comment", client: "cmux-pane#1" })).toBeUndefined();
  expect(queuedFrom({ text: "[WIP] fix the parser", client: "cmux-pane#1" })).toBeUndefined();
  expect(queuedFrom({ text: "Rebase first", client: "acpmux", fromAgent: "  " })).toBeUndefined();
  expect(queuedFrom(undefined)).toBeUndefined();
});

test("acpmux's queue list keeps the sender its record gave", () => {
  const current = [
    { id: "p1", prompt: "Rebase first", from: "coord-deputy" },
    { id: "p2", prompt: "Also update the comment" },
  ];
  const listed = mergeQueue(current, [
    { promptId: "p2", prompt: "Also update the comment" },
    { promptId: "p1", prompt: "Rebase first" },
  ]);
  expect(listed).toEqual([
    { id: "p2", prompt: "Also update the comment" },
    { id: "p1", prompt: "Rebase first", from: "coord-deputy" },
  ]);
});
