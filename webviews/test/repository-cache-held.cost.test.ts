// A chat left open keeps the bare `#N` reading (conversation/transcriptRepositories.ts) of the rows it holds, not of
// every row it ever streamed. The pane lets go of its oldest records past HELD_RECORDS (direct.ts `shedOlderHeld`),
// but the transcript's repository cache kept each prompt's and reply's text by row id for the page's life: in the
// transcript-replay bench's god log (FIXTURE=god, PAIRED=1 heap snapshot) 20,994 entries and 2.3 MB of reply text
// against the 600-turn chat's 1,800 and 0.6 MB, the largest part of the god chat's extra JS heap. Here a small chat
// and a god-sized one end holding the same rows; the god one may keep at most 1.2x the entries and text (Leo,
// 2026-11-12: "even if a chat is long, there should be no percievable difference").
import { expect, test } from "bun:test";
import {
  transcriptRepositories,
  transcriptRepositoriesFrom,
  type RepositoryCache,
  type RepositoryReading,
} from "../src/agent-session/acpmux/conversation/transcriptRepositories";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

/// Rows a chat holds once it lets go of its oldest (direct.ts HELD_KEPT records, about this many rows), and twice
/// that before it does (HELD_RECORDS).
const KEPT = 2_000;
const HELD = 2 * KEPT;

const row = (id: string, kind: "user" | "assistant" | "tool", text?: string): AcpmuxRow =>
  ({ id, version: 1, at: 0, kind, text }) as AcpmuxRow;

/// Streams turns into a transcript as the pane draws it: each turn's prompt, its tool calls (rows with no text, as
/// most of a real chat's rows are), then its reply token by token, one snapshot each; past HELD rows the oldest go, down to the newest KEPT, at a turn's end. Ends after `turns` turns
/// once the rows held are KEPT (a long chat streams on to its next cut).
function stream(turns: number) {
  const cache: RepositoryCache = new Map();
  let reading: RepositoryReading | undefined;
  let rows: AcpmuxRow[] = [];
  for (let turn = 0; turn < turns || rows.length !== KEPT; turn += 1) {
    rows = [...rows, row(`user-${turn}`, "user", `turn ${turn}: look at o/r${turn % 7}#${turn}`)];
    reading = transcriptRepositoriesFrom(rows, undefined, cache, reading);
    for (let call = 0; call < 3; call += 1) {
      rows = [...rows, row(`tool-${turn}-${call}`, "tool")];
      reading = transcriptRepositoriesFrom(rows, undefined, cache, reading);
    }
    let reply = `On it, turn ${turn}.`;
    for (const word of ["Reading", "the", "files", `and #${turn + 1}`, "done."]) {
      reply = `${reply} ${word}`;
      const before = rows.at(-1)?.id === `assistant-${turn}` ? rows.slice(0, -1) : rows;
      rows = [...before, row(`assistant-${turn}`, "assistant", reply)];
      reading = transcriptRepositoriesFrom(rows, undefined, cache, reading);
    }
    if (rows.length > HELD) {
      rows = rows.slice(rows.length - KEPT);
      reading = transcriptRepositoriesFrom(rows, undefined, cache, reading);
    }
  }
  const chars = [...cache.values()].reduce((sum, entry) => sum + entry.text.length, 0);
  return { rows, reading: reading!, entries: cache.size, chars };
}

test("a chat left open keeps the repository reading of the rows it holds, at most 1.2x a small chat's", () => {
  // A chat that holds KEPT rows whole, and one that streamed 35,000 rows (the god log's) and holds the same KEPT.
  const small = stream(KEPT / 5);
  const god = stream(7_000);
  expect(small.rows.length).toBe(KEPT);
  expect(god.rows.length).toBe(KEPT);
  expect(Number(god.rows[0]!.id.split("-")[1])).toBeGreaterThan(6_000);
  expect(god.entries).toBeLessThanOrEqual(small.entries * 1.2);
  expect(god.chars).toBeLessThanOrEqual(small.chars * 1.2);
  // What it reads is what a whole pass over the rows it holds gives.
  for (const chat of [small, god])
    expect(chat.rows.map((_, index) => chat.reading.at(index))).toEqual(transcriptRepositories(chat.rows));
});
