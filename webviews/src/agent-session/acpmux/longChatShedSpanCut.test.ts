// A chat left open lets go of its oldest records at a cut no row spans (`shedOlderHeld`). A row can begin at an
// order no held record has (a prompt drawn before its record comes back, at `latest + 0.5`; a hole a filtered page
// left), and the cut stepping back to it found the same record again and spun with the main thread held: Leo's
// NIGHTLY renderer at 100% CPU and 14 GB, every chat page in it frozen and unclosable.
import { expect, test } from "bun:test";
import type { EventRecord } from "./eventRecord";
import { heldAtOrBefore, midTurnCut, spanCut } from "./direct";

const held = (seqs: readonly number[]): EventRecord[] =>
  seqs.map((seq) => ({ sessionId: "s", seq, at: 1_700_000_000_000 + seq, dir: "mux", kind: "agent_update", msg: {} }));

/// `spanningFrom` for rows that each begin at `starts[seq]` (else at their own record), failing the test past `cap`
/// calls instead of hanging it.
function rowsBeginning(starts: Record<number, number>, cap = 1_000) {
  let calls = 0;
  return (seq: number) => {
    calls += 1;
    if (calls > cap) throw new Error(`the cut was moved back ${cap} times and never settled`);
    return starts[seq] ?? seq;
  };
}

test("a cut moved back to where a row begins between two held records steps to the older one and settles", () => {
  const events = held(Array.from({ length: 100 }, (_, index) => index + 1));
  // The row at record 71 began at 70.5, where no record is held.
  const cut = spanCut(events, 70, rowsBeginning({ 71: 70.5 }));
  expect(events[cut]!.seq).toBe(70);
  // A row that began in a hole of the held seqs (record 40 never read): the cut at 52 goes to 39, not back to 41.
  const holed = held([
    ...Array.from({ length: 39 }, (_, index) => index + 1),
    ...Array.from({ length: 60 }, (_, index) => index + 41),
  ]);
  const at = spanCut(holed, 50, rowsBeginning({ 52: 40, 41: 40 }));
  expect(holed[at]!.seq).toBe(39);
});

test("a cut inside an open turn is spanned by no row, though the row begins where no record is held", () => {
  const events = held(Array.from({ length: 100 }, (_, index) => index + 1));
  const spanningFrom = rowsBeginning({ 71: 70.5 });
  const at = midTurnCut(events, 30, Infinity, spanningFrom);
  expect(at).toBeGreaterThan(0);
  expect(spanningFrom(events[at]!.seq)).toBeGreaterThanOrEqual(events[at]!.seq);
});

test("a row that began before every held record leaves no cut", () => {
  const events = held(Array.from({ length: 10 }, (_, index) => index + 5));
  expect(spanCut(events, 6, rowsBeginning({ 11: 2.5 }))).toBeLessThanOrEqual(0);
  expect(heldAtOrBefore(events, 4)).toBe(-1);
  expect(heldAtOrBefore(events, 9)).toBe(4);
  expect(heldAtOrBefore(events, 9.5)).toBe(4);
  expect(heldAtOrBefore(events, 99)).toBe(9);
});
