// acpmux's inbox notice waiting in the queue (provenance `inbox_notice`, hub/inbox.rs
// `deliver_notice`) is other agents' messages, not the person's prompt (Leo, 2026-11-03: "have it be
// rendered differently than just a regular queued message"). direct.ts reads it from its `queued`
// record (`queuedInbox`) and keeps it through acpmux's list (`mergeQueue`, whose `fromAgent` is null
// for a notice); queuedMessages.ts leaves it out of the composer's queue and draws it in the one
// group of waiting messages, as its threads, the queue's Send now on the first.
import { expect, test } from "bun:test";
import { mergeQueue, queuedInbox } from "../direct";
import { QUEUED_MESSAGE, type AcpmuxSnapshot } from "../model";
import { pendingMessagesRow } from "./pendingMessages";
import { ownQueue, queuedMessageRowId, queuedMessageRows } from "./queuedMessages";

const threads = [
  {
    threadId: "from:grid-lane/pr:2210",
    label: "#2210",
    new: 2,
    from: ["grid-lane"],
    fromSession: "s-grid",
    promptIds: ["m1", "m2"],
    blocker: false,
    preview: "Review passed at e34ce27; landing it now.",
  },
  {
    threadId: "topic:picker plan",
    label: '"picker plan"',
    new: 1,
    from: ["picker-lane"],
    fromSession: "s-picker",
    promptIds: ["m3"],
    blocker: true,
    preview: "Which branch should the picker polish go on?",
  },
];

const text = [
  "[inbox] New messages from other agents in 2 threads. Read one whole with inbox_read (its thread id).",
  "- 2 new in #2210 from grid-lane: Review passed at e34ce27; landing it now. (thread from:grid-lane/pr:2210)",
  '- [blocker] 1 new in "picker plan" from picker-lane: Which branch should the picker polish go on? (thread topic:picker plan)',
].join("\n");

/// The `queued` record hub/queue.rs writes for the notice: no `fromAgent`, its threads in its provenance.
const record = {
  text,
  client: "acpmux",
  promptId: "inbox-notice-1",
  turnId: "t-inbox-notice-1",
  prompt: [{ type: "text", text }],
  _meta: { provenance: { kind: "inbox_notice", noticeId: "inbox-notice-1", threads } },
};

test("a queued record of an inbox notice reads as its threads, not as an agent's message", () => {
  const notice = queuedInbox(record);
  expect(notice?.threads.map((thread) => thread.threadId)).toEqual(["from:grid-lane/pr:2210", "topic:picker plan"]);
  expect(notice?.threads[1]?.blocker).toBe(true);
  // The person's own prompt is no notice.
  expect(queuedInbox({ text: "Then add a test", client: "pane" })).toBeUndefined();
});

test("acpmux's list keeps the notice its record named, and an edit drops it", () => {
  const preview = text.split("\n").join(" ").slice(0, 200);
  const had = [{ id: "inbox-notice-1", prompt: text, inbox: queuedInbox(record)! }];
  const listed = [{ promptId: "inbox-notice-1", prompt: `${preview}…`, fromAgent: null }];
  const [kept] = mergeQueue(had, listed);
  expect(kept?.inbox?.threads).toHaveLength(2);
  expect(kept?.message).toBeUndefined();
  // An edit made it the person's: no notice.
  const [edited] = mergeQueue(
    had,
    [{ promptId: "inbox-notice-1", prompt: "my words now", fromAgent: null }],
    undefined,
    new Set(["inbox-notice-1"]),
  );
  expect(edited?.inbox).toBeUndefined();
});

test("the notice is no composer-queue row; it joins the waiting messages as its threads", () => {
  const own = { id: "p1", prompt: "Then add a test" };
  const notice = { id: "inbox-notice-1", prompt: text, inbox: queuedInbox(record)! };
  const queue: AcpmuxSnapshot["queue"] = [notice, own];
  expect(ownQueue(queue)).toEqual([own]);
  const rows = queuedMessageRows(queue);
  expect(rows.map((row) => row.id)).toEqual([queuedMessageRowId("inbox-notice-1")]);
  expect(rows[0]?.kind).toBe(QUEUED_MESSAGE);
  expect(rows[0]?.incoming?.kind).toBe("inbox");
  // Its text is the messages', never the instruction written for the agent.
  expect(rows[0]?.text).not.toContain("inbox_read");
  const group = pendingMessagesRow([], rows)!;
  const display = group.pendingMessages?.displayRows ?? [];
  expect(display.map((row) => row.text)).toEqual([
    "Review passed at e34ce27; landing it now.",
    "Which branch should the picker polish go on?",
  ]);
  expect(display.some((row) => row.text?.includes("New messages from other agents"))).toBe(false);
  // One queue target for the whole notice: its Send now sits on the first line alone.
  expect(display.filter((row) => row.inboxQueue?.promptId === "inbox-notice-1")).toHaveLength(1);
});
