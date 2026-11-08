import { describe, expect, test } from "bun:test";

import type { AcpmuxRow } from "../model";
import { OLDER_RESERVE_MAX, type OlderReserve, olderReserve } from "./olderReserve";

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
  test("pages that land take their height out of the room: the rows' end stays put", () => {
    // 10 of 50 turns held: 40 more at 200px a turn, held long (OLDER_RESERVE_HEADROOM) at 300px.
    let rows = turns(40, 50);
    let step = pass(undefined, rows, { earlier: 40 });
    expect(step.reserve).toBe(12000);
    const end = step.reserve + rows.length * 100;
    for (let from = 30; from >= 10; from -= 10) {
      rows = turns(from, 50);
      step = pass(step.state, rows, { earlier: from });
      expect(step.reserve + rows.length * 100).toBe(end);
    }
    expect(step.reserve).toBe(6000);
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
    expect(step.reserve).toBe(12000 - 350);
  });

  test("no room once nothing older is left, nor without a count of what is", () => {
    expect(pass(undefined, turns(0, 10), { canLoadOlder: false, earlier: 5 }).reserve).toBe(0);
    expect(pass(undefined, turns(0, 10), {}).reserve).toBe(0);
  });

  test("a room that runs out stays exhausted when more pages and counts arrive", () => {
    const first = pass(undefined, turns(49, 50), { earlier: 1 });
    expect(first.reserve).toBe(300);
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

  test("late counts never add room after the first frame", () => {
    const rows = turns(40, 50);
    const none = pass(undefined, rows, {});
    expect(none.reserve).toBe(0);
    expect(pass(none.state, rows, {}).reserve).toBe(0);
    expect(pass(none.state, rows, { earlier: 40 }).reserve).toBe(0);
    expect(pass(none.state, rows, { promptCount: 50 }).reserve).toBe(0);
  });

  test("the first frame uses promptCount before earlier prompts arrive", () => {
    const rows = turns(40, 50);
    const first = pass(undefined, rows, { promptCount: 50 });
    expect(first.reserve).toBe(12000);
    expect(pass(first.state, rows, { earlier: 400, promptCount: 500 }).reserve).toBe(12000);
  });

  test("shrinking rows above the pin never refills consumed room", () => {
    const first = pass(undefined, turns(40, 50), { promptCount: 50 });
    const page = pass(first.state, turns(30, 50), { earlier: 30 });
    expect(page.reserve).toBe(10000);
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
    expect(collapsed.reserve).toBe(10000);
    expect(resized(collapsed.state, 2000).reserve).toBe(9000);
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
    expect(pass(initiallyEmpty.state, rows, { promptCount: 50 }).reserve).toBe(12000);
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
});
