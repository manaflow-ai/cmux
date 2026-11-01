// The one group of messages that wait for the agent (pendingMessages.ts): every waiting message in
// it, each once (Leo, 2026-10-29: "nx-sidebar #27128 own red fixed and pushed exact d60a3ddc…"
// shown twice), one that arrives later joins the same group, and messages with different images
// are never folded into one.
import { expect, test } from "bun:test";
import { LANE_NOTICE_BATCH, PENDING_MESSAGES, QUEUED_MESSAGE, type AcpmuxRow } from "../model";
import {
  bySender,
  dedupeMessages,
  PENDING_MESSAGES_ROW_ID,
  pendingMessagesRow,
  searchablePendingRows,
} from "./pendingMessages";
import { batchLaneNotices, flattenInboxRows, projectInboxRows } from "./laneNoticeBatches";

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

test("only the same delivery id is deduplicated, never matching words", () => {
  const red = "#27128 own red fixed and pushed exact d60a3ddc";
  const rows = [
    queued("p1", "nx-sidebar", red),
    queued("p2", "nx-sidebar", `  ${red} `), // another delivery, even with matching words
    queued("p1", "nx-sidebar", "same id, other words"),
    queued("p3", "dep-fleet", red), // another sender's same words are theirs
  ];
  expect(dedupeMessages(rows).map((row) => row.queuedMessage?.promptId)).toEqual(["p1", "p2", "p3"]);
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
  expect(group.pendingMessages?.rows.map((row) => row.id)).toEqual([
    "steer-s1",
    "queued-message-q1",
    "queued-message-q2",
  ]);
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

test("Find searches the same deduplicated waiting rows that the group draws", () => {
  const duplicate = queued("q1", "lane", "same delivery");
  const retry = { ...duplicate, id: "retry" };
  const other = queued("q3", "lane", "different");
  const rows = searchablePendingRows([duplicate, retry], [other]);
  expect(rows).toEqual([duplicate, other]);
  expect(pendingMessagesRow([duplicate, retry], [other])?.pendingMessages?.rows).toEqual([duplicate, other]);
});

// Review at 1fbcdcc8: Find never saw a queued message's text, so a search could not reach one in
// the collapsed group. A queued message is a searched row, and its match lands on the group, which
// draws it.
test("Find counts a queued message's words and lands on the group that draws it", async () => {
  const { findMatches, findRowIndex } = await import("./chatFind");
  const waiting = queued("q9", "docs-lane", "Docs are rebuilt for the zebra release.");
  const group = pendingMessagesRow([], [waiting])!;
  const matches = findMatches([waiting], "zebra");
  expect(matches.map((match) => match.rowId)).toEqual([waiting.id]);
  const transcript = [queued("x", "a", "unrelated"), group].slice(1);
  expect(findRowIndex(transcript, waiting.id)).toBe(0);
});

test("a reloaded queue keeps distinct messages whose first 200 characters match", async () => {
  const { mergeQueue } = await import("../direct");
  const { queuedMessageRows } = await import("./queuedMessages");
  const prefix = "Shared status update: ".padEnd(200, "x");
  const fullMessages = [`${prefix} keep this change`, `${prefix} revert this change`];
  const listed = fullMessages.map((message, index) => ({
    promptId: `reloaded-${index}`,
    preview: message.slice(0, 200),
    fromAgent: "same-lane",
  }));
  const rows = queuedMessageRows(mergeQueue([], listed));
  expect(rows[0]?.text).toBe(rows[1]?.text);
  expect(pendingMessagesRow([], rows)?.pendingMessages?.rows).toEqual(rows);
  expect(searchablePendingRows([], rows)).toEqual(rows);
  // The waiting steer and the queue can name the same delivery using different row ids.
  const deliveredTwice = steer("reloaded-0", "same-lane", fullMessages[0]!);
  expect(pendingMessagesRow([deliveredTwice], rows)?.pendingMessages?.rows).toEqual([deliveredTwice, rows[1]!]);
});

test("messages without a prompt id remain distinct unless their row id matches", () => {
  const one = queued("unused", "lane", "matching preview", { queuedMessage: undefined, id: "row-one" });
  const two = { ...one, id: "row-two" };
  expect(dedupeMessages([one, two, { ...one }])).toEqual([one, two]);
});

test("inbox notices become flat sender rows and do not repeat a delivered message", () => {
  const text = [
    "New messages from other agents in 2 threads.",
    "- 1 new in #29626 from stranded-composer-land: merged #29626 (thread from:strand/pr:29626)",
    "- 1 new in #29627 from origin-assist: ready (thread from:origin/pr:29627)",
  ].join("\n");
  const notice: AcpmuxRow = {
    id: "inbox-notice",
    version: 1,
    at: 1,
    kind: QUEUED_MESSAGE,
    text,
    incoming: {
      kind: "message",
      message: { name: "inbox", text, raw: `[inbox] ${text}` },
    },
  };
  const delivered: AcpmuxRow = {
    id: "delivered",
    version: 1,
    at: 2,
    kind: QUEUED_MESSAGE,
    text: "merged #29626",
    incoming: {
      kind: "message",
      message: { name: "stranded-composer-land", text: "merged #29626", raw: "merged #29626" },
    },
  };
  const rows = flattenInboxRows([notice, delivered]);
  expect(rows.map((row) => row.incoming?.kind === "message" && row.incoming.message.name)).toEqual([
    "origin-assist",
    "stranded-composer-land",
  ]);
  expect(rows.map((row) => row.text)).toEqual(["ready", "merged #29626"]);

  const group = pendingMessagesRow([], [notice, delivered])!;
  expect(group.pendingMessages?.flat).toBe(true);
  expect(group.pendingMessages?.displayRows?.map((row) => row.kind)).toEqual(["user", QUEUED_MESSAGE]);
  expect(
    group.pendingMessages?.displayRows?.map((row) => row.incoming?.kind === "message" && row.incoming.message.text),
  ).toEqual(["ready", "merged #29626"]);
  expect(group.text).not.toContain("New messages from other agents");
  expect(group.text).not.toContain("(thread from:");
});

test("structured inbox notices join the flat waiting run without nesting their card", () => {
  const notice: AcpmuxRow = {
    id: "structured-inbox",
    version: 1,
    at: 3,
    kind: "user",
    steer: "waiting",
    incoming: {
      kind: "inbox",
      notice: {
        threads: [
          {
            threadId: "from:origin/pr:1",
            label: "#1",
            from: ["origin-assist"],
            count: 1,
            preview: "checks are green",
            blocker: false,
            promptIds: ["p1"],
            messages: [{ promptId: "p1", from: "origin-assist", text: "checks are green" }],
          },
        ],
      },
    },
  };
  const group = pendingMessagesRow([notice], [])!;
  expect(group.pendingMessages?.flat).toBe(true);
  expect(
    group.pendingMessages?.displayRows?.map((row) => row.incoming?.kind === "message" && row.incoming.message.name),
  ).toEqual(["origin-assist"]);
  expect(group.pendingMessages?.displayRows?.some((row) => row.incoming?.kind === "inbox")).toBe(false);
});

test("inbox deliveries keep distinct full messages and collapse a repeated notice", () => {
  const text = [
    "New messages from other agents in 13 threads.",
    ...Array.from(
      { length: 13 },
      (_, index) =>
        `- 1 new in #${30000 + index} from lane-${index}: delivery ${index} (thread from:lane-${index}/pr:${30000 + index})`,
    ),
  ].join("\n");
  const notice = (id: string): AcpmuxRow => ({
    id,
    version: 1,
    at: 10,
    kind: QUEUED_MESSAGE,
    text,
    incoming: { kind: "message", message: { name: "inbox", text, raw: `[inbox] ${text}` } },
  });
  const group = pendingMessagesRow([], [notice("inbox-a"), notice("inbox-b")])!;
  const rows = group.pendingMessages?.displayRows ?? [];
  expect(rows).toHaveLength(13);
  expect(rows.every((row) => row.incoming?.kind === "message")).toBe(true);
  expect(rows.some((row) => row.text?.includes("New messages from other agents"))).toBe(false);
  expect(rows.some((row) => row.text?.includes("(thread from:"))).toBe(false);
  expect(group.pendingMessages?.flat).toBe(true);
});

test("a waiting wrapper prompt id does not deduplicate its individual deliveries", () => {
  const text = [
    "New messages from other agents in 13 threads.",
    ...Array.from(
      { length: 13 },
      (_, index) =>
        `- 1 new in #${30100 + index} from lane-${index}: delivery ${index} (thread from:lane-${index}/pr:${30100 + index})`,
    ),
  ].join("\n");
  const wrapper: AcpmuxRow = {
    id: "waiting-wrapper",
    version: 1,
    at: 1,
    kind: "user",
    steer: "waiting",
    steerPromptId: "wrapper-prompt",
    queuedMessage: { promptId: "wrapper-prompt" },
    text,
    incoming: { kind: "message", message: { name: "inbox", text, raw: `[inbox] ${text}` } },
  };
  const group = pendingMessagesRow([wrapper], [])!;
  expect(group.pendingMessages?.displayRows).toHaveLength(13);
  const display = group.pendingMessages?.displayRows ?? [];
  expect(display.every((row) => row.queuedMessage === undefined)).toBe(true);
  expect(display.filter((row) => row.inboxQueue?.promptId === "wrapper-prompt")).toHaveLength(1);
});

test("a deduped first inbox delivery keeps the queue menu on the retained delivery", () => {
  const duplicate = queued("direct", "lane-a", "already delivered");
  const wrapperText = [
    "New messages from other agents in 2 threads.",
    "- 1 new in #1 from lane-a: already delivered (thread from:lane-a/pr:1)",
    "- 1 new in #2 from lane-b: keep this (thread from:lane-b/pr:2)",
  ].join("\n");
  const wrapper = queued("wrapper", "inbox", wrapperText, {
    incoming: { kind: "message", message: { name: "inbox", text: wrapperText, raw: wrapperText } },
  });
  const display = pendingMessagesRow([], [duplicate, wrapper])?.pendingMessages?.displayRows ?? [];
  expect(display.map((row) => row.text)).toEqual(["already delivered", "keep this"]);
  expect(display.filter((row) => row.inboxQueue?.promptId === "wrapper")).toHaveLength(1);
});

test("turn shaping keeps all expanded waiting deliveries in the pending group", async () => {
  const text = [
    "New messages from other agents in 13 threads.",
    ...Array.from(
      { length: 13 },
      (_, index) =>
        `- 1 new in #${30200 + index} from lane-${index}: delivery ${index} (thread from:lane-${index}/pr:${30200 + index})`,
    ),
  ].join("\n");
  const wrapper: AcpmuxRow = {
    id: "turn-wrapper",
    version: 1,
    at: 1,
    kind: "user",
    steer: "waiting",
    steerPromptId: "turn-wrapper-prompt",
    text,
    incoming: { kind: "message", message: { name: "inbox", text, raw: `[inbox] ${text}` } },
  };
  const { turnViewFrom } = await import("./turns");
  const view = turnViewFrom([wrapper], new Set());
  expect(view.rows.filter((row) => row.kind !== "date")).toHaveLength(0);
  expect(view.pending).toHaveLength(1);
  expect(pendingMessagesRow(view.pending, [])?.pendingMessages?.displayRows).toHaveLength(13);
});

test("turn shaping removes a read inbox summary when its direct delivery is present", async () => {
  const text = [
    "New messages from other agents in 1 thread.",
    "- 1 new in #30213 from lane-a: merged #30213 (thread from:lane-a/pr:30213)",
  ].join("\n");
  const direct: AcpmuxRow = {
    id: "direct-delivery",
    version: 1,
    at: 1,
    kind: "user",
    text: "merged #30213",
    incoming: { kind: "message", message: { name: "lane-a", text: "merged #30213", raw: "merged #30213" } },
  };
  const notice: AcpmuxRow = {
    id: "read-summary",
    version: 1,
    at: 2,
    kind: "user",
    text,
    incoming: { kind: "message", message: { name: "inbox", text, raw: `[inbox] ${text}` } },
  };
  const { turnViewFrom } = await import("./turns");
  const view = turnViewFrom([direct, notice], new Set());
  const sourceRows = view.rows.filter((row) => row.kind !== "date");
  const display = flattenInboxRows(sourceRows);
  expect(sourceRows).toHaveLength(2);
  expect(display).toHaveLength(1);
  expect(display[0]?.incoming).toMatchObject({ kind: "message", message: { name: "lane-a", text: "merged #30213" } });
});

test("a folded inbox batch projects to flat delivery rows after turn shaping", () => {
  const make = (id: string, sender: string): AcpmuxRow => {
    const text = `New messages from other agents in 1 thread.\n- 1 new in #${id} from ${sender}: merged #${id} (thread from:${sender}/pr:${id})`;
    return {
      id,
      version: 1,
      at: 1,
      kind: "user",
      text,
      incoming: { kind: "message", message: { name: "inbox", text, raw: `[inbox] ${text}` } },
    };
  };
  const source = [make("30214", "lane-a"), make("30215", "lane-b")];
  const batch = batchLaneNotices(source);
  expect(batch).toHaveLength(1);
  const display = flattenInboxRows(batch);
  expect(display).toHaveLength(1);
  expect(display[0]?.inboxDeliveryBatch).toBe(true);
  expect(display[0]?.laneNoticeBatch?.rows).toHaveLength(2);
  expect(display[0]?.laneNoticeBatch?.rows.every((row) => row.incoming?.kind === "message")).toBe(true);
  expect(
    display[0]?.laneNoticeBatch?.rows.map((row) => row.incoming?.kind === "message" && row.incoming.message.name),
  ).toEqual(["lane-a", "lane-b"]);
});

test("one projection context deduplicates across a batch, standalone notice, and direct delivery", () => {
  const make = (id: string, sender: string, text: string): AcpmuxRow => ({
    id,
    version: 1,
    at: 1,
    kind: "user",
    text: `New messages from other agents in 1 thread.\n- 1 new in #${id} from ${sender}: ${text} (thread from:${sender}/pr:${id})`,
    incoming: {
      kind: "message",
      message: {
        name: "inbox",
        text: `New messages from other agents in 1 thread.\n- 1 new in #${id} from ${sender}: ${text} (thread from:${sender}/pr:${id})`,
        raw: "",
      },
    },
  });
  const first = make("30220", "lane-a", "merged #30220");
  const second = make("30221", "lane-b", "merged #30221");
  const standalone = make("30222", "lane-c", "merged #30222");
  const direct: AcpmuxRow = {
    id: "direct-30220",
    version: 1,
    at: 2,
    kind: "user",
    text: "merged #30220",
    incoming: { kind: "message", message: { name: "lane-a", text: "merged #30220", raw: "merged #30220" } },
  };
  const batch = batchLaneNotices([first, second]);
  const projected = projectInboxRows([...batch, standalone, direct]);
  expect(projected).toHaveLength(3);
  expect(projected[0]?.laneNoticeBatch?.rows).toHaveLength(1);
  expect(
    projected[0]?.laneNoticeBatch?.rows[0]?.incoming?.kind === "message" &&
      projected[0].laneNoticeBatch.rows[0].incoming.message.name,
  ).toBe("lane-b");
  expect(projected[1]?.incoming?.kind === "message" && projected[1].incoming.message.name).toBe("lane-c");
  expect(projected[2]).toBe(direct);
  expect(projected.some((row) => row.text?.includes("New messages from other agents"))).toBe(false);
});

test("projection caches are isolated by source row identity across chats", () => {
  const make = (id: string): AcpmuxRow => ({
    id: "same-row-id",
    version: 1,
    at: 1,
    kind: "user",
    text: `New messages from other agents in 1 thread.\n- 1 new in #${id} from lane: delivery ${id} (thread from:lane/pr:${id})`,
    incoming: {
      kind: "message",
      message: {
        name: "inbox",
        text: `New messages from other agents in 1 thread.\n- 1 new in #${id} from lane: delivery ${id} (thread from:lane/pr:${id})`,
        raw: "",
      },
    },
  });
  const first = projectInboxRows([make("30230")]);
  const second = projectInboxRows([make("30231")]);
  expect(first[0]).not.toBe(second[0]);
  expect(first[0]?.text).toContain("30230");
  expect(second[0]?.text).toContain("30231");
});

test("raw inbox deliveries with the same first line keep distinct full bodies", () => {
  const text = [
    "New messages from other agents in 1 thread.",
    "- 2 new in #30020 from lane-a (thread from:lane-a/pr:30020):",
    "> lane-a: same first line; keep this detail",
    "> lane-a: same first line; keep the other detail",
  ].join("\n");
  const row: AcpmuxRow = {
    id: "inbox-same-preview",
    version: 1,
    at: 1,
    kind: QUEUED_MESSAGE,
    text,
    incoming: { kind: "message", message: { name: "inbox", text, raw: `[inbox] ${text}` } },
  };
  expect(flattenInboxRows([row]).map((delivery) => delivery.text)).toEqual([
    "same first line; keep this detail",
    "same first line; keep the other detail",
  ]);
});

test("a structured inbox thread without a preview still gets a sender row", () => {
  const row: AcpmuxRow = {
    id: "inbox-no-preview",
    version: 1,
    at: 1,
    kind: "user",
    steer: "waiting",
    incoming: {
      kind: "inbox",
      notice: {
        threads: [
          {
            threadId: "from:lane-a/pr:30021",
            label: "#30021",
            from: ["lane-a"],
            count: 1,
            preview: "",
            blocker: false,
            promptIds: ["p-no-preview"],
          },
        ],
      },
    },
  };
  const display = pendingMessagesRow([row], [])?.pendingMessages?.displayRows ?? [];
  expect(display).toHaveLength(1);
  expect(display[0]?.incoming).toMatchObject({ kind: "message", message: { name: "lane-a", text: "" } });
});

test("a delivered inbox notice expands to clean rows outside the waiting group", async () => {
  const text = [
    "New messages from other agents in 1 thread. They need no turn of your own: read with inbox_read.",
    "- 1 new in #30022 from lane-a: merged #30022 (thread from:lane-a/pr:30022)",
  ].join("\n");
  const row: AcpmuxRow = {
    id: "delivered-inbox",
    version: 1,
    at: 1,
    kind: "user",
    text,
    incoming: { kind: "message", message: { name: "inbox", text, raw: `[inbox] ${text}` } },
  };
  const { turnViewFrom } = await import("./turns");
  const view = turnViewFrom([row], new Set());
  const sourceRows = view.rows.filter((entry) => entry.kind !== "date");
  expect(sourceRows).toEqual([row]);
  const rendered = flattenInboxRows(sourceRows);
  expect(rendered).toHaveLength(1);
  expect(rendered[0]?.incoming).toMatchObject({ kind: "message", message: { name: "lane-a", text: "merged #30022" } });
  expect(rendered[0]?.text).not.toContain("inbox_read");
  expect(rendered[0]?.text).not.toContain("(thread from:");
});

test("a delivered many-thread notice has one flat fold, independent of the waiting projection", () => {
  const text = [
    "New messages from other agents in 13 threads.",
    ...Array.from(
      { length: 13 },
      (_, i) => `- 1 new in #${31000 + i} from lane-${i}: done #${31000 + i} (thread from:lane-${i}/pr:${31000 + i})`,
    ),
  ].join("\n");
  const notice: AcpmuxRow = {
    id: "delivered-many",
    version: 1,
    at: 1,
    kind: "user",
    text,
    incoming: { kind: "message", message: { name: "inbox", text, raw: text } },
  };
  const reply: AcpmuxRow = { id: "reply", version: 1, at: 2, kind: "assistant", text: "Working" };
  const source = [notice, reply];
  const flat = flattenInboxRows(source);
  expect(flat).toHaveLength(14);
  const delivered = projectInboxRows(source);
  expect(delivered).toHaveLength(2);
  expect(delivered[0]?.kind).toBe(LANE_NOTICE_BATCH);
  expect(delivered[0]?.laneNoticeBatch?.rows).toHaveLength(13);
  expect(
    delivered[0]?.laneNoticeBatch?.rows.every((row) => !row.laneNoticeBatch && row.incoming?.kind === "message"),
  ).toBe(true);
  expect(delivered[0]?.text).not.toContain("New messages from other agents");
  expect(delivered[0]?.text).not.toContain("(thread ");
  expect(delivered[1]).toBe(reply);
  expect(flattenInboxRows(source)).toBe(flat);
  expect(projectInboxRows(source)).toBe(delivered);
  expect(source[0]).toBe(notice);

  // The fold's one output slot must also be used by incremental streaming offsets.
  const nextReply = { ...reply, version: 2, text: "Working on it" };
  const nextSource = [notice, nextReply];
  const streamed = projectInboxRows(nextSource, source, 1);
  expect(streamed).toEqual([delivered[0]!, nextReply]);
  expect(streamed[0]).toBe(delivered[0]);
  // The reverse order must not reuse the folded array for Find or the waiting strip either.
  expect(flattenInboxRows(nextSource)).toHaveLength(14);
});
