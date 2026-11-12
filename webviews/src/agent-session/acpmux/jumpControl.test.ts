// l10n-allow-file: test fixture rows, not shipped UI.
// The one jump control on the seen cursor (jumpControl.ts): which rows are unseen, the first of them
// read in amortized O(1), the rows in view in O(log n), how far the view moves the cursor, and the
// control's state (Leo, 2026-11-12: "when you restart the update, all of a sudden it's just, like,
// you know, it's there and it's noisy").
import { expect, test } from "bun:test";
import { MESSAGE_RUN, type AcpmuxRow } from "./model";
import {
  countsUnseen,
  emptyUnseenScan,
  firstIndexAfter,
  firstUnseen,
  jumpControl,
  seenThrough,
  unseenTurns,
  visibleRows,
  type UnseenScan,
} from "./jumpControl";

const row = (id: string, seq: number | undefined, kind = "assistant", extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind,
  ...(seq !== undefined && { seq }),
  ...extra,
});
const scan = (): { current: UnseenScan } => ({ current: emptyUnseenScan() });

/// Rows of `height` px each, in a geometry like the layout's.
function geometry(count: number, height = 100) {
  return {
    count,
    topAt: (at: number) => Math.max(0, Math.min(at, count)) * height,
    heightAt: (at: number) => (at >= 0 && at < count ? height : 0),
    upperBoundTop: (target: number) => {
      // The first row whose top is greater than `target`.
      let lo = 0;
      let hi = count;
      while (lo < hi) {
        const mid = (lo + hi) >>> 1;
        if (mid * height <= target) lo = mid + 1;
        else hi = mid;
      }
      return lo;
    },
  };
}

test("a run of messages counts: jumpControl.ts writes out model.ts MESSAGE_RUN", () => {
  expect(countsUnseen(row("run", 1, MESSAGE_RUN))).toBe(true);
});

test("an agent's rows and another person's prompts count; your own prompts, notices and status never do", () => {
  expect(countsUnseen(row("a", 1, "assistant"))).toBe(true);
  expect(countsUnseen(row("t", 1, "tool"))).toBe(true);
  expect(countsUnseen(row("th", 1, "thought"))).toBe(true);
  expect(countsUnseen(row("mine", 1, "user"))).toBe(false);
  expect(countsUnseen(row("theirs", 1, "user", { author: { id: "guest-1", name: "Sam" } }))).toBe(true);
  expect(countsUnseen(row("guest-own", 1, "user", { author: { id: "guest-1", name: "Sam" } }), "guest-1")).toBe(false);
  expect(countsUnseen(row("agent-msg", 1, "user", { incoming: { kind: "message" } as AcpmuxRow["incoming"] }))).toBe(
    true,
  );
  expect(countsUnseen(row("notice", 1, "user", { incoming: { kind: "notice" } as AcpmuxRow["incoming"] }))).toBe(false);
  expect(countsUnseen(row("untyped", 1, "user", { untyped: true }))).toBe(false);
  for (const kind of ["notice", "turnSummary", "compaction", "sinceDivider", "typing", "failover", "sessionStart"])
    expect(countsUnseen(row(kind, 1, kind)), kind).toBe(false);
});

test("the first unseen row is the first counted row after the cursor; none before the cursor is known", () => {
  const rows = [row("p1", 1, "user"), row("a2", 2), row("n3", 3, "notice"), row("p4", 4, "user"), row("a5", 5)];
  expect(firstUnseen(rows, undefined, scan())).toBe(-1);
  expect(firstUnseen(rows, 0, scan())).toBe(1);
  expect(firstUnseen(rows, 2, scan())).toBe(4);
  expect(firstUnseen(rows, 5, scan())).toBe(-1);
  expect(firstIndexAfter(rows, 3)).toBe(3);
  expect(firstIndexAfter(rows, 99)).toBe(5);
  // A row the view derives carries no seq: it sorts by the row before it.
  const derived = [row("a1", 1), row("fold", undefined, "activity"), row("a3", 3)];
  expect(firstIndexAfter(derived, 1)).toBe(2);
});

test("appended rows and a cursor moving on read on from where the last read stopped", () => {
  const memo = scan();
  const rows = Array.from({ length: 10 }, (_, i) => row(`r${i}`, i + 1, i % 2 ? "assistant" : "user"));
  expect(firstUnseen(rows, 10, memo)).toBe(-1);
  const more = [...rows, row("p11", 11, "user"), row("a12", 12)];
  expect(firstUnseen(more, 10, memo)).toBe(11);
  expect(memo.current.from).toBe(11);
  // The same first stays while rows append.
  const evenMore = [...more, row("a13", 13)];
  expect(firstUnseen(evenMore, 10, memo)).toBe(11);
  // The cursor moved past it.
  expect(firstUnseen(evenMore, 12, memo)).toBe(12);
  expect(firstUnseen(evenMore, 13, memo)).toBe(-1);
  // Another chat's rows (another tail): read again.
  expect(firstUnseen([row("x", 1), row("y", 2)], 0, memo)).toBe(0);
});

test("the rows in view are those crossing the band; a band between rows takes the row it falls in", () => {
  const g = geometry(10);
  expect(visibleRows(g, 0, 300)).toEqual({ first: 0, last: 2 });
  expect(visibleRows(g, 150, 450)).toEqual({ first: 1, last: 4 });
  expect(visibleRows(g, 900, 2000)).toEqual({ first: 9, last: 9 });
  expect(visibleRows(geometry(0), 0, 300)).toEqual({ first: 0, last: -1 });
  // O(log n): a god chat's band is found without visiting its rows.
  let reads = 0;
  const big = geometry(1_000_000);
  const counted = { ...big, upperBoundTop: (t: number) => (reads++, big.upperBoundTop(t)) };
  expect(visibleRows(counted, 50_000_000, 50_000_500)).toEqual({ first: 500_000, last: 500_004 });
  expect(reads).toBeLessThanOrEqual(2);
});

test("what is in view moves the cursor, never past an unseen row above the view or below it", () => {
  const rows = Array.from({ length: 10 }, (_, i) => row(`r${i}`, i + 1));
  // Nothing unseen: the newest row in view.
  expect(seenThrough(rows, { first: 2, last: 5 }, -1)).toBe(6);
  // The first unseen row in view: through the newest in view.
  expect(seenThrough(rows, { first: 2, last: 5 }, 3)).toBe(6);
  // Above the view: the reader has not been there, nothing moves.
  expect(seenThrough(rows, { first: 2, last: 5 }, 1)).toBeUndefined();
  // Below it: up to just before it.
  expect(seenThrough(rows, { first: 2, last: 5 }, 8)).toBe(6);
  expect(seenThrough(rows, { first: 0, last: -1 }, -1)).toBeUndefined();
  // A notice or status row at the bottom of the view moves nothing: the newest row that counts.
  const withNotice = [...rows, row("notice", 11, "notice"), row("mine", 12, "user")];
  expect(seenThrough(withNotice, { first: 8, last: 11 }, -1)).toBe(10);
  expect(seenThrough([row("n", 1, "notice")], { first: 0, last: 0 }, -1)).toBeUndefined();
});

test("the control: an ask first, then up only while an unseen row is above, then Jump to latest", () => {
  const none = { asks: 0, asksElsewhere: 0 };
  expect(jumpControl({ unseenAbove: false, behind: false, ...none })).toEqual({ kind: "hidden" });
  expect(jumpControl({ unseenAbove: true, behind: false, ...none })).toEqual({ kind: "up" });
  expect(jumpControl({ unseenAbove: true, behind: true, ...none })).toEqual({ kind: "up" });
  expect(jumpControl({ unseenAbove: false, behind: true, ...none })).toEqual({ kind: "latest" });
  expect(jumpControl({ unseenAbove: true, behind: true, asks: 1, asksElsewhere: 0 })).toEqual({ kind: "latest" });
  expect(jumpControl({ unseenAbove: false, behind: false, asks: 1, asksElsewhere: 1 })).toEqual({ kind: "latest" });
});

test("a restart with nothing new: the cursor at the latest row leaves nothing unseen and no arrow", () => {
  const rows = Array.from({ length: 50 }, (_, i) => row(`r${i}`, i + 1));
  const unseen = firstUnseen(rows, 50, scan());
  expect(unseen).toBe(-1);
  const view = visibleRows(geometry(50), 4000, 4500);
  expect(
    jumpControl({ unseenAbove: unseen >= 0 && unseen < view.first, behind: false, asks: 0, asksElsewhere: 0 }),
  ).toEqual({ kind: "hidden" });
});

test("the count badge counts the unseen turns, the running one too", () => {
  const rows = [row("a1", 1), row("s2", 2, "turnSummary"), row("a3", 3), row("s4", 4, "turnSummary"), row("a5", 5)];
  expect(unseenTurns(rows, 0)).toBe(3);
  expect(unseenTurns(rows, 2)).toBe(2);
  expect(unseenTurns(rows, -1)).toBe(0);
});
