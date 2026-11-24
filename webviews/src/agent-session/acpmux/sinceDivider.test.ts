// "New since you looked" sorts right after the record the person had seen (acpmux `seenSeq`), between
// that event's rows and the next one's, wherever the rows around it came from (OrderedRows.placeAfter, setAt).
import { expect, test } from "bun:test";
import { OrderedRows } from "./direct";
import {
  LANE_NOTICE_BATCH,
  MESSAGE_RUN,
  PENDING_MESSAGES,
  QUEUED_MESSAGE,
  SINCE_DIVIDER,
  layoutConversation,
  type AcpmuxRow,
} from "./model";
import { sessionEntry } from "./sessionList";
import { SINCE_NEWS_REACH, isNews, sinceNews } from "./conversation/sinceNews";
import { SUBAGENT_STARTED } from "./subagents/subagentRows";

const reply = (seq: number): AcpmuxRow => ({
  id: `row-${seq}`,
  version: 1,
  at: seq,
  kind: "assistant",
  text: `r${seq}`,
});
const divider = (seq: number, turns: number): AcpmuxRow => ({
  id: SINCE_DIVIDER,
  version: 1,
  at: 0,
  kind: SINCE_DIVIDER,
  since: { key: `s:${seq}`, seq, turns },
});

function eventRows(seqs: number[]): OrderedRows {
  const rows = new OrderedRows();
  for (const seq of seqs) {
    rows.current = seq;
    rows.set(`row-${seq}`, reply(seq));
    rows.current = undefined;
  }
  return rows;
}

test("the divider goes after the seen record and before the first new one", () => {
  const rows = eventRows([1, 2, 5, 8]);
  rows.sorted();
  rows.setAt(rows.placeAfter(2), divider(2, 2));
  expect(rows.sorted().map((row) => row.id)).toEqual(["row-1", "row-2", SINCE_DIVIDER, "row-5", "row-8"]);
  // A record reduced afterwards, older or newer, sorts by its seq around it.
  rows.current = 9;
  rows.set("row-9", reply(9));
  rows.current = 2;
  rows.set("row-2b", { ...reply(2), id: "row-2b" });
  rows.current = undefined;
  expect(rows.sorted().map((row) => row.id)).toEqual([
    "row-1",
    "row-2",
    "row-2b",
    SINCE_DIVIDER,
    "row-5",
    "row-8",
    "row-9",
  ]);
});

test("a later return moves the one divider, and a reset's replay keeps it in place", () => {
  const rows = eventRows([1, 2, 5, 8]);
  rows.setAt(rows.placeAfter(2), divider(2, 2));
  rows.setAt(rows.placeAfter(5), divider(5, 1));
  const ids = rows.sorted().map((row) => row.id);
  expect(ids.filter((id) => id === SINCE_DIVIDER)).toHaveLength(1);
  expect(ids).toEqual(["row-1", "row-2", "row-5", SINCE_DIVIDER, "row-8"]);
  // A rebuild drops it with the rows; placed again, it sorts among the replayed events.
  rows.clear();
  rows.setAt(rows.placeAfter(5), divider(5, 1));
  for (const seq of [1, 2, 5, 8]) {
    rows.current = seq;
    rows.set(`row-${seq}`, reply(seq));
  }
  rows.current = undefined;
  expect(rows.sorted().map((row) => row.id)).toEqual(["row-1", "row-2", "row-5", SINCE_DIVIDER, "row-8"]);
});

test("the session list reads unreadTurns and seenSeq, and leaves out what is not a count", () => {
  const entry = sessionEntry({ sessionId: "s-1", unread: true, unreadTurns: 3, seenSeq: 41 });
  expect(entry.unreadTurns).toBe(3);
  expect(entry.seenSeq).toBe(41);
  const older = sessionEntry({ sessionId: "s-2", unreadTurns: "3", seenSeq: null });
  expect(older.unreadTurns).toBeUndefined();
  expect(older.seenSeq).toBeUndefined();
});

test("new content at the same place reaches the kept order: a recap that arrives, then its dismissal", () => {
  const rows = eventRows([1, 2, 5]);
  rows.setAt(rows.placeAfter(2), divider(2, 1));
  expect(rows.sorted().find((row) => row.id === SINCE_DIVIDER)?.since?.recap).toBeUndefined();
  const recap = { key: "s-1:9", text: "Where it stands." };
  rows.setAt(rows.placeAfter(2), { ...divider(2, 1), version: 2, since: { key: "s:2", seq: 2, turns: 1, recap } });
  expect(rows.sorted().find((row) => row.id === SINCE_DIVIDER)?.since?.recap).toEqual(recap);
  rows.setAt(rows.placeAfter(2), { ...divider(2, 1), version: 3 });
  expect(rows.sorted().find((row) => row.id === SINCE_DIVIDER)?.since?.recap).toBeUndefined();
  expect(rows.sorted().map((row) => row.id)).toEqual(["row-1", "row-2", SINCE_DIVIDER, "row-5"]);
});

test("a reply the person left mid-stream goes under the divider, so the rest of it reads as new", () => {
  const rows = eventRows([1, 2]);
  // The reply starts at 3, the person leaves after 4, it streams on at 6.
  for (const seq of [3, 4, 6]) {
    rows.current = seq;
    rows.set("reply", { ...reply(3), id: "reply", text: `through ${seq}` });
  }
  rows.current = 7;
  rows.set("row-7", reply(7));
  rows.current = undefined;
  rows.setAt(rows.placeAfter(4), divider(4, 1));
  expect(rows.sorted().map((row) => row.id)).toEqual(["row-1", "row-2", SINCE_DIVIDER, "reply", "row-7"]);
  // A reply that ended before the person left stays above it.
  const done = eventRows([1, 2]);
  for (const seq of [3, 4]) {
    done.current = seq;
    done.set("reply", { ...reply(3), id: "reply" });
  }
  done.current = 6;
  done.set("row-6", reply(6));
  done.current = undefined;
  done.setAt(done.placeAfter(4), divider(4, 1));
  expect(done.sorted().map((row) => row.id)).toEqual(["row-1", "row-2", "reply", SINCE_DIVIDER, "row-6"]);
});

// The divider reads the daemon's persisted seen cursor (`readThrough`), so the client derives new
// turns from rows written after that cursor rather than from the session list's transient count.
const summary = (seq: number): AcpmuxRow => ({ id: `turn-${seq}`, version: 1, at: seq, kind: "turnSummary" });

test("nothing after the cursor is no new turn", () => {
  const rows = eventRows([1, 2, 5]);
  rows.current = 6;
  rows.set("turn-6", summary(6));
  rows.current = undefined;
  expect(rows.turnsAfter(6)).toBe(0);
  expect(rows.turnsAfter(99)).toBe(0);
});

test("completed and streaming turns after the cursor count once each", () => {
  const rows = eventRows([1, 2]);
  rows.current = 3;
  rows.set("turn-3", summary(3));
  for (const seq of [4, 6]) {
    rows.current = seq;
    rows.set(`row-${seq}`, reply(seq));
  }
  rows.current = 7;
  rows.set("turn-7", summary(7));
  rows.current = 8;
  rows.set("row-8", reply(8));
  rows.current = undefined;
  expect(rows.turnsAfter(3)).toBe(1);
  expect(rows.turnsAfter(2)).toBe(2);
  expect(rows.turnsAfter(7)).toBe(1);
});

test("seqOf uses the newest event write and excludes local rows and the divider", () => {
  const rows = eventRows([1, 2]);
  rows.current = 4;
  rows.set("row-2", { ...reply(2), text: "r2 more" });
  rows.current = undefined;
  rows.set("local", { ...reply(0), id: "local" });
  rows.setAt(rows.placeAfter(1), divider(1, 1));
  expect(rows.seqOf("row-1")).toBe(1);
  expect(rows.seqOf("row-2")).toBe(4);
  expect(rows.seqOf("local")).toBeUndefined();
  expect(rows.seqOf(SINCE_DIVIDER)).toBeUndefined();
  expect(rows.seqOf("missing")).toBeUndefined();
});

// Leo, 2026-11-22, on the line over a subagent's "started working" and nothing else: "this is a bad
// new. it shouldnt just do this like this when there's nothing".
const started = (id: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: SUBAGENT_STARTED, subagents: [] });
const prompt = (id: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "user", text: "go on" });
const message = (id: string): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind: "user",
  text: "From the coordinator",
  incoming: { kind: "notice", text: "From the coordinator" },
});

test("a line over status lines and the person's own prompts has nothing new under it", () => {
  expect(sinceNews([reply(1), divider(1, 1), started("s1"), prompt("p1"), started("s2")], 1)).toBe(false);
  expect(sinceNews([reply(1), divider(1, 1)], 1)).toBe(false);
  // A reply with no words yet is not news; one with words is.
  expect(isNews({ ...reply(2), text: "  " })).toBe(false);
  expect(sinceNews([reply(1), divider(1, 1), started("s1"), reply(2)], 1)).toBe(true);
  // Another agent's message to this chat is news; a recap on the line is too.
  expect(sinceNews([reply(1), divider(1, 1), message("m1")], 1)).toBe(true);
  const recapped: AcpmuxRow = {
    ...divider(1, 1),
    since: { key: "s:1", seq: 1, turns: 1, recap: { key: "r", text: "Done." } },
  };
  expect(sinceNews([reply(1), recapped, started("s1")], 1)).toBe(true);
  // Not a line at that index: nothing.
  expect(sinceNews([reply(1), divider(1, 1)], 0)).toBe(false);
});

// A running turn folds the messages that started it (or that arrived during it) into its own rows;
// they are still news, so the line shows over them.
test("messages folded into a run, a batch, the queue or the turn's prompt are news", () => {
  const row = (kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id: kind,
    version: 1,
    at: 1,
    kind,
    ...extra,
  });
  const run = (received: number): AcpmuxRow =>
    row(MESSAGE_RUN, { messageRun: { sent: 1, received, work: [], failed: 0, running: false, rows: [] } });
  expect(isNews(run(2))).toBe(true);
  expect(isNews(run(0))).toBe(false);
  expect(isNews(row(LANE_NOTICE_BATCH))).toBe(true);
  expect(isNews(row(QUEUED_MESSAGE))).toBe(true);
  expect(isNews(row(PENDING_MESSAGES))).toBe(true);
  expect(isNews({ ...started("s1"), foldedPrompt: message("m1") })).toBe(true);
  expect(isNews({ ...started("s1"), foldedPrompt: prompt("p1") })).toBe(false);
});

test("the news scan is bounded: a run of status lines past its reach counts as news", () => {
  const statuses = Array.from({ length: SINCE_NEWS_REACH + 4 }, (_, at) => started(`s${at}`));
  expect(sinceNews([divider(1, 1), ...statuses], 0)).toBe(true);
  expect(sinceNews([divider(1, 1), ...statuses.slice(0, SINCE_NEWS_REACH)], 0)).toBe(false);
});

// Leo, 2026-11-22: "probably also not layout shift this". The line takes no height and no gap, so
// every other row is placed where it is with no line (it was a 28 px row with its gaps: 52 px).
test("the line moves no row: the rows' tops are the same with and without it", () => {
  const before = [prompt("p0"), reply(1), reply(2)];
  const after = [message("m3"), reply(4), started("s5"), reply(6)];
  const plain = layoutConversation([...before, ...after], 720);
  const lined = layoutConversation([...before, divider(2, 1), ...after], 720);
  expect(lined.heights[before.length]).toBe(0);
  const shift = Math.max(
    ...[...before, ...after].map((_, at) => Math.abs(lined.tops[at < before.length ? at : at + 1]! - plain.tops[at]!)),
  );
  expect(shift).toBe(0);
  expect(lined.totalHeight).toBe(plain.totalHeight);
});
