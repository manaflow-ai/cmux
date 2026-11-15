// l10n-allow-file: test fixtures.
// acpmux's inbox notices next to each other draw as one (inboxNotice.ts `mergeInboxNotices`).
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import {
  inboxMessages,
  inboxNotice,
  joinNotices,
  mergeInboxNotices,
  threadLabel,
  type InboxNotice,
  type InboxThread,
} from "./inboxNotice";

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

// chat-fork-fast's agent chip (#37626) opens a sender by its record: the name reads bare, the
// record keeps the declared label and session whole.
test("a bare sender name keeps its record's label and session", () => {
  const sender = {
    label: "gcp-agent-lane-2/lock-proof-routes",
    labelDeclared: true,
    session: "s-9",
    verification: "declared",
  };
  const notice = inboxNotice("[inbox] New messages from other agents in 1 thread.", {
    threads: [
      {
        threadId: "declared:gcp-agent-lane-2/lock-proof-routes",
        label: "gcp-agent-lane-2/lock-proof-routes (self-declared, unauthenticated)",
        from: ["gcp-agent-lane-2/lock-proof-routes (self-declared, unauthenticated)"],
        promptIds: ["p1"],
        preview: "done",
        sender,
        messages: [
          {
            promptId: "p1",
            from: "gcp-agent-lane-2/lock-proof-routes (self-declared, unauthenticated)",
            text: "done",
            sender,
          },
        ],
      },
    ],
  });
  const thread = notice!.threads[0]!;
  expect(thread.from).toEqual(["gcp-agent-lane-2/lock-proof-routes"]);
  expect(thread.sender).toMatchObject({ label: sender.label, session: "s-9" });
  expect(thread.messages![0]!.sender).toMatchObject({ label: sender.label, session: "s-9" });
});

test("an opened thread names each sender by its plain name, not the agent's words", () => {
  // `_acpmux/inbox_thread` gives `fromName` for the transcript; `from` is what the agent reads.
  const opened = [{ from: "dot (self-declared, unauthenticated)", fromName: "dot", text: "hello", at: 1 }];
  // The agent's words still mark it unverified (the row's marker, never words in the name).
  expect(inboxMessages(opened)).toEqual([{ from: "dot", text: "hello", at: 1, unverified: true }]);
  // A daemon from before `fromName`: its `from` as given.
  expect(inboxMessages([{ from: "lane-a", text: "hi" }])).toEqual([{ from: "lane-a", text: "hi" }]);
});

// Review of #37653: a sender record that says `authenticated: false` is unverified whatever else it
// names; an acpmux that wrote no `verification` nor `labelDeclared` still said so.
test("a sender record with authenticated false is unverified without labelDeclared", () => {
  const [plain, proven] = inboxMessages([
    { from: "lane-a", text: "hi", sender: { authenticated: false, label: "lane-a" } },
    { from: "lane-b", text: "hi", sender: { authenticated: true, session: "s-b" } },
  ]);
  expect(plain?.unverified).toBe(true);
  expect(proven?.unverified).toBeUndefined();
});

// Review of #37653: a later notice of the same sender that names less about it (no record, no
// session, no harness, no unverified mark) keeps what the earlier one said; a later notice from
// another sender speaks for itself.
test("a joined thread keeps the earlier notice's sender metadata for the same sender", () => {
  const earlier = thread("pr:9", "lane-a", 1, {
    sender: { label: "vm-1/lane-a", session: "s-a" },
    fromSession: "s-a",
    fromHarness: "codex",
    unverified: true,
  });
  const same = joinNotices({ threads: [earlier] }, { threads: [thread("pr:9", "lane-a")] }).threads[0]!;
  expect(same).toMatchObject({
    sender: { label: "vm-1/lane-a", session: "s-a" },
    fromSession: "s-a",
    fromHarness: "codex",
    unverified: true,
    count: 2,
  });
  // Two chats named lane-a (cmux#38642 review): the later notice's own record names s-b, so the
  // joined thread opens s-b, and nothing of s-a's record fills a field of it.
  const twin = joinNotices(
    { threads: [earlier] },
    { threads: [thread("pr:9", "lane-a", 1, { sender: { session: "s-b" } })] },
  ).threads[0]!;
  expect(twin.sender).toEqual({ session: "s-b" });
  expect(twin.fromSession).toBeUndefined();
  expect(twin.fromHarness).toBeUndefined();
  expect(twin.unverified).toBeUndefined();
  // The same chat by its session id: what the later notice leaves out still holds.
  const agreed = joinNotices(
    { threads: [earlier] },
    { threads: [thread("pr:9", "lane-a", 1, { sender: { session: "s-a" } })] },
  ).threads[0]!;
  expect(agreed).toMatchObject({ sender: { session: "s-a" }, fromSession: "s-a", fromHarness: "codex" });
  const other = joinNotices({ threads: [earlier] }, { threads: [thread("pr:9", "lane-b")] }).threads[0]!;
  expect(other.sender).toBeUndefined();
  expect(other.fromSession).toBeUndefined();
  expect(other.fromHarness).toBeUndefined();
  expect(other.unverified).toBeUndefined();
});

// cmux#38642 review: acpmux may mark only the thread unverified, and the thread's newest message
// takes that mark from its own notice. A later notice whose thread names no record but whose newest
// message carries its own (verified) one speaks for that sender: the join keeps each message's mark
// from its own notice, and the earlier notice's thread-level mark never reaches the newest message
// (nor the line, which names the newest sender). Its own record's session is its chat too, so a
// second chat of the same name takes nothing of the first one's.
test("a join never lends an earlier thread's unverified mark to a newest message its notice did not mark", () => {
  const earlier = inboxNotice("[inbox] 1 thread.", {
    threads: [
      {
        threadId: "pr:9",
        from: ["lane-a"],
        promptIds: ["p1"],
        preview: "first",
        sender: { label: "lane-a", session: "s-a", verification: "declared" },
        messages: [{ promptId: "p1", from: "lane-a", text: "first" }],
      },
    ],
  })!;
  expect(earlier.threads[0]!.unverified).toBe(true);
  expect(earlier.threads[0]!.messages![0]!.unverified).toBe(true);
  const later = (session: string) =>
    inboxNotice("[inbox] 1 thread.", {
      threads: [
        {
          threadId: "pr:9",
          from: ["lane-a"],
          promptIds: ["p2"],
          preview: "second",
          messages: [{ promptId: "p2", from: "lane-a", text: "second", sender: { session, verification: "verified" } }],
        },
      ],
    })!;
  const joined = joinNotices(earlier, later("s-a")).threads[0]!;
  expect(joined.messages!.map((m) => m.unverified)).toEqual([true, undefined]);
  expect(joined.unverified).toBeUndefined();
  // Another chat named lane-a: none of s-a's record, session or mark fills the joined thread.
  const twin = joinNotices(earlier, later("s-b")).threads[0]!;
  expect(twin.sender).toBeUndefined();
  expect(twin.fromSession).toBeUndefined();
  expect(twin.unverified).toBeUndefined();
  expect(twin.messages!.at(-1)!.sender).toEqual({ session: "s-b" });
});

// cmux#38791 review (F2): a later record that names the same label but no session is not proof it
// is the earlier session's chat: two chats can share a label. When either side names a session,
// only the same session joins as one sender.
test("a join never lends an earlier session to a later record of the same label with none", () => {
  const earlier = thread("pr:9", "lane-a", 1, {
    sender: { label: "vm-1/lane-a", session: "s-a" },
    fromSession: "s-a",
    fromHarness: "codex",
  });
  const later = joinNotices(
    { threads: [earlier] },
    { threads: [thread("pr:9", "lane-a", 1, { sender: { label: "vm-1/lane-a" } })] },
  ).threads[0]!;
  expect(later.sender).toEqual({ label: "vm-1/lane-a" });
  expect(later.fromSession).toBeUndefined();
  expect(later.fromHarness).toBeUndefined();
  // Neither names a session: the same label is the same sender.
  const unnamed = joinNotices(
    { threads: [thread("pr:9", "lane-a", 1, { sender: { label: "vm-1/lane-a" }, fromHarness: "codex" })] },
    { threads: [thread("pr:9", "lane-a", 1, { sender: { label: "vm-1/lane-a" } })] },
  ).threads[0]!;
  expect(unnamed.fromHarness).toBe("codex");
});

test("a snapshot after the last merges as a fresh read of it would, reading only past the last closed run", () => {
  // Seeded, so a failure replays.
  let seed = 7;
  const random = () => (seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31;
  let made = 0;
  const any = (): AcpmuxRow => {
    made += 1;
    const pick = random();
    return pick < 0.4
      ? notice(`n${made}`, [thread(`pr:${made % 3}`, `lane-${made % 2}`)])
      : pick < 0.55
        ? hidden(`h${made}`)
        : reply(`r${made}`);
  };
  const fresh = (rows: AcpmuxRow[]) => {
    mergeInboxNotices([]);
    return mergeInboxNotices([...rows]);
  };
  const shape = (rows: AcpmuxRow[]) => rows.map((row) => [row.id, row.joined ?? [], row.text]);
  let rows = Array.from({ length: 40 }, any);
  mergeInboxNotices(rows);
  for (let step = 0; step < 400; step += 1) {
    const next = rows.slice();
    const pick = random();
    if (pick < 0.5) next.push(any());
    else if (pick < 0.8) next[next.length - 1 - Math.floor(random() * 3)] = any();
    else next[Math.floor(random() * next.length)] = any();
    const merged = mergeInboxNotices(next);
    const expected = shape(fresh(next));
    // The fresh read reset the last call: read the step again to carry on from it.
    mergeInboxNotices([]);
    mergeInboxNotices(rows);
    expect(shape(mergeInboxNotices(next))).toEqual(expected);
    expect(shape(merged)).toEqual(expected);
    rows = next;
  }
});
