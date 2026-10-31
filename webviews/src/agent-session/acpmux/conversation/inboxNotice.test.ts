// l10n-allow-file: test fixtures.
// acpmux's inbox notices next to each other draw as one (inboxNotice.ts `mergeInboxNotices`).
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { joinNotices, mergeInboxNotices, threadLabel, type InboxNotice, type InboxThread } from "./inboxNotice";

const thread = (threadId: string, from: string, count = 1, fields: Partial<InboxThread> = {}): InboxThread => ({
  threadId,
  label: threadLabel(threadId),
  from: [from],
  count,
  preview: `${from} says`,
  blocker: false,
  promptIds: Array.from({ length: count }, (_, i) => `${threadId}-${from}-${i}`),
  ...fields,
});

const notice = (id: string, threads: InboxThread[]): AcpmuxRow => ({
  id,
  version: 1,
  at: 1,
  kind: "user",
  text: "",
  incoming: { kind: "inbox", notice: { threads } },
});
const reply = (id: string): AcpmuxRow => ({ id, version: 1, at: 2, kind: "assistant", text: "ok" });
const hidden = (id: string): AcpmuxRow => ({
  id,
  version: 1,
  at: 2,
  kind: "user",
  text: "",
  incoming: { kind: "hidden" },
});
const threadsOf = (row: AcpmuxRow) => (row.incoming as { kind: "inbox"; notice: InboxNotice }).notice.threads;

test("a thread's label: a pull request, a topic, or none for a sender's own thread", () => {
  expect(threadLabel("pr:9")).toBe("#9");
  expect(threadLabel("from:lane-a/pr:27686")).toBe("#27686");
  expect(threadLabel("topic:plan")).toBe("plan");
  expect(threadLabel("from:lane-a")).toBe("");
});

test("rows with no run of notices come back as the same array", () => {
  const rows = [notice("n1", [thread("pr:9", "a")]), reply("r1"), notice("n2", [thread("pr:9", "a")])];
  expect(mergeInboxNotices(rows)).toBe(rows);
});

test("notices next to each other are one row, a thread in both once", () => {
  const rows = [
    reply("r0"),
    notice("n1", [thread("pr:9", "lane-a")]),
    hidden("h1"),
    notice("n2", [thread("pr:9", "lane-c", 2), thread("topic:plan", "lane-d")]),
    notice("n3", [thread("from:lane-b", "lane-b")]),
    reply("r1"),
  ];
  const merged = mergeInboxNotices(rows);
  expect(merged.map((row) => row.id)).toEqual(["r0", "n1", "r1"]);
  const row = merged[1]!;
  expect(row.joined).toEqual(["n2", "n3"]);
  const threads = threadsOf(row);
  expect(threads.map((t) => t.threadId)).toEqual(["pr:9", "topic:plan", "from:lane-b"]);
  expect(threads[0]).toMatchObject({ from: ["lane-a", "lane-c"], count: 3, preview: "lane-c says" });
  // Find reads the run's words.
  expect(row.text).toContain("lane-b says");
  // The same rows give the same merged row back.
  expect(mergeInboxNotices([...rows])[1]).toBe(row);
});

test("another chat's notices with the same row ids and versions never get this chat's merged row", () => {
  const ours = [notice("n1", [thread("pr:9", "lane-a")]), notice("n2", [thread("pr:7", "lane-b")])];
  const theirs = [notice("n1", [thread("pr:3", "other-a")]), notice("n2", [thread("pr:4", "other-b")])];
  const mine = mergeInboxNotices(ours)[0]!;
  const other = mergeInboxNotices(theirs)[0]!;
  expect(other).not.toBe(mine);
  expect(threadsOf(other).map((t) => t.threadId)).toEqual(["pr:3", "pr:4"]);
});

test("a joined thread keeps its messages whole only when both notices held them", () => {
  const whole = (from: string) => thread("pr:9", from, 1, { messages: [{ from, text: `${from} text` }] });
  const both = joinNotices({ threads: [whole("a")] }, { threads: [whole("b")] });
  expect(both.threads[0]?.messages?.map((m) => m.text)).toEqual(["a text", "b text"]);
  const one = joinNotices({ threads: [whole("a")] }, { threads: [thread("pr:9", "b")] });
  expect(one.threads[0]?.messages).toBeUndefined();
  expect(one.threads[0]?.blocker).toBe(false);
});
