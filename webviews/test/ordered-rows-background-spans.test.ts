// OrderedRows asks which background turn owns a row on every row write of a chat that has any (direct/orderedRows.ts
// `set`). It walked every span heard, newest first; BackgroundSpans (direct/backgroundSpans.ts) indexes the closed
// spans by start with a running maximum of their ends. Correctness: the walk (backgroundAtLinear) is the oracle on
// random histories of opens (in order and older pages out of order, ties, an end heard first), closes (an end moving
// only earlier), retains and clears. Speed: walk against index on the same spans, interleaved in one process, and the
// index at 10x the spans.
import { describe, expect, test } from "bun:test";
import {
  BackgroundSpans,
  backgroundAtLinear,
  type BackgroundSpan,
} from "../src/agent-session/acpmux/direct/backgroundSpans";
import { expectGrowth, expectSpeedup, forSeeds } from "./support/dsaBench";

describe("BackgroundSpans", () => {
  test("answers as the walk over every span on random histories", () => {
    forSeeds(1500, (g) => {
      const spans = new BackgroundSpans();
      let next = 0;
      let live = g.int(0, 50);
      const steps = g.int(1, 60);
      for (let step = 0; step < steps; step++) {
        const roll = g.next();
        if (roll < 0.4) {
          // A start: live (past what is held) or an older page's (anywhere, ties too), maybe its end already heard.
          const from = g.bool(0.7) ? (live += g.int(0, 6)) : g.int(-10, live);
          const to = g.bool(0.3) ? from + g.int(-2, 30) : undefined;
          spans.add({ id: g.bool(0.1) && next > 0 ? `t${g.int(0, next - 1)}` : `t${next++}`, from, to });
        } else if (roll < 0.7 && next > 0) {
          const id = `t${g.int(0, next - 1)}`;
          const from = spans.get(id)?.from ?? 0;
          spans.close(id, from + g.int(-2, 30));
        } else if (roll < 0.75) {
          const lo = g.int(-10, live);
          const hi = lo + g.int(0, 30);
          spans.retain((span) => !(span.from >= lo && span.to !== undefined && span.to < hi));
        } else if (roll < 0.77) {
          spans.clear();
        }
        const all = spans.spans();
        for (let probe = 0; probe < 8; probe++) {
          const order = g.int(-12, live + 35) + (g.bool(0.2) ? 0.5 : 0);
          expect(spans.at(order)).toBe(backgroundAtLinear(all, order));
        }
        const openWant = all.filter((s) => s.to === undefined && s.from < live).map((s) => s.id);
        expect(spans.openBefore(live)).toEqual(openWant);
      }
    });
  });

  // A chat's background turns, one after another (each ended before the next started, as acpmux runs them), with
  // 100 events each; the last one still open.
  const history = (count: number) => {
    const spans = new BackgroundSpans();
    const list: BackgroundSpan[] = [];
    for (let i = 0; i < count; i++) {
      const span = { id: `t${i}`, from: i * 100, to: i === count - 1 ? undefined : i * 100 + 60 };
      spans.add({ ...span });
      list.push(span);
    }
    return { spans, list, rows: count * 100 };
  };

  // One rebuild's worth of row writes: every event order of the chat, once.
  const writeAll = (lookup: (order: number) => string | undefined, rows: number, step: number) => () => {
    let owned = 0;
    for (let order = 0; order < rows; order += step) if (lookup(order) !== undefined) owned++;
    return owned;
  };

  for (const count of [1_000, 10_000]) {
    // Every 7th event at 1k spans (14k writes), every 70th at 10k: the walk takes 1.6 s for every 7th there.
    test(`a row write's lookup at ${count} spans: faster than the walk`, () => {
      const { spans, list, rows } = history(count);
      const step = count === 1_000 ? 7 : 70;
      expectSpeedup(
        `backgroundSpans.at_${count}`,
        count,
        writeAll((order) => backgroundAtLinear(list, order), rows, step),
        writeAll((order) => spans.at(order), rows, step),
        { minSpeedup: 10, budgetMs: 20, runs: 5 },
      );
    }, 60_000);
  }

  test("a lookup costs about the same at 10x the spans", () => {
    expectGrowth(
      "backgroundSpans.at_per_lookup",
      1_000,
      (count) => {
        const { spans } = history(count);
        // The same 20k lookups, spread over the chat, whatever its size.
        return () => {
          let owned = 0;
          for (let i = 0; i < 20_000; i++) if (spans.at(((i * 7919) % count) * 100 + 30) !== undefined) owned++;
          return owned;
        };
      },
      // log2(10k) / log2(1k) is 1.3; a shared runner's cache and JIT noise get the rest of the headroom. The walk is 10.
      { maxRatio: 4 },
    );
  });
});
