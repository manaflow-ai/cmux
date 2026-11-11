import { describe, expect, test } from "bun:test";

import type { AcpmuxRow } from "../model";
import { OLDER_RESERVE_MAX, type OlderReserve, olderReserve, payOlderRoom } from "./olderReserve";

// A turn: a prompt and a reply, each 100px tall.
const turn = (n: number): AcpmuxRow[] =>
  [
    { id: `u${n}`, kind: "user", text: `prompt ${n}` },
    { id: `a${n}`, kind: "assistant", text: `reply ${n}` },
  ] as unknown as AcpmuxRow[];
const turns = (from: number, to: number) => Array.from({ length: to - from }, (_, i) => turn(from + i)).flat();

const pass = (
  state: OlderReserve | undefined,
  rows: AcpmuxRow[],
  more: { canLoadOlder?: boolean; earlier?: number; promptCount?: number },
) =>
  olderReserve(state, {
    sessionId: "s",
    rows,
    rowTop: (index) => index * 100,
    rowsHeight: rows.length * 100,
    canLoadOlder: more.canLoadOlder ?? true,
    earlier: more.earlier,
    promptCount: more.promptCount,
  });

describe("olderReserve", () => {
  test("pages that land take their height out of the room: the rows' end never moves down", () => {
    // 10 of 50 turns held: 40 more at the loaded turns' 200px a turn, leaning 2% high (8160).
    let rows = turns(40, 50);
    let step = pass(undefined, rows, { earlier: 40 });
    expect(step.reserve).toBe(8160);
    let end = step.reserve + rows.length * 100;
    const ends: number[] = [];
    for (let from = 30; from >= 10; from -= 10) {
      rows = turns(from, 50);
      step = pass(step.state, rows, { earlier: from });
      const now = step.reserve + rows.length * 100;
      // A refinement only takes back the lean (the thumb moves up, with the reader); it never adds.
      expect(now).toBeLessThanOrEqual(end);
      end = now;
      ends.push(now);
    }
    // 6160 held (the 6120 estimate is within 64px); 4160 refined to 4080; 2080 held.
    expect(ends).toEqual([10160, 10080, 10080]);
    expect(step.reserve).toBe(2080);
  });

  test("a row above the pin that draws taller takes the room, not the rows under it", () => {
    const rows = turns(40, 50);
    const first = pass(undefined, rows, { earlier: 40 });
    const older = turns(39, 50);
    const step = olderReserve(first.state, {
      sessionId: "s",
      rows: older,
      // The landed turn draws 350px instead of 200px.
      rowTop: (index) => (index < 2 ? index * 175 : 350 + (index - 2) * 100),
      rowsHeight: 350 + rows.length * 100,
      canLoadOlder: true,
      earlier: 39,
    });
    // The 150px it grew comes out of the room, and the rows under the pin stay. The landed turn ran
    // 350px against the tail's 200: the 39 still unloaded are estimated at its 350 (leaning 2%), over
    // the room held, so the difference is owed, not added at once.
    expect(step.reserve).toBe(first.reserve - 350);
    expect(step.state?.owed).toBe(Math.round(350 * 39 * 1.02) - step.reserve);
  });

  test("no room once nothing older is left, nor without a count of what is", () => {
    expect(pass(undefined, turns(0, 10), { canLoadOlder: false, earlier: 5 }).reserve).toBe(0);
    expect(pass(undefined, turns(0, 10), {}).reserve).toBe(0);
  });

  test("a room that runs out stays exhausted when more pages and counts arrive", () => {
    const first = pass(undefined, turns(49, 50), { earlier: 1 });
    expect(first.reserve).toBe(204);
    // The estimate was short: three turns landed and more are left.
    const step = pass(first.state, turns(46, 50), { earlier: 10 });
    expect(step.reserve).toBe(0);
    expect(pass(step.state, turns(40, 50), { earlier: 40 }).reserve).toBe(0);
  });

  test("a divider above the first prompt that is replaced keeps the room", () => {
    const divider = (id: string) => ({ id, kind: "date" }) as unknown as AcpmuxRow;
    const first = pass(undefined, [divider("d1"), ...turns(40, 50)], { earlier: 40 });
    expect(first.state?.pinId).toBe("u40");
    // The page brings the turn before it, under its own divider; the old one goes.
    const step = pass(first.state, [divider("d0"), ...turns(39, 50)], { earlier: 39 });
    expect(step.state?.pinId).toBe("u40");
    // The pin (and every row under it) stays on its pixel: row 1 before, row 3 after.
    expect(step.reserve + 3 * 100).toBe(first.reserve + 1 * 100);
  });

  test("a first frame with no count seeds the room once, when the count comes; later counts add none", () => {
    // Leo, 2026-11-11: "the thumb turns from a tiny thing that would imply a big chat to just a medium
    // sized thumb at the top". A chat drawn before its summary held no room for good, so every page
    // grew the content above the reader and the thumb shrank page after page.
    const rows = turns(40, 50);
    const none = pass(undefined, rows, {});
    expect(none.reserve).toBe(0);
    expect(pass(none.state, rows, {}).reserve).toBe(0);
    const seeded = pass(none.state, rows, { earlier: 40 });
    expect(seeded.reserve).toBe(8160);
    // Seeded: a later, larger count adds nothing between pages.
    expect(pass(seeded.state, rows, { earlier: 400 }).reserve).toBe(8160);
  });

  test("the first frame uses promptCount before earlier prompts arrive", () => {
    const rows = turns(40, 50);
    const first = pass(undefined, rows, { promptCount: 50 });
    expect(first.reserve).toBe(8160);
    expect(pass(first.state, rows, { earlier: 400, promptCount: 500 }).reserve).toBe(8160);
  });

  test("shrinking rows above the pin never refills consumed room", () => {
    const first = pass(undefined, turns(40, 50), { promptCount: 50 });
    const page = pass(first.state, turns(30, 50), { earlier: 30 });
    expect(page.reserve).toBe(6160);
    const resized = (state: OlderReserve | undefined, top: number) =>
      olderReserve(state, {
        sessionId: "s",
        rows: turns(30, 50),
        rowTop: (index) => (index < 20 ? (index * top) / 20 : top + (index - 20) * 100),
        rowsHeight: top + 2000,
        canLoadOlder: true,
        promptCount: 50,
      });
    const collapsed = resized(page.state, 1000);
    expect(collapsed.reserve).toBe(6160);
    expect(resized(collapsed.state, 2000).reserve).toBe(5160);
  });

  test("a removed pin keeps only the remaining room without another estimate", () => {
    const first = pass(undefined, turns(40, 50), { promptCount: 50 });
    const page = pass(first.state, turns(30, 50), { earlier: 30 });
    const removed = turns(30, 50).filter((row) => row.id !== "u40");
    const next = pass(page.state, removed, { earlier: 400 });
    expect(next.reserve).toBe(page.reserve);
    expect(next.state?.pinId).toBe("u30");
    expect(pass(next.state, removed, { earlier: 4000 }).reserve).toBe(next.reserve);
  });

  test("completed or temporarily empty history never reseeds the same session", () => {
    const rows = turns(40, 50);
    const first = pass(undefined, rows, { promptCount: 50 });
    const complete = pass(first.state, rows, { canLoadOlder: false });
    expect(complete.reserve).toBe(0);
    expect(pass(complete.state, rows, { promptCount: 500 }).reserve).toBe(0);
    const empty = pass(first.state, [], {});
    expect(pass(empty.state, rows, { promptCount: 500 }).reserve).toBe(0);
    const initiallyEmpty = pass(undefined, [], {});
    expect(pass(initiallyEmpty.state, rows, { promptCount: 50 }).reserve).toBe(8160);
  });

  test("another chat starts its own room, and the room is capped", () => {
    const first = pass(undefined, turns(0, 10), { earlier: 10 });
    const other = olderReserve(first.state, {
      sessionId: "t",
      rows: turns(0, 10),
      rowTop: (index) => index * 100,
      rowsHeight: 1000,
      canLoadOlder: true,
      earlier: 1_000_000,
    });
    expect(other.reserve).toBe(OLDER_RESERVE_MAX);
    expect(other.state?.sessionId).toBe("t");
  });

  test("a page whose turns are taller than the estimate's owes the shortfall, paid as the reader rises", () => {
    // The tail's turns are 200px; the older turns are 400px. Each page refines the average.
    const first = pass(undefined, turns(40, 50), { earlier: 40 });
    expect(first.reserve).toBe(8160);
    // Ten older turns land at 400px each: the 30 still to come are estimated at the landed turns'
    // 400px (12240 leaning 2%), over the whole sample's 300px, against the 4160 left. Added at once
    // it would push the thumb down; it is owed instead.
    const step = olderReserve(first.state, {
      sessionId: "s",
      rows: turns(30, 50),
      rowTop: (index) => (index < 20 ? index * 200 : 4000 + (index - 20) * 100),
      rowsHeight: 6000,
      canLoadOlder: true,
      earlier: 30,
    });
    expect(step.reserve).toBe(4160);
    expect(step.state?.owed).toBe(8080);
    // A 100px scroll up pays 75px of it; a scroll down pays nothing.
    const paid = payOlderRoom(step.state, 100)!;
    expect(paid.room).toBe(4235);
    expect(paid.end).toBe(step.state!.end + 75);
    expect(paid.owed).toBe(8005);
    expect(payOlderRoom(paid, -100)).toBe(paid);
    // The next pass holds what was paid, and still owes the rest.
    const next = olderReserve(paid, {
      sessionId: "s",
      rows: turns(30, 50),
      rowTop: (index) => (index < 20 ? index * 200 : 4000 + (index - 20) * 100),
      rowsHeight: 6000,
      canLoadOlder: true,
      earlier: 30,
    });
    expect(next.reserve).toBe(4235);
    expect(next.state?.owed).toBe(8005);
    // Paid in full, nothing more is owed.
    expect(payOlderRoom(next.state, 100_000)!.owed).toBeUndefined();
  });

  test("a later count that names fewer prompts does not shrink the room", () => {
    // 50 prompts by the summary; then a prompt index cut at its cap names only 5 older than the rows.
    const first = pass(undefined, turns(40, 50), { promptCount: 50 });
    expect(first.reserve).toBe(8160);
    const step = pass(first.state, turns(30, 50), { earlier: 5 });
    // The page took its 2000px; 30 prompts are still left by the first count: 6120 is within 64px of
    // the 6160 held, so the room stays.
    expect(step.reserve).toBe(6160);
    expect(step.state?.prompts).toBe(50);
  });

  test("a chat held whole before opens with the exact room", () => {
    const rows = turns(40, 50);
    // From the last whole visit: 7321px of history above the first loaded prompt.
    const step = olderReserve(undefined, {
      sessionId: "s",
      rows,
      rowTop: (index) => index * 100,
      rowsHeight: rows.length * 100,
      canLoadOlder: true,
      earlier: 40,
      knownAbove: (row) => (row.id === "u40" ? 7321 : undefined),
    });
    expect(step.reserve).toBe(7321);
  });
});
