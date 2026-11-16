// Every turn's final reply is drawn from the row store, with folds closed and open (6d PR2, the
// plan's last check). The recorded corpus: each reply the log says a turn ended with
// (`turnReplies`) is drawn by turnView over the adapter's rows. A generated 1,000-turn chat, read
// the way a person scrolls it (the window at the end, then a page before at a time, past the
// store's cap): each reply row the store holds is drawn, and every turn's reply is held once.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { chatRowsFeed } from "../../../../test/support/chatRowsFeed";
import { turnReplies, undrawnReplies } from "../conversation/repliesDrawn";
import { turnView } from "../conversation/turns";
import type { Folds } from "../conversation/viewFolds";
import type { EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";
import { adaptChat } from "./adapter";
import { ChatRowsHost, type ChatRowsPost } from "./host";
import { ChatRowStore, STORE_MAX_ROWS, type ChatRowsSnapshot } from "./store";
import type { ChatRow } from "./wire";

const FIXTURES = `${import.meta.dir}/../../../../../cmux-tui/crates/acpmux-book/src/translate/fixtures`;
const CORPUS = ["seed-turn", "r1-reply-1", "r1-reply-2", "parity"];
const SESSION = "s1";
const SID = "rows.1";

/// Every fold closed, as a chat opens, and every fold open, as a person who opens each one.
const FOLDS: readonly [string, Folds][] = [
  ["closed", new Set<string>()],
  ["open", { has: () => true, size: 1 }],
];

async function opened() {
  const store = new ChatRowStore();
  const post: ChatRowsPost = async (method, params) => (method === "chat.rows.open" ? { sid: params.sid } : {});
  const host = new ChatRowsHost(post, store, () => SID);
  await host.open("chat-1");
  const feed = chatRowsFeed(host, post);
  return { store, host, send: (change: unknown) => feed([JSON.stringify(change)]) };
}

/// The view's rows over a snapshot, as the pane draws them.
function drawn(snapshot: ChatRowsSnapshot, expanded: Folds): AcpmuxRow[] {
  const rows = adaptChat(snapshot, { sessionId: SESSION }).rows;
  const now = Math.max(0, ...rows.map((row) => row.at)) + 60_000;
  return turnView(rows, expanded, { now });
}

/// The recorded log's store snapshot: the window, then each settled turn's fold as the Rust half
/// paged it (as parity.test.ts reads it).
async function recorded(name: string): Promise<ChatRowsSnapshot> {
  const { store, host, send } = await opened();
  const folds: number[] = [];
  for (const line of readFileSync(`${import.meta.dir}/parity/${name}.changes.jsonl`, "utf8").split("\n")) {
    if (!line.trim()) continue;
    const change = JSON.parse(JSON.parse(line) as string) as { kind: string; window?: { rows: ChatRow[] } };
    if (change.kind === "chatPage") expect(host.page(SID, "after", { from: folds[0], fold: folds.shift() })).toBe(true);
    send(change);
    if (change.kind === "chatWindow")
      for (const row of change.window!.rows) if (row.kind === "group" && !row.open) folds.push(row.id);
  }
  return store.snapshot(SID)!;
}

test("the corpus: each turn's final reply in the log is drawn from the store, folds closed and open", async () => {
  let replies = 0;
  for (const name of CORPUS) {
    const events: EventRecord[] = readFileSync(`${FIXTURES}/${name}.ndjson`, "utf8")
      .split("\n")
      .filter((line) => line.trim())
      .map((line) => ({ ...JSON.parse(line), sessionId: SESSION }));
    const said = turnReplies(events);
    replies += said.length;
    const snapshot = await recorded(name);
    for (const [folds, expanded] of FOLDS) {
      // A reply whose chunks name no message id is one segment a chunk to `turnReplies`, so its
      // "final reply" is the last chunk: drawn when it ends a reply row the view shows whole.
      const view = drawn(snapshot, expanded);
      const ends = view.flatMap((row) =>
        row.kind === "assistant" && !row.foldedReply && typeof row.text === "string" ? [row.text.trim()] : [],
      );
      const undrawn = undrawnReplies(said, view).filter(
        (reply) => !ends.some((text) => text.endsWith(reply.text.trim())),
      );
      expect({ name, folds, undrawn: undrawn.map((reply) => reply.text) }).toEqual({ name, folds, undrawn: [] });
    }
  }
  expect(replies).toBeGreaterThan(0);
});

const TURNS = 1_000;
const AT = 1_794_480_000;
/// Turn `t`'s rows: its prompt, its group row, its final reply and its end, in id order.
function turnRows(t: number): ChatRow[] {
  const prompt = t * 4 + 1;
  const [group, reply, end] = [prompt + 1, prompt + 2, prompt + 3];
  const row = (id: number, extra: Partial<ChatRow> & Pick<ChatRow, "body">): ChatRow => ({
    id,
    rev: 1,
    kind: "text",
    turn: prompt,
    at: AT + id,
    open: false,
    est: 1,
    ...extra,
  });
  return [
    row(prompt, { kind: "user", body: { content: `prompt ${t}`, promptId: `p${t}`, state: "sent", steer: false } }),
    row(group, {
      kind: "group",
      body: {
        calls: 0,
        head: `prompt ${t}`,
        last: end,
        ms: 1000,
        out: [[reply, reply]],
        prompt,
        promptId: `p${t}`,
        status: "completed",
      },
    }),
    row(reply, { group, body: { messageId: `m${t}`, text: `reply ${t}` } }),
    row(end, { kind: "notice", group, body: { notice: "turn_result", seq: end, status: "completed" } }),
  ];
}
const rowsOf = (from: number, to: number) =>
  Array.from({ length: to - from }, (_, index) => turnRows(from + index)).flat();

test("a 1,000-turn chat read a page at a time: every reply row held is drawn, folds closed and open", async () => {
  const { store, host, send } = await opened();
  const PAGE = 100;
  let first = TURNS - 3 * PAGE;
  send({
    kind: "chatWindow",
    replaces: true,
    window: {
      sid: SID,
      cursor: TURNS * 4,
      edition: 1,
      rows: rowsOf(first, TURNS),
      hasBefore: true,
      hasAfter: false,
      open: [],
      queue: { entries: [], count: 0 },
    },
  });
  const held = new Set<number>();
  const undrawn: string[] = [];
  for (;;) {
    const snapshot = store.snapshot(SID)!;
    expect(snapshot.rows.length).toBeLessThanOrEqual(STORE_MAX_ROWS);
    const replies = snapshot.rows.flatMap((entry) =>
      entry.row?.kind === "text" ? [String((entry.row.body as { text: string }).text)] : [],
    );
    for (const [folds, expanded] of FOLDS) {
      const shown = new Set(
        drawn(snapshot, expanded).flatMap((row) => (row.kind === "assistant" && !row.foldedReply ? [row.text] : [])),
      );
      for (const reply of replies) if (!shown.has(reply)) undrawn.push(`${reply} (folds ${folds}, from turn ${first})`);
    }
    for (const reply of replies) held.add(Number(reply.slice("reply ".length)));
    if (first === 0) break;
    const from = Math.max(0, first - PAGE);
    expect(host.page(SID, "before")).toBe(true);
    send({
      kind: "chatPage",
      page: { sid: SID, edition: 1, rows: rowsOf(from, first), hasBefore: from > 0, hasAfter: true },
    });
    first = from;
  }
  expect(undrawn.slice(0, 5)).toEqual([]);
  expect(held.size).toBe(TURNS);
});
