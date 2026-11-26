// A running turn is shaped again on every record (turns.ts `shapedTurn` keeps no cache for it): the
// rows a record did not change stay the objects drawn before (`steadyLiveRows`), so the transcript's
// layout and row memos keep them and a record costs what it changed, not the whole running turn.
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnViewFrom } from "./turns";

// These pin how a running turn's calls draw in sight, the `open` live arm they were written for;
// the shipped `folded` keeps them under a closed "Working for" (#50987, live-turn-folds-to-line.test.ts).
let armsBefore: typeof globalThis.cmuxExperiments;
beforeEach(() => {
  armsBefore = globalThis.cmuxExperiments;
  globalThis.cmuxExperiments = { ...armsBefore, "live-turn-work": "open" };
});
afterEach(() => {
  if (armsBefore === undefined) delete globalThis.cmuxExperiments;
  else globalThis.cmuxExperiments = armsBefore;
});

const prompt: AcpmuxRow = { id: "prompt", version: 1, at: 1_000, kind: "user", text: "coordinate the lanes" };

function tool(index: number, status = "completed"): AcpmuxRow {
  return {
    id: `tool-${index}`,
    version: 1,
    at: 2_000 + index * 10,
    kind: "activity",
    items: [
      {
        kind: "tool",
        text: "Bash",
        tool: { id: `call-${index}`, title: `step ${index}`, kind: "execute", status, command: `echo ${index}` },
      },
    ],
    toolCount: 1,
  };
}

function reply(index: number): AcpmuxRow {
  return {
    id: `reply-${index}`,
    version: 1,
    at: 2_005 + index * 10,
    kind: "assistant",
    text: `Lane ${index} is green.`,
  };
}

/// A running coordinator turn: calls with a reply after every fourth, `count` records long.
function liveTurn(count: number): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [prompt];
  for (let index = 0; index < count; index += 1) rows.push(index % 4 === 3 ? reply(index) : tool(index));
  return rows;
}

const options = (now: number) => ({ now, working: true, turnStartedAtMs: 1_000 });

test("a record into a long running turn leaves the rows it did not change the same objects", () => {
  const folds = new Set<string>();
  const rows = liveTurn(400);
  const before = turnViewFrom(rows, folds, options(10_000));
  const after = turnViewFrom([...rows, tool(400, "in_progress")], folds, options(10_000), before);
  const ids = new Map(before.rows.map((row) => [row.id, row]));
  const changed = after.rows.filter((row) => ids.has(row.id) && ids.get(row.id) !== row).map((row) => row.id);
  // Only rows that read the newest record (the live line, the group the call joined) may change.
  expect(changed.length).toBeLessThanOrEqual(3);
  // The prefix the layout keeps by object reaches the end of what the record left alone.
  let kept = 0;
  while (kept < before.rows.length && before.rows[kept] === after.rows[kept]) kept += 1;
  expect(kept).toBeGreaterThanOrEqual(before.rows.length - 3);
});

test("a row whose record changed is a new object", () => {
  const folds = new Set<string>();
  const rows = [...liveTurn(40), tool(40, "in_progress")];
  const before = turnViewFrom(rows, folds, options(10_000));
  const finished = [...rows.slice(0, -1), { ...tool(40, "completed"), version: 2 }];
  const after = turnViewFrom(finished, folds, options(10_000), before);
  const old = before.rows.find((row) => JSON.stringify(row).includes("call-40"));
  const now = after.rows.find((row) => JSON.stringify(row).includes("call-40"));
  expect(now).toBeDefined();
  expect(now).not.toBe(old);
  expect(JSON.stringify(now)).toContain('"completed"');
});

test("the shape that ends the turn keeps the objects the running turn drew", () => {
  const folds = new Set<string>();
  const rows = liveTurn(40);
  const running = turnViewFrom(rows, folds, options(10_000));
  const again = turnViewFrom([...rows], folds, options(10_000), running);
  let kept = 0;
  while (kept < running.rows.length && running.rows[kept] === again.rows[kept]) kept += 1;
  expect(kept).toBeGreaterThanOrEqual(running.rows.length - 1);
});

/// `tool(index)` whose command line counts its reads in `reads`: what a record parses again.
function countedTool(index: number, reads: { count: number }): AcpmuxRow {
  const row = tool(index);
  const call = row.items![0]!.tool!;
  const command = call.command!;
  Object.defineProperty(call, "command", {
    enumerable: true,
    get: () => {
      reads.count += 1;
      return command;
    },
  });
  return row;
}

test("a record into a long running turn reads none of its earlier calls again", () => {
  const folds = new Set<string>();
  const reads = { count: 0 };
  // A prompt of its own: what a running turn keeps between records is kept by its prompt, and the
  // tests above ran theirs under `prompt`.
  const rows: AcpmuxRow[] = [{ ...prompt, id: "prompt-reads" }];
  for (let index = 0; index < 200; index += 1) rows.push(index % 4 === 3 ? reply(index) : countedTool(index, reads));
  let view = turnViewFrom(rows, folds, options(10_000));
  // Once more with the same rows, so whatever the first shape read lazily is read.
  view = turnViewFrom([...rows], folds, options(10_000), view);
  const perRecord: number[] = [];
  for (let record = 200; record < 220; record += 1) {
    reads.count = 0;
    rows.push(record % 4 === 3 ? reply(record) : tool(record));
    view = turnViewFrom([...rows], folds, options(10_000), view);
    perRecord.push(reads.count);
  }
  // 150 earlier calls: a record that parsed each again read each command line at least once (1,830
  // reads a record before the earlier runs kept their rows). The appended calls are not counted.
  expect(Math.max(...perRecord)).toBeLessThan(10);
});
