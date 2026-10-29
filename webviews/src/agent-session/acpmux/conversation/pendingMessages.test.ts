// The one group of messages that wait for the agent (pendingMessages.ts): every waiting message in
// it, each once (Leo, 2026-10-29: "nx-sidebar #27128 own red fixed and pushed exact d60a3ddc…"
// shown twice), one that arrives later joins the same group, and messages with different images
// are never folded into one.
import { expect, test } from "bun:test";
import { PENDING_MESSAGES, QUEUED_MESSAGE, type AcpmuxRow } from "../model";
import { bySender, dedupeMessages, PENDING_MESSAGES_ROW_ID, pendingMessagesRow } from "./pendingMessages";

let at = 0;
const queued = (promptId: string, name: string, text: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: `queued-message-${promptId}`,
  version: 1,
  at: at++,
  kind: QUEUED_MESSAGE,
  text,
  incoming: { kind: "message", message: { name, sessionId: `s-${name}`, text, raw: text } },
  queuedMessage: { promptId },
  ...extra,
});
const steer = (promptId: string, name: string, text: string): AcpmuxRow => ({
  id: `steer-${promptId}`,
  version: 1,
  at: at++,
  kind: "user",
  text,
  steer: "waiting",
  steerPromptId: promptId,
  incoming: { kind: "message", message: { name, sessionId: `s-${name}`, text, raw: text } },
});

test("the same delivery or the same sender and words show once", () => {
  const red = "#27128 own red fixed and pushed exact d60a3ddc";
  const rows = [
    queued("p1", "nx-sidebar", red),
    queued("p2", "nx-sidebar", `  ${red} `), // a relay retried under a new id
    queued("p1", "nx-sidebar", "same id, other words"),
    queued("p3", "dep-fleet", red), // another sender's same words are theirs
  ];
  expect(dedupeMessages(rows).map((row) => row.queuedMessage?.promptId)).toEqual(["p1", "p3"]);
  // Nothing repeated: the same array back.
  const distinct = [queued("p4", "a", "one"), queued("p5", "b", "two")];
  expect(dedupeMessages(distinct)).toBe(distinct);
});

test("two messages with the same words and different images are two messages", () => {
  const before = queued("p1", "lane", "See attached", { images: [{ id: "before", mimeType: "image/png" }] });
  const after = queued("p2", "lane", "See attached", { images: [{ id: "after", mimeType: "image/png" }] });
  expect(dedupeMessages([before, after])).toEqual([before, after]);
  // The same delivery twice is still one.
  expect(dedupeMessages([before, { ...before, id: "copy" }])).toEqual([before]);
});

test("every waiting message is in one group, and a later one joins it under the same id", () => {
  const steers = [steer("s1", "claude-sr2/fanout-infra", "cmux#27143 merged")];
  const first = [queued("q1", "dep-fleet", "#27133 at a4e09e88: FAIL"), queued("q2", "nx-sidebar", "pushed")];
  const group = pendingMessagesRow(steers, first)!;
  expect(group.id).toBe(PENDING_MESSAGES_ROW_ID);
  expect(group.kind).toBe(PENDING_MESSAGES);
  expect(group.pendingMessages?.rows.map((row) => row.id)).toEqual(["steer-s1", "queued-message-q1", "queued-message-q2"]);
  // The same rows give the same row back, so the transcript keeps it.
  expect(pendingMessagesRow(steers, first, group)).toBe(group);
  const later = pendingMessagesRow(steers, [...first, queued("q3", "dep-fleet", "#26105 reds")], group)!;
  expect(later.id).toBe(group.id);
  expect(later.pendingMessages?.rows).toHaveLength(4);
  // Opened, by sender, each sender once in the order it first wrote.
  expect(bySender(later.pendingMessages!.rows).map((each) => [each.key, each.rows.length])).toEqual([
    ["s-claude-sr2/fanout-infra", 1],
    ["s-dep-fleet", 2],
    ["s-nx-sidebar", 1],
  ]);
  // Nothing waits: no group.
  expect(pendingMessagesRow([], [])).toBeUndefined();
});
