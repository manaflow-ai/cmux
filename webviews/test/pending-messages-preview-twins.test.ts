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

// Review at 2a2493745a6: a queued message with a waiting steer's words was hidden behind the steer,
// and its queue entry went nowhere, so Send now on the steer left it queued and it came back. A steer
// (already in the running turn) and a queued message (due after it) are two deliveries: the queued one
// stays shown with its own Dismiss and Send now, unless both are the one prompt.
test("a queued message with a waiting steer's words is not hidden behind the steer", () => {
  const words = "#27128 own red fixed and pushed exact d60a3ddc";
  const incoming = { kind: "message" as const, message: { name: "nx-sidebar", text: words, raw: words } };
  const steer = {
    id: "steer-s1",
    version: 1,
    at: 1,
    kind: "user",
    text: words,
    steer: "waiting" as const,
    steerPromptId: "s1",
    incoming,
  };
  const queued = queuedMessageRows(mergeQueue([], [{ promptId: "q1", prompt: words, fromAgent: "nx-sidebar" }]));
  const group = pendingMessagesRow([steer], queued)!;
  // Send now on the steer drops it from the waiting rows; the queued copy must be covered either way:
  // shown on its own now, or carried by a row that still shows.
  const shownIds = group.pendingMessages!.rows.flatMap((row) => [
    row.queuedMessage?.promptId,
    ...(row.queuedMessage?.twins ?? []),
  ]);
  expect(shownIds).toContain("q1");
  // The same prompt as a steer and a queue entry at once is still one message.
  const same = queuedMessageRows(mergeQueue([], [{ promptId: "s1", prompt: words, fromAgent: "nx-sidebar" }]));
  expect(pendingMessagesRow([steer], same)!.pendingMessages!.rows.map((row) => row.id)).toEqual(["steer-s1"]);
});

// Review at 08d5800d46ab: a duplicate that arrives after its shown copy mounted changed the copy's
// `twins` but not its version, so the memoized row (App.tsx QueuedMessageRow, by id and version) kept
// Dismiss and Send now closures without the newcomer, which stayed queued. A member whose twins change
// is a new version; the same twins give the same row back.
test("a duplicate that arrives later gives the shown copy a new version", () => {
  const words = "#27128 own red fixed and pushed exact d60a3ddc";
  const first = mergeQueue([], [{ promptId: "p1", prompt: words, fromAgent: "nx-sidebar" }]);
  const rows1 = queuedMessageRows(first);
  const before = pendingMessagesRow([], rows1)!.pendingMessages!.rows[0]!;
  const second = mergeQueue(first, [
    { promptId: "p1", prompt: words, fromAgent: "nx-sidebar" },
    { promptId: "p2", prompt: words, fromAgent: "nx-sidebar" },
  ]);
  const rows2 = queuedMessageRows(second);
  const group2 = pendingMessagesRow([], rows2)!;
  const after = group2.pendingMessages!.rows[0]!;
  expect(after.id).toBe(before.id);
  expect(after.queuedMessage?.twins).toEqual(["p2"]);
  expect(after.version).not.toBe(before.version);
  // Rebuilt from the same rows, the copy is the same row, so nothing draws again.
  expect(pendingMessagesRow([], [...rows2])!.pendingMessages!.rows[0]).toBe(after);
  // The duplicate goes: the copy is new again, with no twins.
  const gone = pendingMessagesRow([], rows1)!.pendingMessages!.rows[0]!;
  expect(gone.queuedMessage?.twins).toBeUndefined();
  expect(gone.version).not.toBe(after.version);
});
