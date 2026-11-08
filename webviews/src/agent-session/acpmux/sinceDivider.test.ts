// "New since you looked" sorts right after the record the person had seen (acpmux `seenSeq`), between
// that event's rows and the next one's, wherever the rows around it came from (OrderedRows.setAfter).
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
  rows.setAfter(2, divider(2, 2));
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
  rows.setAfter(2, divider(2, 2));
  rows.setAfter(5, divider(5, 1));
  const ids = rows.sorted().map((row) => row.id);
  expect(ids.filter((id) => id === SINCE_DIVIDER)).toHaveLength(1);
  expect(ids).toEqual(["row-1", "row-2", "row-5", SINCE_DIVIDER, "row-8"]);
  // A rebuild drops it with the rows; placed again, it sorts among the replayed events.
  rows.clear();
  rows.setAfter(5, divider(5, 1));
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
