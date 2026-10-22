// Another agent's message waiting in the queue is that message (direct.ts `queuedMessage`), which
// its row draws as its received line: as its provenance gives it, as the transcript reads it once
// it runs, else as acpmux's `fromAgent` names its sender. The person's own prompt is none, and
// acpmux's queue list (which names no sender) keeps the one the record gave.
import { expect, test } from "bun:test";
import { mergeQueue, queuedMessage } from "./direct";

test("a queued agent's message reads as its provenance gives it", () => {
  const message = (provenance: Record<string, unknown>) => ({
    text: "Rebase first",
    client: "acpmux",
    promptId: "p1",
    _meta: { provenance },
  });
  expect(queuedMessage(message({ kind: "agent_message", from: "acp:s-deputy", fromName: "coord-deputy" }))).toEqual({
    name: "coord-deputy",
    sessionId: "s-deputy",
    text: "Rebase first",
    raw: "Rebase first",
  });
  expect(
    queuedMessage(
      message({ kind: "session_message", from: "acp:s-lane", fromName: "claude-sr2/lane", fromShortName: "lane" }),
    ),
  ).toEqual({ name: "lane", sessionId: "s-lane", text: "Rebase first", raw: "Rebase first" });
  // `acpmux send` from a shell names its sender in brackets.
  expect(queuedMessage({ text: "[coord-deputy] Merged #1", client: "acpmux-cli#42" })).toEqual({
    name: "coord-deputy",
    text: "Merged #1",
    raw: "[coord-deputy] Merged #1",
  });
});

test("acpmux's fromAgent names the sender, and a lead that only repeats it goes", () => {
  expect(queuedMessage({ text: "Rebase first", client: "acpmux", fromAgent: " claude-sr2 " })).toEqual({
    name: "claude-sr2",
    text: "Rebase first",
    raw: "Rebase first",
  });
  expect(
    queuedMessage({ text: "From claude-sr2: Rebase first", client: "acpmux", fromAgent: "claude-sr2" })?.text,
  ).toBe("Rebase first");
  expect(queuedMessage({ text: "[claude-sr2] Rebase first", client: "acpmux", fromAgent: "claude-sr2" })?.text).toBe(
    "Rebase first",
  );
  // Another name in brackets is the message's own text.
  expect(queuedMessage({ text: "[WIP] Rebase first", client: "acpmux", fromAgent: "claude-sr2" })?.text).toBe(
    "[WIP] Rebase first",
  );
});

test("the person's queued prompt is no agent's message", () => {
  expect(queuedMessage({ text: "Also update the comment", client: "cmux-pane#1" })).toBeUndefined();
  expect(queuedMessage({ text: "[WIP] fix the parser", client: "cmux-pane#1" })).toBeUndefined();
  expect(queuedMessage({ text: "Rebase first", client: "acpmux", fromAgent: "  " })).toBeUndefined();
  expect(queuedMessage(undefined)).toBeUndefined();
});

test("acpmux's queue list keeps the message its record gave", () => {
  const message = { name: "coord-deputy", text: "Rebase first", raw: "Rebase first" };
  const current = [
    { id: "p1", prompt: "Rebase first", message },
    { id: "p2", prompt: "Also update the comment" },
  ];
  const listed = mergeQueue(current, [
    { promptId: "p2", prompt: "Also update the comment" },
    { promptId: "p1", prompt: "Rebase first" },
  ]);
  expect(listed).toEqual([
    { id: "p2", prompt: "Also update the comment" },
    { id: "p1", prompt: "Rebase first", message },
  ]);
});
