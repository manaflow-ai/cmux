// #25588: a Chief's thread reply showed at the top level of the Chief chat, under its parent drawn
// again. A reply that names the message it answers but not the thread (`reply_to` only: a reply from
// before threads, an inline reply, a Chief host that posts only `reply_to`) took that message as its
// thread root, so a reply to a thread reply became a "thread" of its own under a reply, outside the
// real thread. Such a reply is in the thread of the message it answers: that message's root.
//
// The messages go through the page's wire mapping (daemonHome `message`) and window merge, as the
// owner's snapshot and events reach the page.
import { expect, test } from "bun:test";
import { message as wire } from "../src/pages/home-channels/daemonHome";
import { mergeMessages, threadMessages, threadTree, timelineRows } from "../src/pages/home-channels/model";

const raw = (seq: number, author: string, extra: Record<string, unknown> = {}) => ({
  id: `msg_${seq}`,
  conversation: "conv_chief",
  seq,
  author,
  created_at: new Date(Date.UTC(2026, 9, 26, 12, 0, seq)).toISOString(),
  parts: [{ type: "text", text: `${author} ${seq}` }],
  reactions: [],
  client_msg_id: `key_${seq}`,
  ...extra,
});
const replyTo = (id: string) => ({ reply_to: { message_id: id, part_index: 0 } });
const window = (...messages: ReturnType<typeof raw>[]) => mergeMessages([], messages.map(wire), 200);
const shown = (messages: ReturnType<typeof window>) =>
  timelineRows(messages).flatMap((row) => (row.kind === "message" ? [[row.message.id, row.thread?.count]] : []));
const replies = (messages: ReturnType<typeof window>, root: string) =>
  threadMessages(messages, root).replies.map((m) => m.id);

test("a Chief reply to my thread reply that names no thread shows once, in that thread", () => {
  const messages = window(
    raw(1, "user_local"),
    raw(2, "user_local", { ...replyTo("msg_1"), thread_root: "msg_1" }),
    raw(3, "agent_chief", replyTo("msg_2")),
    raw(4, "agent_chief", replyTo("msg_2")),
  );
  // The parent once at the top level, with every reply counted; no reply or second parent there.
  expect(shown(messages)).toEqual([["msg_1", 3]]);
  expect(replies(messages, "msg_1")).toEqual(["msg_2", "msg_3", "msg_4"]);
  // In the thread the Chief's replies hang under the message they answer.
  expect(threadTree(threadMessages(messages, "msg_1").replies, "msg_1").map((n) => [n.message.id, n.depth])).toEqual([
    ["msg_2", 1],
    ["msg_3", 2],
    ["msg_4", 2],
  ]);
});

test("a chain of replies without roots stays in the first message's thread", () => {
  const messages = window(
    raw(1, "user_local"),
    raw(2, "agent_chief", replyTo("msg_1")),
    raw(3, "user_local", replyTo("msg_2")),
    raw(4, "agent_chief", replyTo("msg_3")),
  );
  expect(shown(messages)).toEqual([["msg_1", 3]]);
  expect(replies(messages, "msg_1")).toEqual(["msg_2", "msg_3", "msg_4"]);
});

test("a reply that arrives before the thread reply it answers moves into the thread once that loads", () => {
  // An event (the reply) before an older page (the message it answers).
  const live = window(raw(5, "user_local"), raw(9, "agent_chief", replyTo("msg_7")));
  const merged = mergeMessages(
    live,
    [raw(6, "user_local"), raw(7, "user_local", { ...replyTo("msg_6"), thread_root: "msg_6" })].map(wire),
    200,
  );
  expect(shown(merged)).toEqual([
    ["msg_5", undefined],
    ["msg_6", 2],
  ]);
  expect(replies(merged, "msg_6")).toEqual(["msg_7", "msg_9"]);
});

test("a reply to a top-level message and a reply loop keep their threads", () => {
  const top = window(raw(1, "user_local"), raw(2, "agent_chief", replyTo("msg_1")));
  expect(shown(top)).toEqual([["msg_1", 1]]);
  const loop = window(raw(1, "user_local", replyTo("msg_2")), raw(2, "agent_chief", replyTo("msg_1")));
  // Each answers the other: neither is a top-level row, and the merge ends.
  expect(shown(loop)).toEqual([]);
});
