import { describe, expect, it } from "bun:test";
import type { PendingSend } from "../../home-channels/store";
import type { HomeConversation, HomeMessage, HomeParticipant } from "../../home-channels/types";
import { GROUP_GAP_MS, SEPARATOR_GAP_MS, transcriptRows, type TranscriptData, type TranscriptRow } from "./rows";

const me: HomeParticipant = { id: "me", kind: "human", name: "Me", chief: false };
const ana: HomeParticipant = { id: "ana", kind: "human", name: "Ana", chief: false };
const sam: HomeParticipant = { id: "sam", kind: "human", name: "Sam", chief: false };
const T0 = Date.UTC(2026, 10, 6, 15, 0);

function conversation(kind: HomeConversation["kind"], people = [me, ana]): HomeConversation {
  return {
    id: "c1",
    owner: "local",
    title: "",
    kind,
    participants: people,
    lastSeq: 0,
    rev: 1,
    updatedAt: T0,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
}

let seq = 0;
function msg(author: string, at: number, text = `m${seq + 1}`, extra: Partial<HomeMessage> = {}): HomeMessage {
  seq += 1;
  return {
    id: `id${seq}`,
    conversation: "c1",
    seq,
    author,
    createdAt: at,
    retracted: false,
    parts: [{ type: "text", text, mentions: [] }],
    reactions: [],
    ...extra,
  };
}

function data(messages: HomeMessage[], extra: Partial<TranscriptData> = {}): TranscriptData {
  return { me: "me", conversation: conversation("direct"), messages, ...extra };
}

const bubbles = (rows: TranscriptRow[]) =>
  rows.filter((row): row is Extract<TranscriptRow, { kind: "bubble" }> => row.kind === "bubble");
const kinds = (rows: TranscriptRow[]) => rows.map((row) => row.kind);

describe("grouping", () => {
  it("joins one sender's messages under a minute apart, with the tail on the last", () => {
    seq = 0;
    const rows = transcriptRows(
      data([msg("ana", T0), msg("ana", T0 + 10_000), msg("ana", T0 + 20_000), msg("me", T0 + 30_000)]),
      T0,
    );
    const b = bubbles(rows);
    expect(b.map((row) => row.tail)).toEqual([false, false, true, true]);
    expect(b.map((row) => row.gap)).toEqual([0, 3, 3, 8]);
  });

  it("starts a new group a minute later, and a time label an hour later", () => {
    seq = 0;
    const rows = transcriptRows(
      data([msg("ana", T0), msg("ana", T0 + GROUP_GAP_MS), msg("ana", T0 + GROUP_GAP_MS + SEPARATOR_GAP_MS + 1)]),
      T0,
    );
    expect(kinds(rows)).toEqual(["separator", "bubble", "bubble", "separator", "bubble"]);
    const b = bubbles(rows);
    expect(b.map((row) => row.tail)).toEqual([true, true, true]);
    expect(b[1]!.gap).toBe(8);
  });

  it("names another person's run in a group chat and puts their avatar on its last bubble", () => {
    seq = 0;
    const rows = transcriptRows(
      {
        me: "me",
        conversation: conversation("group", [me, ana, sam]),
        messages: [msg("ana", T0), msg("ana", T0 + 1000), msg("sam", T0 + 2000), msg("me", T0 + 3000)],
      },
      T0,
    );
    expect(kinds(rows)).toEqual(["separator", "name", "bubble", "bubble", "name", "bubble", "bubble", "receipt"]);
    const b = bubbles(rows);
    expect(b.map((row) => row.avatar?.id)).toEqual([undefined, "ana", "sam", undefined]);
    expect(b.map((row) => row.indent)).toEqual([true, true, true, false]);
  });

  it("separates a change of thread by 32", () => {
    seq = 0;
    const root = msg("ana", T0);
    const reply = msg("ana", T0 + 1000, "r", { threadRoot: root.id });
    const other = msg("ana", T0 + 2000);
    const b = bubbles(transcriptRows(data([root, reply, other]), T0));
    expect(b.map((row) => row.gap)).toEqual([0, 2.5, 32]);
  });

  it("draws an unsent message as its line and ends the group", () => {
    seq = 0;
    const rows = transcriptRows(data([msg("ana", T0), msg("ana", T0 + 1000, "x", { retracted: true })]), T0);
    expect(kinds(rows)).toEqual(["separator", "bubble", "unsent"]);
    expect(bubbles(rows)[0]!.tail).toBe(true);
  });

  it("puts a run of attachments in one row after the text", () => {
    seq = 0;
    const file = (hash: string) =>
      ({ type: "attachment", hash, name: `${hash}.png`, mimeType: "image/png", byteCount: 10 }) as const;
    const m = msg("ana", T0, "look");
    m.parts.push(file("a"), file("b"));
    const b = bubbles(transcriptRows(data([m]), T0));
    expect(b.map((row) => row.parts.length)).toEqual([1, 2]);
    expect(b.map((row) => row.tail)).toEqual([false, true]);
  });
});

describe("receipts", () => {
  it("shows Read under my newest read message and Delivered under a newer one", () => {
    seq = 0;
    const messages = [msg("me", T0), msg("me", T0 + 1000), msg("ana", T0 + 2000), msg("me", T0 + 3000)];
    const rows = transcriptRows(data(messages, { readCursors: { ana: { seq: 2, at: T0 + 5000 } } }), T0);
    const receipts = rows.filter((row) => row.kind === "receipt");
    expect(receipts.map((row) => [row.key, row.kind === "receipt" && row.receipt])).toEqual([
      ["receipt:id2", "read"],
      ["receipt:id4", "delivered"],
    ]);
    expect(receipts[0]!.kind === "receipt" && receipts[0]!.at).toBe(T0 + 5000);
  });

  it("shows only Read when my newest message is read, and none for my own cursor", () => {
    seq = 0;
    const messages = [msg("me", T0), msg("me", T0 + 1000)];
    const rows = transcriptRows(
      data(messages, { readCursors: { me: { seq: 2, at: T0 }, ana: { seq: 2, at: T0 + 9 } } }),
      T0,
    );
    expect(rows.filter((row) => row.kind === "receipt").map((row) => row.key)).toEqual(["receipt:id2"]);
    const own = transcriptRows(data(messages, { readCursors: { me: { seq: 2, at: T0 } } }), T0);
    expect(own.filter((row) => row.kind === "receipt").map((row) => row.kind === "receipt" && row.receipt)).toEqual([
      "delivered",
    ]);
  });

  it("marks a pending send sending and a failed one Not Delivered, with no receipt", () => {
    seq = 0;
    const pending: PendingSend[] = [
      { key: "k1", conversation: "c1", text: "one", createdAt: T0 + 1000, failed: false },
      { key: "k2", conversation: "c1", text: "two", createdAt: T0 + 2000, failed: true },
    ];
    const rows = transcriptRows(data([msg("me", T0)], { pending }), T0);
    const b = bubbles(rows);
    expect(b.map((row) => row.delivery?.state)).toEqual(["delivered", "sending", "failed"]);
    expect(rows.filter((row) => row.kind === "label").map((row) => row.key)).toEqual(["failed:pending:k2"]);
    expect(rows.filter((row) => row.kind === "receipt").map((row) => row.key)).toEqual(["receipt:id1"]);
  });
});

describe("typing and the running reply", () => {
  it("shows one typing bubble for others, never for me", () => {
    seq = 0;
    const rows = transcriptRows(data([msg("me", T0)], { typing: ["me", "ana"] }), T0);
    const typing = rows.at(-1)!;
    expect(typing.kind).toBe("typing");
    expect(typing.kind === "typing" && typing.participants).toEqual(["ana"]);
    expect(transcriptRows(data([msg("ana", T0)], { typing: ["me"] }), T0).at(-1)!.kind).toBe("bubble");
  });

  it("draws a running reply as its author's bubble instead of their typing dots", () => {
    seq = 0;
    const rows = transcriptRows(
      data([msg("me", T0)], { typing: ["ana"], draft: { participant: "ana", turn: "t1", text: "Working on it" } }),
      T0 + 1000,
    );
    const last = rows.at(-1)!;
    expect(last.kind).toBe("bubble");
    expect(last.kind === "bubble" && last.streaming).toBe(true);
  });

  it("puts a load-older row on top while older messages exist", () => {
    seq = 0;
    expect(transcriptRows(data([msg("ana", T0)], { hasOlder: true, loadingOlder: true }), T0)[0]).toMatchObject({
      kind: "older",
      loading: true,
    });
  });
});

describe("cost", () => {
  it("derives 10,000 messages in one pass", () => {
    seq = 0;
    const many = Array.from({ length: 10_000 }, (_, index) => msg(index % 3 ? "ana" : "me", T0 + index * 20_000));
    const started = performance.now();
    const rows = transcriptRows(data(many, { readCursors: { ana: { seq: 9_990, at: T0 } } }), T0);
    const elapsed = performance.now() - started;
    expect(bubbles(rows)).toHaveLength(10_000);
    // Generous for a loaded CI host; on a laptop this is a few milliseconds.
    expect(elapsed).toBeLessThan(500);
  });
});

describe("row cache", () => {
  it("keeps the rows of messages a send does not touch", async () => {
    const { RowCache } = await import("./rows");
    seq = 0;
    const cache = new RowCache();
    const messages = Array.from({ length: 50 }, (_, index) => msg(index % 2 ? "ana" : "me", T0 + index * 120_000));
    const before = transcriptRows(data(messages), T0, cache);
    const after = transcriptRows(data([...messages, msg("me", T0 + 51 * 120_000)]), T0, cache);
    // Every row of the first 48 messages is the same object; only the old last messages and the new one change.
    const kept = after.filter((row) => before.includes(row)).length;
    expect(kept).toBeGreaterThanOrEqual(before.length - 4);
    // The cache never changes what the rows are.
    const later = [...messages, msg("me", T0 + 52 * 120_000)];
    expect(transcriptRows(data(later), T0, cache)).toEqual(transcriptRows(data(later), T0));
  });
});
