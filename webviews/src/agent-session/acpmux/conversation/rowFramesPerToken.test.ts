// A streamed token redraws the live row's frame alone (rowFrameCache.ts), but each transcript render still
// paid per mounted row: `begin` made a new Map, `put` a new entry, inputs copy and row window for the
// row it drew again, and every mounted row's reference scope (VirtualTranscript `scopeAt`,
// bareReferences.ts `referenceScopes`) built a JSON key for its turn. A god chat of short turns mounts
// about 60 rows where a small chat mounts 31 (bench/transcript-replay.bench.ts PAIRED=1), so that garbage
// followed the rows in view: `drawRowFrames` allocated about 131 KB more per token in the god chat
// (ALLOC=1; Leo, 2026-11-12: "infinite everything feels like nothing"). Here a token's render over 30 and
// over 60 mounted rows makes no Map, keeps the live row's entry, and builds no scope key.
import { afterEach, describe, expect, test } from "bun:test";
import type { ReactElement } from "react";
import type { AcpmuxRow } from "../model";
import { newReferenceScopeCache, referenceScopes, turnOpener } from "./bareReferences";
import { RowFrameCache } from "./rowFrameCache";

const RealMap = globalThis.Map;
afterEach(() => {
  globalThis.Map = RealMap;
});

/// Counts the Maps made while `run` runs.
function mapsMadeBy(run: () => void): number {
  let made = 0;
  globalThis.Map = class extends RealMap<unknown, unknown> {
    constructor(entries?: Iterable<readonly [unknown, unknown]> | null) {
      super(entries);
      made += 1;
    }
  } as MapConstructor;
  try {
    run();
  } finally {
    globalThis.Map = RealMap;
  }
  return made;
}

/// `count` rows of short turns: a prompt naming a pull request, then a reply; the last row is the live reply.
function chat(count: number): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  for (let index = 0; index < count; index += 1)
    rows.push(
      (index % 2 === 0
        ? { id: `p${index}`, kind: "user", text: `look at #${100 + index}`, at: index }
        : { id: `r${index}`, kind: "assistant", text: "ok", at: index }) as unknown as AcpmuxRow,
    );
  return rows;
}

/// A streamed token: the last row is a new object with one more word.
const token = (rows: readonly AcpmuxRow[], word: string): AcpmuxRow[] => {
  const next = rows.slice();
  const last = next.at(-1)!;
  next[next.length - 1] = { ...last, text: `${last.text} ${word}` } as AcpmuxRow;
  return next;
};

const SHARED = [1, 2, 3];

/// One transcript render through the cache, as drawRowFrames does it.
function render(cache: RowFrameCache, rows: readonly AcpmuxRow[]): void {
  cache.begin(SHARED);
  for (let index = 0; index < rows.length; index += 1) {
    const inputs = cache.scratch;
    inputs.index = index;
    inputs.top = index * 20;
    inputs.gapBelow = 8;
    if (cache.take(rows[index]!.id, rows)) continue;
    cache.put(rows[index]!.id, rows, Math.max(0, index - 2), index + 1, {} as ReactElement);
  }
  cache.end();
}

type Entry = { inputs: object; window: unknown[] };
const entryOf = (cache: RowFrameCache, key: string) =>
  (cache as unknown as { entries: Map<string, Entry> }).entries.get(key)!;

describe("a streamed token's frame work does not follow the rows in view", () => {
  test("the row frame cache: no Map, and the live row keeps its entry", () => {
    const passes = [30, 60].map((count) => {
      const cache = new RowFrameCache();
      let rows = chat(count);
      render(cache, rows);
      rows = token(rows, "a");
      render(cache, rows);
      const live = rows.at(-1)!.id;
      const before = entryOf(cache, live);
      const { inputs, window } = before;
      let maps = 0;
      for (const word of ["b", "c", "d", "e"]) {
        rows = token(rows, word);
        maps += mapsMadeBy(() => render(cache, rows));
      }
      const after = entryOf(cache, live);
      return {
        count,
        maps,
        derived: cache.derived,
        sameEntry: after === before && after.inputs === inputs && after.window === window,
      };
    });
    console.log(`PER-UPDATE row frame cache ${JSON.stringify(passes)}`);
    expect(passes[1]!.maps).toBe(passes[0]!.maps);
    expect(passes[0]!.maps).toBe(0);
    expect(passes[0]!.sameEntry).toBe(true);
    expect(passes[1]!.sameEntry).toBe(true);
  });

  test("the rows' reference scopes: no key built for a row whose turn is unchanged", () => {
    const passes = [30, 60].map((count) => {
      const cache = newReferenceScopeCache();
      let rows = chat(count);
      let scopeOf = referenceScopes(rows, cache);
      for (let index = 0; index < rows.length; index += 1) scopeOf(turnOpener(cache, rows, index));
      rows = token(rows, "a");
      scopeOf = referenceScopes(rows, cache);
      const stringify = JSON.stringify;
      let keys = 0;
      JSON.stringify = ((...args: Parameters<typeof JSON.stringify>) => {
        keys += 1;
        return stringify(...args);
      }) as typeof JSON.stringify;
      const first = scopeOf(turnOpener(cache, rows, 0));
      try {
        for (let index = 0; index < rows.length; index += 1) scopeOf(turnOpener(cache, rows, index));
      } finally {
        JSON.stringify = stringify;
      }
      // The scope objects themselves are kept, so the rows' frames see the same scope.
      expect(scopeOf(turnOpener(cache, rows, 0))).toBe(first);
      return { count, keys };
    });
    console.log(`PER-UPDATE reference scope keys ${JSON.stringify(passes)}`);
    expect(passes[1]!.keys).toBe(passes[0]!.keys);
    expect(passes[0]!.keys).toBe(0);
  });
});
