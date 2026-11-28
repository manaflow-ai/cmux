// A full rebuild of the held log (direct.ts `rebuildHeld`, every refold without a cut: a seek, a jump, a reset) copied
// and sorted the log by `seq`, then filtered and sorted it again, though the log is kept in `seq` order. `heldBySeq`
// (direct/records.ts) checks the order in one pass and copies. Correctness: the copy-or-filter-and-sort
// (heldBySeqBySort) is the oracle on random logs, in order or not, with ties, NaN and a `through` anywhere. Speed: the
// two steps of a rebuild, old against new on one 100k log, interleaved in one process, and new at 10x.
import { describe, expect, test } from "bun:test";
import { type EventRecord, heldBySeq, heldBySeqBySort } from "../src/agent-session/acpmux/direct/records";
import { expectGrowth, expectSpeedup, forSeeds } from "./support/dsaBench";

const record = (seq: number, tag = ""): EventRecord => ({ seq, at: seq, dir: "in", kind: "x", msg: { tag } });
const log = (count: number) => Array.from({ length: count }, (_, i) => record(i + 1));

const same = (got: EventRecord[], want: EventRecord[], input: EventRecord[]) => {
  expect(got.length).toBe(want.length);
  for (let i = 0; i < want.length; i++) expect(got[i]).toBe(want[i]!);
  expect(got).not.toBe(input);
};

describe("heldBySeq", () => {
  test("matches the copy-or-filter-and-sort record for record on random logs", () => {
    forSeeds(2000, (g) => {
      const seqs = Array.from({ length: g.int(0, 40) }, () => g.int(-5, 60));
      if (g.bool(0.7)) seqs.sort((a, b) => a - b);
      if (g.bool(0.3)) for (let i = 1; i < seqs.length; i++) if (g.bool(0.3)) seqs[i] = seqs[i - 1]!;
      if (g.bool(0.05) && seqs.length > 0) seqs[g.int(0, seqs.length - 1)] = Number.NaN;
      const events = seqs.map((seq, i) => record(seq, `r${i}`));
      const through = g.pick([undefined, Number.POSITIVE_INFINITY, Number.NaN, -10, g.int(-5, 65)]);
      same(heldBySeq(events, through), heldBySeqBySort(events, through), events);
    });
  });

  test("a full rebuild's two orderings of a 100k log: faster than the sorts, linear when the log grows 10x", () => {
    const held = log(100_000);
    expectSpeedup(
      "heldBySeq.full_rebuild_100k",
      100_000,
      () => heldBySeqBySort(heldBySeqBySort(held), Number.POSITIVE_INFINITY),
      () => heldBySeq(heldBySeq(held), Number.POSITIVE_INFINITY),
      { minSpeedup: 3, budgetMs: 25 },
    );
    expectGrowth(
      "heldBySeq.full_rebuild",
      100_000,
      (n) => {
        const held = log(n);
        return () => heldBySeq(heldBySeq(held), Number.POSITIVE_INFINITY);
      },
      { maxRatio: 40, runs: 7 },
    );
  });
});
