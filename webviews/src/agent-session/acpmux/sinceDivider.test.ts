// "New since you looked" sorts right after the record the person had seen (acpmux `seenSeq`), between
// that event's rows and the next one's, wherever the rows around it came from (OrderedRows.placeAfter, setAt).
import { expect, test } from "bun:test";
import { OrderedRows } from "./direct";
import { SINCE_DIVIDER, type AcpmuxRow } from "./model";
import { sessionEntry } from "./sessionList";

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
