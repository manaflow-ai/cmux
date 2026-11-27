// mergeEventRecords (direct/records.ts) merges the held log with an older, gap or attach page on every page. It walked
// every record into a Map and sorted the whole log per page; now it merges the already-ordered inputs in one pass.
// Correctness: the old Map-and-sort (mergeEventRecordsBySort) is the oracle on random batches, ordered or not, with
// ties inside and across batches. Speed: old against new on one 100k log, interleaved in one process, and new at 10x.
import { describe, expect, test } from "bun:test";
import {
  type EventRecord,
  mergeEventRecords,
  mergeEventRecordsBySort,
} from "../src/agent-session/acpmux/direct/records";
import { expectGrowth, expectSpeedup, forSeeds, type Gen } from "./support/dsaBench";

const record = (seq: number, tag = ""): EventRecord => ({ seq, at: seq, dir: "in", kind: "x", msg: { tag } });
const log = (from: number, count: number, step = 1) => Array.from({ length: count }, (_, i) => record(from + i * step));

function batch(g: Gen, tag: string): EventRecord[] {
  const count = g.int(0, 30);
  const from = g.int(-20, 40);
  const seqs = Array.from({ length: count }, () => from + g.int(0, 40));
  if (g.bool(0.75)) seqs.sort((a, b) => a - b);
  if (g.bool(0.3)) for (let i = 1; i < seqs.length; i++) if (g.bool(0.3)) seqs[i] = seqs[i - 1]!;
  return seqs.map((seq, i) => record(seq, `${tag}${i}`));
}

describe("mergeEventRecords", () => {
  test("matches the Map-and-sort merge record for record on random batches", () => {
    forSeeds(2000, (g) => {
      const batches = Array.from({ length: g.int(0, 4) }, (_, i) => batch(g, `b${i}.`));
      const got = mergeEventRecords(...batches);
      const want = mergeEventRecordsBySort(...batches);
      expect(got.length).toBe(want.length);
      for (let i = 0; i < want.length; i++) expect(got[i]).toBe(want[i]!);
      for (const input of batches) expect(got).not.toBe(input);
    });
  });

  test("a later batch wins a tie; disjoint pages concatenate either way round", () => {
    const held = log(10, 5);
    const replay = [record(12, "again")];
    expect(mergeEventRecords(held, replay)[2]!.msg.tag).toBe("again");
    expect(mergeEventRecords(log(0, 3), held).map((e) => e.seq)).toEqual([0, 1, 2, 10, 11, 12, 13, 14]);
    expect(mergeEventRecords(held, log(0, 3)).map((e) => e.seq)).toEqual([0, 1, 2, 10, 11, 12, 13, 14]);
    expect(mergeEventRecords()).toEqual([]);
  });

  test("an older page onto a 100k log: faster than the Map-and-sort, linear when the log grows 10x", () => {
    const held = log(1, 100_000);
    const older = log(-500, 500);
    expectSpeedup(
      "mergeEventRecords.older_page_100k",
      100_000,
      () => mergeEventRecordsBySort(older, held),
      () => mergeEventRecords(older, held),
      {
        minSpeedup: 3,
        budgetMs: 25,
      },
    );
    // At 1M it still beats the sort by as much. It is linear, not flat: a merge hands back a new array, so it copies
    // the log (and allocation at 1M costs more per record than at 100k). Flat needs a log that is not one array.
    const big = log(1, 1_000_000);
    expectSpeedup(
      "mergeEventRecords.older_page_1m",
      1_000_000,
      () => mergeEventRecordsBySort(older, big),
      () => mergeEventRecords(older, big),
      {
        minSpeedup: 3,
        budgetMs: 250,
        runs: 5,
      },
    );
    expectGrowth(
      "mergeEventRecords.older_page",
      100_000,
      (n) => {
        const held = log(1, n);
        return () => mergeEventRecords(older, held);
      },
      { maxRatio: 40, runs: 7 },
    );
  });

  test("a gap page inside a 100k log: one merge pass, faster than the sort", () => {
    const held = log(1, 100_000, 2);
    const gap = log(100_000, 500, 2).map((event) => record(event.seq + 1));
    expectSpeedup(
      "mergeEventRecords.gap_page_100k",
      100_000,
      () => mergeEventRecordsBySort(held, gap),
      () => mergeEventRecords(held, gap),
      {
        minSpeedup: 3,
        budgetMs: 25,
      },
    );
  });
});
