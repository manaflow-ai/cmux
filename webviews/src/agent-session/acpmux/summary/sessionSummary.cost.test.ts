// Session Info makes the chat's summary (sessionSummary.ts) again on every call's start and end, since
// either one moves the transcript's summary version. It read every finished call's whole output for
// links each time, so a chat of 28,408 background shells paid for all of them on every call (Leo,
// 2026-11-19: "dam this is slow as shit on the sesion info"). A past call's output is now read once,
// when its row first shows, never again for a later call.
//
// A chat of N past turns, each a reply and a finished shell whose output counts its reads and holds a
// link, then one update: a new call finished. The update must read no past call, at N = 10 as at
// N = 1,000, and list the same Sources a fresh read of the same rows lists.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { sessionSummary } from "./sessionSummary";

const filler = (seed: string) => Array.from({ length: 200 }, (_, index) => `${seed} line ${index}`).join("\n");

function pastTurn(n: number, reads: { count: number }): AcpmuxRow[] {
  const output = `${filler(`build ${n}`)}\nsee https://example.com/docs/${n} and https://github.com/o/r/issues/${n + 1}\n`;
  const tool = {
    id: `shell-${n}`,
    kind: "execute",
    title: `make step-${n}`,
    status: "completed",
    command: `make step-${n}`,
    inputSummary: JSON.stringify({ command: `make step-${n}`, run_in_background: true }),
    get output() {
      reads.count += 1;
      return output;
    },
  };
  return [
    {
      id: `reply-${n}`,
      version: 1,
      at: n,
      kind: "assistant",
      text: `Ran step ${n}, notes at https://example.com/n/${n}`,
    },
    {
      id: `activity-${n}`,
      version: 1,
      at: n,
      kind: "activity",
      items: [{ kind: "tool", tool }],
    } as unknown as AcpmuxRow,
  ];
}

const finished = (id: string, at: number): AcpmuxRow =>
  ({
    id,
    version: 1,
    at,
    kind: "activity",
    items: [
      { kind: "tool", tool: { id, kind: "execute", title: "ls", status: "completed", command: "ls", output: "a\nb" } },
    ],
  }) as unknown as AcpmuxRow;

/// The same rows as new objects with plain outputs: nothing any cache kept applies to them.
const fresh = (rows: readonly AcpmuxRow[]) => rows.map((row) => JSON.parse(JSON.stringify(row)) as AcpmuxRow);

function update(turns: number) {
  const reads = { count: 0 };
  const history = Array.from({ length: turns }, (_, n) => pastTurn(n, reads)).flat();
  sessionSummary([...history, finished("first", turns)], "o/r", "/w");
  reads.count = 0;
  const rows = [...history, finished("first", turns), finished("second", turns + 1)];
  const started = performance.now();
  const after = sessionSummary(rows, "o/r", "/w");
  const ms = performance.now() - started;
  const counted = reads.count;
  return { reads: counted, ms, after, rows };
}

test("one finished call reads no past call's output, however long the chat", () => {
  const ten = update(10);
  const thousand = update(1000);
  console.log(
    `SUMMARY-COST ${JSON.stringify({ n10: { reads: ten.reads, ms: +ten.ms.toFixed(2) }, n1000: { reads: thousand.reads, ms: +thousand.ms.toFixed(2) } })}`,
  );
  expect(ten.reads, "past call outputs read for one update, N = 10").toBe(0);
  expect(thousand.reads, "past call outputs read for one update, N = 1,000").toBe(0);
  expect(thousand.after.backgroundTasks).toHaveLength(1000);
});

test("the kept reads list what a fresh read of the same rows lists, in the same order", () => {
  const { after, rows } = update(50);
  const again = sessionSummary(fresh(rows), "o/r", "/w");
  expect(after.sources).toEqual(again.sources);
  expect(after.backgroundTasks).toEqual(again.backgroundTasks);
  expect(after.sources.length).toBeGreaterThan(100);
});

test("a page of older rows read in front keeps each row's finds and the transcript order", () => {
  const reads = { count: 0 };
  const older = Array.from({ length: 20 }, (_, n) => pastTurn(n, reads)).flat();
  const newer = Array.from({ length: 20 }, (_, n) => pastTurn(n + 20, reads)).flat();
  sessionSummary(newer, "o/r", "/w");
  const paged = sessionSummary([...older, ...newer], "o/r", "/w");
  const again = sessionSummary(fresh([...older, ...newer]), "o/r", "/w");
  expect(paged.sources).toEqual(again.sources);
  expect(paged.sources[0]?.url).toBe("https://example.com/n/0");
});

test("one call's output with more links than a call takes arguments still lists its Source", () => {
  // `push(...links)` threw RangeError (Maximum call stack size exceeded) here, and Session Info failed to open.
  const output = "https://example.com/same ".repeat(1_200_000);
  const row = {
    id: "many-links",
    version: 1,
    at: 1,
    kind: "activity",
    items: [
      {
        kind: "tool",
        tool: { id: "many", kind: "execute", title: "cat", status: "completed", command: "cat", output },
      },
    ],
  } as unknown as AcpmuxRow;
  const summary = sessionSummary([row], "o/r", "/w");
  expect(summary.sources.map((source) => source.url)).toContain("https://example.com/same");
});
