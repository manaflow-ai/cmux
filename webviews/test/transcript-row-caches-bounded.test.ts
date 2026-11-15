// A long chat's rows slide: the store keeps a window (rows/store.ts STORE_MAX_ROWS) and lets go of
// the rows past it. What the transcript keeps per row id must go with them. Two did not: the bare
// `#N` repository cache (an entry, with the row's whole text, per row ever read) and the keys of
// rows seen (VirtualTranscript `knownRows`). In the transcript-replay bench's god chat both held an
// entry for every row from the first, part of its JS heap over the small chat's (36 MB against 30).
import { expect, test } from "bun:test";
import { DRAWN_ROWS_KEPT, keepKnownRows } from "../src/agent-session/acpmux/conversation/openBreakpoint";
import {
  REPOSITORY_CACHE_SLACK,
  transcriptRepositories,
  transcriptRepositoriesFrom,
  type RepositoryCache,
  type RepositoryReading,
} from "../src/agent-session/acpmux/conversation/transcriptRepositories";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (index: number): AcpmuxRow =>
  ({
    id: `r${index}`,
    version: 1,
    at: index,
    kind: index % 2 ? "assistant" : "user",
    text: index % 97 === 0 ? `see o/r${index}#1` : `text ${index}`,
  }) as AcpmuxRow;

const WINDOW = 400;

test("the bare #N repository cache holds the rows of the window, not every row the chat showed", () => {
  const cache: RepositoryCache = new Map();
  let reading: RepositoryReading | undefined;
  let rows: AcpmuxRow[] = [];
  let peak = 0;
  for (let index = 0; index < 20 * WINDOW; index += 1) {
    rows = [...rows.slice(rows.length >= WINDOW ? 1 : 0), row(index)];
    reading = transcriptRepositoriesFrom(rows, "h/r", cache, reading);
    peak = Math.max(peak, cache.size);
  }
  expect(peak).toBeLessThanOrEqual(2 * WINDOW + REPOSITORY_CACHE_SLACK + 1);
  for (const each of rows) expect(cache.has(each.id)).toBe(true);
  // What it answers is a whole pass's.
  const drawn = Array.from({ length: rows.length }, (_, i) => reading!.at(i));
  expect(drawn).toEqual(transcriptRepositories(rows, "h/r"));
});

test("a transcript's seen rows are let go of past the bound, keeping every row shown now", () => {
  const key = (each: AcpmuxRow) => each.id;
  const known = new Set<string>();
  let rows: AcpmuxRow[] = [];
  let peak = 0;
  for (let index = 0; index < 4 * DRAWN_ROWS_KEPT; index += 1) {
    rows = [...rows.slice(rows.length >= WINDOW ? 1 : 0), row(index)];
    known.add(key(rows.at(-1)!));
    keepKnownRows(known, rows, key);
    peak = Math.max(peak, known.size);
  }
  expect(peak).toBeLessThanOrEqual(DRAWN_ROWS_KEPT + 1);
  for (const each of rows) expect(known.has(each.id)).toBe(true);
  // Under the bound nothing is let go of.
  const small = new Set(["a", "b"]);
  keepKnownRows(small, [{ id: "a" }], (each) => each.id);
  expect([...small]).toEqual(["a", "b"]);
});
