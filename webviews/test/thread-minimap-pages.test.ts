// The rail's model over pages of older history (threadMinimap/model.ts minimapTurns' page path,
// foldIncoming, hasIncoming, and the key maps railRows.ts reads): a page builds only its own turns
// and ticks and reuses the rest by reference, and every list, key and fold must equal a reading of
// the same rows from scratch, for pages put above the rows, pages taken away, a first row drawn
// again, rows rebuilt with the same content, rows added at the tail and readings React dropped.
import { describe, expect, test } from "bun:test";
import { noteKeptSuffix, rowsDelta } from "../src/agent-session/acpmux/conversation/rowsDelta";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  foldIncoming,
  hasIncoming,
  minimapTurns,
  turnRow,
  type MinimapTick,
  type MinimapTurn,
  type MinimapTurns,
} from "../src/agent-session/acpmux/threadMinimap/model";
import { tickRows, turnRows } from "../src/agent-session/acpmux/threadMinimap/railRows";
import { tickIndex } from "../src/agent-session/acpmux/threadMinimap/threadMinimapModel";

const PEERS = ["peer/a", "peer/b"];

/// Rows of prompts (some other chats' messages, which fold into runs, some steers), replies and
/// tool calls, from a seeded generator.
function make(seed: { n: number }, prefix: string, count: number): AcpmuxRow[] {
  return Array.from({ length: count }, (_, at): AcpmuxRow => {
    seed.n = (seed.n * 1103515245 + 12345) % 2 ** 31;
    const pick = seed.n % 8;
    const id = `${prefix}${at}`;
    if (pick === 0 || pick === 1) return { id, kind: "user", text: `ask ${id}`, version: 1, at: 0 };
    if (pick === 2 || pick === 3) {
      const name = PEERS[seed.n % PEERS.length]!;
      return {
        id,
        kind: "user",
        text: `note ${id}`,
        version: 1,
        at: 0,
        incoming: { kind: "message", message: { name, sessionId: name, text: `note ${id}`, raw: `note ${id}` } },
      } as AcpmuxRow;
    }
    if (pick === 4) return { id, kind: "user", text: `steer ${id}`, steer: "waiting", version: 1, at: 0 } as AcpmuxRow;
    if (pick === 5) return { id, kind: "activity", items: [], version: 1, at: 0 } as AcpmuxRow;
    return { id, kind: "assistant", text: `reply **${id}** with \`code\``, version: 1, at: 0 };
  });
}

const turnPlain = (base: number, turn: MinimapTurn) => [
  turnRow(base, turn),
  turn.id,
  turn.key,
  turn.prompt,
  turn.from,
  turn.members,
  turn.reply,
  turn.metadata,
];
const tickPlain = (tick: MinimapTick) => [tick.key, tick.id, tick.prompt, tick.from, tick.members];

/// What the rail draws from a reading: its turns and ticks, folded as the rail folds them, each
/// turn's row, each tick's row by key, and whether the menu offers other chats' messages.
function drawn(read: MinimapTurns) {
  const folded = foldIncoming(read.turns, read.ticks, read.loadedStart ?? 0);
  const ticks = tickRows(folded.ticks, 0, "s");
  const turns = turnRows(folded.turns, 0, "s", read.base);
  return {
    turns: read.turns.map((turn) => turnPlain(read.base, turn)),
    ticks: read.ticks.map(tickPlain),
    folded: folded.turns.map((turn) => turnPlain(read.base, turn)),
    foldedTicks: folded.ticks.map(tickPlain),
    rows: Array.from({ length: turns.length }, (_, at) => turns.rowAt(at)),
    keys: folded.ticks.map((tick) => ticks.keyIndex(tick.key)),
    missing: ticks.keyIndex("s#nowhere"),
    incoming: hasIncoming(read.ticks),
  };
}

describe("the rail's model over pages of older history", () => {
  test("pages, pages taken away, a first row drawn again, rebuilt rows and new rows read as from scratch", () => {
    const seed = { n: 11 };
    let rows = make(seed, "r", 80);
    let reading = minimapTurns(rows, "s");
    drawn(reading);
    const pages: AcpmuxRow[][] = [];
    const kinds = new Set<string>();
    for (let step = 0; step < 120; step += 1) {
      const before = rows;
      const kind = step % 6;
      let page: AcpmuxRow[] | undefined;
      if (kind < 2 || (kind === 2 && !pages.length)) {
        page = make(seed, `p${step}-`, 1 + (step % 7));
        pages.push(page);
        rows = [...page, ...before];
        noteKeptSuffix(rows, before, before.length);
        kinds.add("page");
      } else if (kind === 2) {
        rows = before.slice(pages.pop()!.length);
        noteKeptSuffix(rows, before, rows.length);
        kinds.add("page taken away");
      } else if (kind === 3) {
        // The first row drawn again over a page (its date line): a head replaced.
        const head = make(seed, `h${step}-`, 2);
        rows = [...head, ...before.slice(1)];
        noteKeptSuffix(rows, before, rows.length - 2);
        pages.length = 0;
        kinds.add("first row replaced");
      } else if (kind === 4) {
        // Every row made again with the same content: new objects, nothing told.
        rows = before.map((each) => ({ ...each }));
        pages.length = 0;
        kinds.add("rebuilt");
      } else {
        rows = [...before, ...make(seed, `n${step}-`, 2)];
        pages.length = 0;
        kinds.add("tail");
      }
      // A render React dropped: read from the committed reading and thrown away, every few steps.
      if (step % 5 === 0) {
        const other = [...make(seed, `x${step}-`, 3), ...before];
        noteKeptSuffix(other, before, before.length);
        drawn(minimapTurns(other, "s", reading, { base: before, rows: other, from: rowsDelta(before, other).from }));
      }
      const previous = reading;
      reading = minimapTurns(rows, "s", reading, { base: before, rows, from: rowsDelta(before, rows).from });
      expect(drawn(reading)).toEqual(drawn(minimapTurns(rows, "s")));
      // The rail's state finds each tick it named at the last commit by lookups: where a walk finds it.
      const was = foldIncoming(previous.turns, previous.ticks).ticks;
      const now = foldIncoming(reading.turns, reading.ticks).ticks;
      const rail = tickRows(now, 0, "s");
      for (const [at, tick] of was.entries()) {
        const from = at % 3 === 0 ? 0 : Math.max(0, at - 2);
        expect([at, tickIndex(rail, tick, from)]).toEqual([at, tickIndex(now, tick, from)]);
      }
      if (page) {
        // Only the page's turns are new: the last reading's after it are the same objects.
        const kept = new Set<MinimapTurn>(previous.turns);
        const reused = reading.turns.filter((turn) => kept.has(turn)).length;
        expect(reused).toBeGreaterThanOrEqual(previous.turns.length - 1);
        const keptTicks = new Set<MinimapTick>(previous.ticks);
        expect(reading.ticks.filter((tick) => keptTicks.has(tick)).length).toBeGreaterThanOrEqual(
          previous.ticks.length - 1,
        );
      }
    }
    expect([...kinds].sort()).toEqual(["first row replaced", "page", "page taken away", "rebuilt", "tail"]);
  });

  test("a page that joins the run of other chats' messages below it folds into that run's tick", () => {
    const note = (id: string, name = "peer/a"): AcpmuxRow =>
      ({
        id,
        kind: "user",
        text: `note ${id}`,
        version: 1,
        at: 0,
        incoming: { kind: "message", message: { name, sessionId: name, text: id, raw: id } },
      }) as AcpmuxRow;
    const ask = (id: string): AcpmuxRow => ({ id, kind: "user", text: `ask ${id}`, version: 1, at: 0 });
    let rows = [note("m1"), note("m2", "peer/b"), ask("u1"), note("m3"), note("m4")];
    let reading = minimapTurns(rows, "s");
    drawn(reading);
    for (const page of [[note("m0")], [ask("u0"), note("m-1")], [note("m-2", "peer/b"), note("m-3")]]) {
      const before = rows;
      rows = [...page, ...before];
      noteKeptSuffix(rows, before, before.length);
      const last = foldIncoming(reading.turns, reading.ticks);
      reading = minimapTurns(rows, "s", reading, { base: before, rows, from: 0 });
      expect(drawn(reading)).toEqual(drawn(minimapTurns(rows, "s")));
      // The fold below the page's run is the last one's: the same tick and turn objects.
      const now = foldIncoming(reading.turns, reading.ticks);
      expect(now.ticks.at(-1)).toBe(last.ticks.at(-1)!);
      expect(now.turns.at(-1)).toBe(last.turns.at(-1)!);
    }
    expect(foldIncoming(reading.turns, reading.ticks).ticks.map((tick) => tick.members ?? tick.id)).toEqual([
      ["m-2", "m-3"],
      "u0",
      ["m-1", "m0", "m1", "m2"],
      "u1",
      ["m3", "m4"],
    ]);
  });
});
