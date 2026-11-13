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
  lineOver,
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

test("a press lands on the New line while only rows that never count lie between it and the first unseen row", () => {
  const rows = [
    row("a", 1),
    row("line", undefined, "sinceDivider"),
    row("mine", 2, "user"),
    row("note", 3, "status"),
    row("footer", 3, "turnFooter"),
    row("b", 4),
  ];
  expect(lineOver(rows, 5, 1)).toBe(1);
  // An agent's row between them: the line is not over the first unseen row.
  const apart = [row("line", undefined, "sinceDivider"), row("x", 1), row("b", 2)];
  expect(lineOver(apart, 2, 0)).toBe(2);
  // No line, or a line below the row: the row.
  expect(lineOver(rows, 5, -1)).toBe(5);
  expect(lineOver(rows, 0, 1)).toBe(0);
});

/// The control for `rows` (each 100 px tall) with the cursor at `readThrough` and the view's top at
/// `top`, `height` tall, at the latest message when its bottom reaches the last row.
function controlAt(rows: readonly AcpmuxRow[], readThrough: number, top: number, height = 500) {
  const unseen = firstUnseen(rows, readThrough, scan());
  const view = visibleRows(geometry(rows.length), top, top + height);
  return jumpControl({
    unseenAbove: unseen >= 0 && unseen < view.first,
    behind: top + height < rows.length * 100,
    asks: 0,
    asksElsewhere: 0,
  }).kind;
}

// #41831's idle mark asked for these (Leo, 2026-11-12: "it's more so, like, idle detection... when
// you have, like, at least one full screen of idleness, that's when it starts having that... instead
// of getting overwritten by some useless noise"); the cursor model keeps them.
test("a restart, a reconnect, an older page or the page's own moves bring no up arrow", () => {
  const seen = Array.from({ length: 40 }, (_, i) => row(`r${i}`, i + 1));
  // Reopened at the latest, the cursor where it was: nothing.
  expect(controlAt(seen, 40, 3500)).toBe("hidden");
  // A reconnect redraws the same rows and adds its notice and status rows after the cursor: nothing.
  const reconnected = [...seen, row("reconnected", 41, "notice"), row("status", 42, "status")];
  expect(controlAt(reconnected, 40, 3700)).toBe("hidden");
  // An older page lands above: its rows are all before the cursor.
  const older = [...Array.from({ length: 20 }, (_, i) => row(`o${i}`, i - 30)), ...seen];
  expect(controlAt(older, 40, 5500)).toBe("hidden");
  // The page moves the view (a reveal, Find, a settle) anywhere: Jump to latest, never up.
  for (const top of [0, 1200, 2900]) expect(controlAt(seen, 40, top)).toBe("latest");
});

test("after Jump to latest nothing turns up, and going back up a little is Jump to latest, not up", () => {
  const rows = Array.from({ length: 40 }, (_, i) => row(`r${i}`, i + 1));
  // Everything seen, scrolled up, pressed: at the latest the disc goes; a little up it is down again.
  expect(controlAt(rows, 40, 3500)).toBe("hidden");
  expect(controlAt(rows, 40, 3300)).toBe("latest");
  // Unless unseen rows lie above: that is the one thing that turns it up.
  expect(controlAt(rows, 30, 3500)).toBe("up");
});

test("less than a screen of new content while idle brings no up arrow; a screen of it does", () => {
  const before = Array.from({ length: 40 }, (_, i) => row(`r${i}`, i + 1));
  const arrived = (count: number) => [...before, ...Array.from({ length: count }, (_, i) => row(`n${i}`, 41 + i))];
  // The reader stepped away at the latest (cursor 40) with a 500 px view; the view follows the reply.
  const atLatest = (rows: AcpmuxRow[]) => controlAt(rows, 40, rows.length * 100 - 500);
  // Three rows (300 px): all of them still in view, nothing unseen above.
  expect(atLatest(arrived(3))).toBe("hidden");
  // Five rows fill the view exactly: the first is at its top, still in view.
  expect(atLatest(arrived(5))).toBe("hidden");
  // Six (more than a screen): the first new row went above the view.
  expect(atLatest(arrived(6))).toBe("up");
  // Only bookkeeping arrived, a screen of it: nothing to catch up on.
  const noise = [...before, ...Array.from({ length: 12 }, (_, i) => row(`s${i}`, 41 + i, "status"))];
  expect(atLatest(noise)).toBe("hidden");
});

test("another chat with the same row ids and cursor reads again: the scan is kept across chat switches", () => {
  const memo = scan();
  // Chat A: its first unseen row is its second.
  const a = [row("user-1", 1, "user"), row("assistant-2", 2), row("assistant-3", 3)];
  expect(firstUnseen(a, 1, memo, "owner", "chat-a")).toBe(1);
  // Chat B: same shape and ids (they are per chat), all of it from the reader: nothing unseen.
  const b = [
    row("user-1", 1, "user"),
    row("assistant-2", 2, "user"),
    row("assistant-3", 3, "user"),
    row("user-4", 4, "user"),
  ];
  expect(firstUnseen(b, 1, memo, "owner", "chat-b")).toBe(-1);
});
