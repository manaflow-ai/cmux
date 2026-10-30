// Two distinct messages one session queued must never be folded into one (review at a67dc0e4): after
// a reload the pane knows a queued message only by acpmux's list, whose text is a preview cut at 200
// characters (direct.ts `mergeQueue`). Two messages with different prompt ids whose first 200
// characters match share that preview, yet they are two messages: both show in the waiting group,
// and Dismiss or Send now on one (the shown row's `queuedMessage.twins`) never takes the other.
import { expect, test } from "bun:test";
import { mergeQueue } from "../src/agent-session/acpmux/direct";
import { pendingMemberId, pendingMessagesRow } from "../src/agent-session/acpmux/conversation/pendingMessages";
import { queuedMessageRows } from "../src/agent-session/acpmux/conversation/queuedMessages";

const head = "cmux#27602 review: ".padEnd(200, "x");
// acpmux's preview of a longer prompt: its first 200 characters on one line, then "…" (session.rs short_text).
const preview = `${head}…`;

test("two queued messages sharing a cut preview both show, and neither carries the other", () => {
  const queue = mergeQueue(
    [],
    [
      { promptId: "p-first", prompt: preview, fromAgent: "nx-sidebar" },
      { promptId: "p-second", prompt: preview, fromAgent: "nx-sidebar" },
    ],
  );
  const rows = queuedMessageRows(queue);
  expect(rows.map((row) => row.queuedMessage?.promptId)).toEqual(["p-first", "p-second"]);
  const group = pendingMessagesRow([], rows)!;
  const shown = group.pendingMessages!.rows;
  expect(shown.map((row) => row.queuedMessage?.promptId)).toEqual(["p-first", "p-second"]);
  // Dismiss and Send now act on the row's own entry and its twins alone: none here.
  for (const row of shown) expect(row.queuedMessage?.twins ?? []).toEqual([]);
  // Find lands each match on its own row.
  expect(pendingMemberId(group, "queued-message-p-second")).toBe("queued-message-p-second");
});

test("a relay retried under a new id with its whole, uncut words still shows once", () => {
  const words = "#27128 own red fixed and pushed exact d60a3ddc";
  const queue = mergeQueue(
    [],
    [
      { promptId: "p1", prompt: words, fromAgent: "nx-sidebar" },
      { promptId: "p2", prompt: words, fromAgent: "nx-sidebar" },
    ],
  );
  const group = pendingMessagesRow([], queuedMessageRows(queue))!;
  expect(group.pendingMessages!.rows.map((row) => [row.queuedMessage?.promptId, row.queuedMessage?.twins])).toEqual([
    ["p1", ["p2"]],
  ]);
});

test("a cut preview listed again stays a preview", () => {
  const first = mergeQueue([], [{ promptId: "p1", prompt: preview, fromAgent: "nx-sidebar" }]);
  const again = mergeQueue(first, [{ promptId: "p1", prompt: preview, fromAgent: "nx-sidebar" }]);
  expect(again[0]?.preview).toBe(true);
});
